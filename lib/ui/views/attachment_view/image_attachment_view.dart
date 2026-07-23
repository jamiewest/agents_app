// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../dialogs/adaptive_dialog.dart';
import '../../dialogs/image_preview_dialog.dart';
import '../../providers/interface/attachments.dart';

/// A widget that displays an image attachment in a chat message.
///
/// Renders byte-backed images ([ImageFileAttachment]) and image-valued
/// [LinkAttachment]s with loading and error placeholders. Tapping the image
/// opens the full-size [ImagePreviewDialog].
@immutable
class ImageAttachmentView extends StatelessWidget {
  /// Creates an ImageAttachmentView.
  ///
  /// The [attachment] must satisfy [Attachment.isImage].
  ImageAttachmentView(
    this.attachment, {
    this.maxHeight = 360,
    this.fit = BoxFit.contain,
    super.key,
  }) : assert(attachment.isImage);

  /// The image attachment to be displayed.
  final Attachment attachment;

  /// The maximum height the rendered image may occupy.
  final double maxHeight;

  /// How the image is inscribed into the available space.
  final BoxFit fit;

  static const double _placeholderHeight = 160;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: maxHeight),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Semantics(
        button: true,
        label: 'Open image ${attachment.name}',
        child: GestureDetector(
          onTap: () => unawaited(_showPreviewDialog(context)),
          child: switch (attachment) {
            (final ImageFileAttachment a) => Image.memory(
              a.bytes,
              width: double.infinity,
              fit: fit,
              errorBuilder: (context, _, _) => _BrokenImagePlaceholder(
                name: attachment.name,
                height: _placeholderHeight,
              ),
            ),
            (FileAttachment _) => throw AssertionError(
              'File attachments not supported in image attachment view',
            ),
            (final LinkAttachment a) => Image.network(
              a.url.toString(),
              width: double.infinity,
              fit: fit,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const SizedBox(
                      height: _placeholderHeight,
                      child: Center(
                        child: SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
              errorBuilder: (context, _, _) => _BrokenImagePlaceholder(
                name: attachment.name,
                height: _placeholderHeight,
              ),
            ),
          },
        ),
      ),
    ),
  );

  Future<void> _showPreviewDialog(BuildContext context) async =>
      AdaptiveAlertDialog.show<void>(
        context: context,
        content: ImagePreviewDialog(attachment),
      );
}

/// A stable placeholder shown when an image fails to load or decode.
@immutable
class _BrokenImagePlaceholder extends StatelessWidget {
  const _BrokenImagePlaceholder({required this.name, required this.height});

  final String name;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.imageOff300, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              name,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
