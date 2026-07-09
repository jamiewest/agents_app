// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// by convention, using the names of the icons as the constant names
// ignore_for_file: constant_identifier_names

import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

/// A collection of default icons used by the chat UI.
@immutable
class ToolkitIcons {
  const ToolkitIcons._();

  /// Icon for submitting or sending.
  static const IconData submit_icon = Symbols.arrow_upward;

  /// Icon representing a spark or idea.
  static const IconData spark_icon = Symbols.auto_awesome;

  /// Icon for adding or creating new items.
  static const IconData add = Symbols.add;

  /// Icon for attaching files.
  static const IconData attach_file = Symbols.attach_file;

  /// Icon for stopping or halting an action.
  static const IconData stop = Symbols.stop;

  /// Icon representing a microphone.
  static const IconData mic = Symbols.mic;

  /// Icon for closing or dismissing.
  static const IconData close = Symbols.close;

  /// Icon representing a camera.
  static const IconData camera_alt = Symbols.photo_camera;

  /// Icon representing an image or picture.
  static const IconData image = Symbols.photo;

  /// Icon representing a link or URL.
  static const IconData link = Symbols.link;

  /// Icon for editing.
  static const IconData edit = Symbols.edit;

  /// Icon for copying content.
  static const IconData content_copy = Symbols.content_copy;
}
