// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import '../../providers/interface/attachments.dart';
import 'file_attatchment_view.dart';
import 'image_attachment_view.dart';
import 'link_attachment_view.dart';

/// A widget that displays an attachment based on its type.
///
/// This widget determines the appropriate view for the given [attachment]
/// and renders it accordingly. Image content — byte-backed image files and
/// links with an `image/` MIME type — renders as an image; other files and
/// links render as file and link previews.
@immutable
class AttachmentView extends StatelessWidget {
  /// Creates an AttachmentView.
  ///
  /// The [attachment] parameter must not be null.
  const AttachmentView(this.attachment, {super.key});

  /// The attachment to be displayed.
  final Attachment attachment;

  /// The style for the attachment view.

  @override
  Widget build(BuildContext context) => switch (attachment) {
    (final ImageFileAttachment a) => ImageAttachmentView(a),
    (final LinkAttachment a) when a.isImage => ImageAttachmentView(a),
    (final FileAttachment a) => FileAttachmentView(a),
    (final LinkAttachment a) => LinkAttachmentView(a),
  };
}
