/// Pure mapping between the durable transcript and what the chat UI shows.
///
/// These functions hold no state and touch no widgets, so the chat screen is
/// left with lifecycle and presentation only. Extracted from `ChatScreen`
/// unchanged; see `test/data/chat_transcript_mapping_test.dart`.
library;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_flutter/chat_provider.dart';
import 'package:extensions/ai.dart' as ai;

/// Maps the durable transcript to displayable UI messages.
///
/// Tool-call-only turns carry no text and are skipped; the model still
/// sees them through the chat history provider. Loop-synthesized
/// wait-for-background-agents feedback is model plumbing, not user input,
/// so it is hidden as well.
///
/// Passing [sessionId] narrows the result to that session's slice.
List<ChatMessage> displayMessagesFrom(
  Iterable<TranscriptEntry> entries, {
  String? sessionId,
}) {
  final messages = <ChatMessage>[];
  // Usage from entries that are not displayed (tool-call-only assistant
  // messages) rolls forward onto the turn's final visible bubble, so
  // restored badges match what the live stream showed.
  ai.UsageDetails? pendingUsage;

  for (final entry in entries) {
    if (sessionId != null && entry.sessionId != sessionId) continue;
    if (entry.message.authorName == loopFeedbackAuthorName) continue;
    // A scheduled-task prompt reaches the model but is never shown: either
    // tagged with the task author name (hidden user message) or sent as a
    // system turn, which would otherwise render as an LLM bubble below.
    if (entry.message.authorName == taskPromptAuthorName) continue;
    if (entry.message.role == ai.ChatRole.system) continue;
    for (final content in entry.message.contents.whereType<ai.UsageContent>()) {
      (pendingUsage ??= ai.UsageDetails()).add(content.details);
    }
    if (entry.message.text.trim().isEmpty) continue;
    if (entry.message.role == ai.ChatRole.user) {
      messages.add(
        ChatMessage.user(
          entry.message.text,
          displayAttachmentsFor(entry.message),
        ),
      );
    } else {
      messages.add(
        ChatMessage(
          origin: MessageOrigin.llm,
          text: entry.message.text,
          attachments: const [],
        )..usage = pendingUsage,
      );
      pendingUsage = null;
    }
  }
  return messages;
}

/// Rebuilds display attachments from a transcript message's file and link
/// contents, so attachment chips survive a restart. The transcript stores
/// attachments as agent-native content ([ai.DataContent]/[ai.UriContent]);
/// text-file inlining happens below persistence, so the original bytes are
/// still here.
List<Attachment> displayAttachmentsFor(ai.ChatMessage message) => [
  for (final content in message.contents)
    if (content case ai.DataContent(data: final bytes?))
      FileAttachment.fileOrImage(
        name: content.name ?? 'attachment',
        mimeType: content.mediaType ?? 'application/octet-stream',
        bytes: bytes,
      )
    else if (content case ai.UriContent(:final uri, :final mediaType))
      LinkAttachment(
        name: uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '$uri',
        url: uri,
        mimeType: mediaType,
      ),
];

/// Converts the visible UI [history] to agent-native messages for durable
/// storage. Empty-text placeholders are dropped to match what
/// [displayMessagesFrom] renders back on resume.
List<ai.ChatMessage> transcriptMessagesFrom(Iterable<ChatMessage> history) => [
  for (final message in history)
    if ((message.text ?? '').trim().isNotEmpty)
      ai.ChatMessage(
        role: message.origin.isUser ? ai.ChatRole.user : ai.ChatRole.assistant,
        contents: [
          ai.TextContent(message.text!),
          if (message.origin.isUser)
            for (final attachment in message.attachments)
              agentAttachmentContentFor(attachment),
        ],
      ),
];

/// Maps a UI [attachment] to the agent-native content the transcript stores,
/// so [displayAttachmentsFor] can rebuild the chip on resume.
ai.AIContent agentAttachmentContentFor(Attachment attachment) =>
    switch (attachment) {
      FileAttachment(
        name: final name,
        mimeType: final mimeType,
        bytes: final bytes,
      ) =>
        ai.DataContent(bytes, mediaType: mimeType, name: name),
      LinkAttachment(url: final url, mimeType: final mimeType) => ai.UriContent(
        url,
        mediaType: mimeType,
      ),
    };

/// Collapses whitespace and clips [text] to a conversation-title length.
String truncateConversationTitle(String text) {
  const maxLength = 80;
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= maxLength) return collapsed;
  return '${collapsed.substring(0, maxLength - 1)}…';
}
