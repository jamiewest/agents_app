// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// using dynamic calls to translate to/from JSON
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:extensions/ai.dart' as ai show UsageDetails;
import 'package:flutter/foundation.dart';

import 'attachments.dart';
import 'message_origin.dart';

/// Represents a message in a chat conversation.
///
/// This class encapsulates the properties and behavior of a chat message,
/// including its unique identifier, origin (user or LLM), text content,
/// and any attachments.
///
/// A message is a [ChangeNotifier]: it notifies as its streamed text and
/// transient turn state ([toolActivity], [isGenerating], [usage]) change, so
/// only the live bubble rebuilds per token while the provider's coarser
/// notifications cover structural history changes.
class ChatMessage extends ChangeNotifier {
  /// Constructs a [ChatMessage] instance.
  ///
  /// The [origin] parameter specifies the origin of the message (user or LLM).
  /// The [text] parameter is the content of the message. It can be null or
  /// empty if the message is from an LLM. For user-originated messages, [text]
  /// must not be null or empty. The [attachments] parameter is a list of any
  /// files or media attached to the message.
  ChatMessage({
    required this.origin,
    required String? text,
    required this.attachments,
  }) : assert(origin.isUser && text != null && text.isNotEmpty || origin.isLlm),
       _text = text;

  /// Converts a JSON map representation to a [ChatMessage].
  ///
  /// The map should contain the following keys:
  /// - 'origin': The origin of the message (user or model).
  /// - 'text': The text content of the message.
  /// - 'attachments': A list of attachments, each represented as a map with:
  ///   - 'type': The type of the attachment ('file' or 'link').
  ///   - 'name': The name of the attachment.
  ///   - 'mimeType': The MIME type of the attachment.
  ///   - 'data': The data of the attachment, either as a base64 encoded string
  ///     (for files) or a URL (for links).
  factory ChatMessage.fromJson(Map<String, dynamic> map) => ChatMessage(
    origin: MessageOrigin.values.byName(map['origin'] as String),
    text: map['text'] as String,
    attachments: [
      for (final attachment in map['attachments'] as List<dynamic>)
        switch (attachment['type'] as String) {
          'file' => FileAttachment.fileOrImage(
            name: attachment['name'] as String,
            mimeType: attachment['mimeType'] as String,
            bytes: base64Decode(attachment['data'] as String),
          ),
          'link' => LinkAttachment(
            name: attachment['name'] as String,
            url: Uri.parse(attachment['data'] as String),
          ),
          _ => throw UnimplementedError(),
        },
    ],
  );

  /// Factory constructor for creating an LLM-originated message.
  ///
  /// Creates a message with an empty text content and no attachments.
  factory ChatMessage.llm() =>
      ChatMessage(origin: MessageOrigin.llm, text: null, attachments: []);

  /// Factory constructor for creating a user-originated message.
  ///
  /// [text] is the content of the user's message.
  /// [attachments] are any files or media the user has attached to the message.
  factory ChatMessage.user(String text, Iterable<Attachment> attachments) =>
      ChatMessage(
        origin: MessageOrigin.user,
        text: text,
        attachments: attachments,
      );

  /// Text content of the message.
  ///
  /// Streamed LLM text grows through [append]; there is no setter.
  String? get text => _text;
  String? _text;

  /// The origin of the message (user or LLM).
  final MessageOrigin origin;

  /// Any attachments associated with the message.
  final Iterable<Attachment> attachments;

  /// Token usage of the model turn that produced this message, when known.
  ///
  /// Covers the whole turn — tool-calling sub-requests included — and is
  /// populated only for LLM messages. Not serialized by [toJson]; durable
  /// usage lives in the transcript and the usage ledger.
  ai.UsageDetails? get usage => _usage;
  ai.UsageDetails? _usage;
  set usage(ai.UsageDetails? value) {
    if (identical(value, _usage)) return;
    _usage = value;
    notifyListeners();
  }

  /// Accumulates [details] into [usage] for a multi-request turn.
  ///
  /// Unlike mutating the object returned by [usage] in place, this notifies
  /// listeners on every accumulation.
  void addUsage(ai.UsageDetails details) {
    (_usage ??= ai.UsageDetails()).add(details);
    notifyListeners();
  }

  /// Name(s) of the tools the model is currently running to produce this
  /// message, or null when no tool is in flight.
  ///
  /// Transient streaming state set only while the turn is live; not
  /// serialized by [toJson].
  String? get toolActivity => _toolActivity;
  String? _toolActivity;
  set toolActivity(String? value) {
    if (value == _toolActivity) return;
    _toolActivity = value;
    notifyListeners();
  }

  /// Whether the provider is currently streaming this message's turn.
  ///
  /// Transient streaming state; not serialized by [toJson].
  bool get isGenerating => _isGenerating;
  bool _isGenerating = false;
  set isGenerating(bool value) {
    if (value == _isGenerating) return;
    _isGenerating = value;
    notifyListeners();
  }

  /// Wall-clock start of the turn that produced this message, when known.
  ///
  /// Survives an approval pause: resuming the same bubble keeps the original
  /// start so the elapsed timer covers the whole turn. Not serialized by
  /// [toJson].
  ///
  /// Plain (non-notifying) field: writers set it *before* the adjacent
  /// notifying [isGenerating] write so one notification publishes both.
  DateTime? turnStartedAt;

  /// Total wall-clock duration of the turn, set once the turn completes.
  ///
  /// Not serialized by [toJson]; restored transcripts show token counts only.
  ///
  /// Plain (non-notifying) field: writers set it *before* the adjacent
  /// notifying [isGenerating] write so one notification publishes both.
  Duration? turnDuration;

  /// Appends additional text to the existing message content.
  ///
  /// This is typically used for LLM messages that are streamed in parts.
  void append(String text) {
    _text = (_text ?? '') + text;
    notifyListeners();
  }

  @override
  String toString() =>
      'ChatMessage('
      'origin: $origin, '
      'text: $text, '
      'attachments: $attachments'
      ')';

  /// Converts a [ChatMessage] to a JSON map representation.
  ///
  /// The map contains the following keys:
  /// - 'origin': The origin of the message (user or model).
  /// - 'text': The text content of the message.
  /// - 'attachments': A list of attachments, each represented as a map with:
  ///   - 'type': The type of the attachment ('file' or 'link').
  ///   - 'name': The name of the attachment.
  ///   - 'mimeType': The MIME type of the attachment.
  ///   - 'data': The data of the attachment, either as a base64 encoded string
  ///     (for files) or a URL (for links).
  Map<String, dynamic> toJson() => {
    'origin': origin.name,
    'text': text,
    'attachments': [
      for (final attachment in attachments)
        {
          'type': switch (attachment) {
            (FileAttachment _) => 'file',
            (LinkAttachment _) => 'link',
          },
          'name': attachment.name,
          'mimeType': switch (attachment) {
            (final FileAttachment a) => a.mimeType,
            (final LinkAttachment a) => a.mimeType,
          },
          'data': switch (attachment) {
            (final FileAttachment a) => base64Encode(a.bytes),
            (final LinkAttachment a) => a.url,
          },
        },
    ],
  };
}
