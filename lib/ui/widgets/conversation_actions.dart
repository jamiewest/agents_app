// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Shared rename/delete flows for conversations and channels, used by the
/// chats list, the channel screen, and the chat app bar.
library;

import 'package:flutter/material.dart';

import '../../data/chat_transcript_store.dart';
import '../../data/conversation_store.dart';
import '../../data/usage_store.dart';
import '../../domain/conversation.dart';

/// Prompts for a new title and returns it trimmed, or `null` on cancel.
///
/// Works for any titled record; pass e.g. `dialogTitle: 'Rename channel'`.
Future<String?> showRenameDialog(
  BuildContext context, {
  required String dialogTitle,
  required String initialTitle,
}) async {
  var title = initialTitle;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(dialogTitle),
      content: TextFormField(
        initialValue: initialTitle,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Title'),
        textInputAction: TextInputAction.done,
        onChanged: (value) => title = value,
        onFieldSubmitted: (_) {
          final trimmed = title.trim();
          if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final trimmed = title.trim();
            if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Confirms with the user, then deletes the conversation and everything
/// hanging off it: transcript entries, session state, the usage ledger,
/// then the record.
///
/// Returns whether the conversation was deleted.
Future<bool> confirmAndDeleteConversation(
  BuildContext context, {
  required String conversationId,
  required String title,
  required ConversationStore conversations,
  required ConversationSessionStore sessions,
  required ChatTranscriptStore transcripts,
  UsageStore? usage,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete conversation?'),
      content: Text('Delete "$title"? This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  await transcripts.deleteFor(conversationId);
  await sessions.deleteFor(conversationId);
  await usage?.deleteFor(conversationId);
  await conversations.delete(conversationId);
  return true;
}

/// The conversation's title for display, never empty.
String conversationDisplayTitle(Conversation conversation) =>
    conversation.title.trim().isEmpty
    ? 'Untitled conversation'
    : conversation.title.trim();

/// Formats a timestamp as a compact local `yyyy-MM-dd HH:mm`.
String formatConversationDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}
