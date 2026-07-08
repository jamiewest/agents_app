// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../providers/interface/attachments.dart';
import '../../styles/toolkit_text_styles.dart';

/// A widget that displays a link attachment with a preview.
///
/// This widget shows a rich preview of a web link including:
/// - Website favicon (loaded from multiple possible locations)
/// - Page title (extracted from URL or provided in attachment)
/// - Domain name (formatted for display)
///
///
/// Example:
/// ```dart
/// LinkAttachmentView(
///   LinkAttachment(
///     name: 'Flutter',
///     url: Uri.parse('https://flutter.dev'),
///   ),
/// )
/// ```
@immutable
class LinkAttachmentView extends StatelessWidget {
  /// Creates a [LinkAttachmentView] for the given [attachment].
  ///
  /// The [attachment] must not be null and should contain at least a valid URL.
  /// If [attachment.name] is provided, it will be used as the display title.
  LinkAttachmentView(this.attachment, {super.key}) : _contextKey = GlobalKey();

  /// The link attachment to display.
  final LinkAttachment attachment;
  final GlobalKey _contextKey;

  /// Cache for favicon URLs to avoid repeated generation.
  static final _faviconCache = <String, String>{};

  /// Clears the favicon cache.
  static void clearFaviconCache() => _faviconCache.clear();

  @override
  Widget build(BuildContext context) {
    return Builder(
      key: _contextKey,
      builder: (context) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyles = ToolkitTextStyles.fromTheme(context);

    return Container(
      width: 300,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Image.network(
                  _getFaviconUrl(attachment.url),
                  width: 16,
                  height: 16,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Symbols.link,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                        if (frame == null) {
                          return Icon(
                            Symbols.link,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          );
                        }
                        return child;
                      },
                ),
              ),
              Expanded(
                child: Text(
                  _getDisplayUrl(attachment.url),
                  style: textStyles.label.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _getPageTitle(attachment),
            style: textStyles.body1.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Generates a favicon URL for the given [uri] using multiple strategies.
  ///
  /// Tries multiple common favicon locations and caches the result.
  /// Returns a URL that can be used to load the favicon.
  String _getFaviconUrl(Uri uri) {
    final host = uri.host;

    if (_faviconCache.containsKey(host)) {
      return _faviconCache[host]!;
    }

    final urls = [
      'https://${uri.host}/favicon.ico',
      'https://${uri.host}/favicon.png',
      'https://${uri.host}/favicon.jpg',
      'https://${uri.host}/favicon.svg',
      'https://www.google.com/s2/favicons?domain=${uri.host}&sz=32',
      'https://icons.duckduckgo.com/ip3/${uri.host}.ico',
    ];

    final url = urls.first;
    _faviconCache[host] = url;
    return url;
  }

  /// Extracts a human-readable title from a URI.
  ///
  /// Handles various URL formats and cleans up the result.
  String _extractTitleFromUrl(Uri uri) {
    if (uri.path.isNotEmpty && uri.path != '/') {
      return uri.path
          .split('/')
          .last
          .split('.')
          .first
          .replaceAll(RegExp(r'[-_.+]'), ' ')
          .trim()
          .split(' ')
          .map(
            (s) => s.isNotEmpty ? '${s[0].toUpperCase()}${s.substring(1)}' : '',
          )
          .join(' ');
    }

    return _formatDomain(uri.host);
  }

  /// Formats a domain name for display.
  ///
  /// Removes common prefixes and formats the domain in a user-friendly way.
  String _formatDomain(String domain) {
    return domain
        .replaceAll(RegExp(r'^www\.'), '')
        .split('.')
        .map(
          (s) => s.isNotEmpty ? '${s[0].toUpperCase()}${s.substring(1)}' : '',
        )
        .join('.');
  }

  /// Gets a display-friendly version of a URL.
  ///
  /// Removes protocol, www prefix, and standard ports for cleaner display.
  String _getDisplayUrl(Uri uri) {
    String host = uri.host.replaceAll(RegExp(r'^www\.'), '');

    if (uri.hasPort && uri.port != 80 && uri.port != 443) {
      host = '$host:${uri.port}';
    }

    final path = uri.path;
    if (path.isNotEmpty && path != '/' && path.length < 30) {
      return '$host$path';
    }

    return host;
  }

  /// Gets the most appropriate title for the link.
  ///
  /// Uses the attachment name if provided and not the same as the URL.
  /// Otherwise, extracts a title from the URL.
  String _getPageTitle(LinkAttachment attachment) {
    if (attachment.name.isNotEmpty &&
        attachment.name != attachment.url.toString() &&
        !attachment.name.startsWith('http')) {
      return attachment.name;
    }
    return _extractTitleFromUrl(attachment.url);
  }
}
