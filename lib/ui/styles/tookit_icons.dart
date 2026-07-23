// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// by convention, using the names of the icons as the constant names
// ignore_for_file: constant_identifier_names

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A collection of default icons used by the chat UI.
@immutable
class ToolkitIcons {
  const ToolkitIcons._();

  /// Icon for submitting or sending.
  static const IconData submit_icon = LucideIcons.arrowUp300;

  /// Icon representing a spark or idea.
  static const IconData spark_icon = LucideIcons.sparkles300;

  /// Icon for adding or creating new items.
  static const IconData add = LucideIcons.plus300;

  /// Icon for attaching files.
  static const IconData attach_file = LucideIcons.paperclip300;

  /// Icon for stopping or halting an action.
  static const IconData stop = LucideIcons.circleStop300;

  /// Icon representing a microphone.
  static const IconData mic = LucideIcons.mic300;

  /// Icon for closing or dismissing.
  static const IconData close = LucideIcons.x300;

  /// Icon representing a camera.
  static const IconData camera_alt = LucideIcons.camera300;

  /// Icon representing an image or picture.
  static const IconData image = LucideIcons.image300;

  /// Icon representing a link or URL.
  static const IconData link = LucideIcons.link300;

  /// Icon for editing.
  static const IconData edit = LucideIcons.pencil300;

  /// Icon for copying content.
  static const IconData content_copy = LucideIcons.copy300;
}
