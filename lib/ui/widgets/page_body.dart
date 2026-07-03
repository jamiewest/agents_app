// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

/// Centers page content with a comfortable reading width.
///
/// Forms and settings stretched edge-to-edge look broken on wide layouts;
/// every non-chat screen wraps its body in this.
class PageBody extends StatelessWidget {
  /// Creates a [PageBody].
  const PageBody({
    required this.child,
    this.maxWidth = 720,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  /// The page content.
  final Widget child;

  /// Maximum content width.
  final double maxWidth;

  /// Padding inside the constrained area.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(padding: padding, child: child),
    ),
  );
}
