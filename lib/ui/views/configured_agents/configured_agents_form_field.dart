// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import '../../styles/configured_agents_style.dart';

/// A labelled text form field styled by [ConfiguredAgentsStyle].
///
/// Used by the source/model/agent editors so every field shares the same
/// compact, restrained look as the rest of the toolkit.
class ConfiguredAgentsFormField extends StatelessWidget {
  /// Creates a [ConfiguredAgentsFormField].
  const ConfiguredAgentsFormField({
    required this.label,
    required this.controller,
    required this.style,
    this.hintText,
    this.keyboardType,
    this.maxLines = 1,
    this.obscureText = false,
    this.validator,
    super.key,
  });

  /// The field label shown above the input.
  final String label;

  /// The editing controller for the field.
  final TextEditingController controller;

  /// Resolved style supplying colors and text styles.
  final ConfiguredAgentsStyle style;

  /// Optional placeholder text.
  final String? hintText;

  /// Optional keyboard type.
  final TextInputType? keyboardType;

  /// Number of lines for the input.
  final int maxLines;

  /// Whether to obscure input (e.g. API keys).
  final bool obscureText;

  /// Optional validator.
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: style.dividerColor ?? Theme.of(context).dividerColor,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: style.labelTextStyle),
          const SizedBox(height: 6),
          TextFormField(
            controller: controller,
            keyboardType: keyboardType,
            maxLines: obscureText ? 1 : maxLines,
            obscureText: obscureText,
            validator: validator,
            style: style.bodyTextStyle,
            decoration: InputDecoration(
              isDense: true,
              hintText: hintText,
              hintStyle: style.hintTextStyle,
              border: border,
              enabledBorder: border,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
