// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// by convention, using the names of the icons as the constant names
// ignore_for_file: constant_identifier_names

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

/// A collection of default icons used by the chat UI.
@immutable
class ToolkitIcons {
  const ToolkitIcons._();

  /// Icon for submitting or sending.
  static const IconData submit_icon = Icons.arrow_upward;

  /// Icon representing a spark or idea.
  static const IconData spark_icon = Icons.auto_awesome;

  /// Icon for adding or creating new items.
  static const IconData add = Icons.add;

  /// Icon for attaching files.
  static const IconData attach_file = Icons.attach_file;

  /// Icon for stopping or halting an action.
  static const IconData stop = Icons.stop;

  /// Icon representing a microphone.
  static const IconData mic = Icons.mic;

  /// Icon for closing or dismissing.
  static const IconData close = Icons.close;

  /// Icon representing a camera.
  static const IconData camera_alt = Icons.photo_camera_outlined;

  /// Icon representing an image or picture.
  static const IconData image = Icons.photo_outlined;

  /// Icon for editing.
  static const IconData edit = Icons.edit;

  /// Icon for copying content.
  static const IconData content_copy = Icons.copy;
}
