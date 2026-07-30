import 'package:flutter/material.dart';

/// A popup-menu row: leading icon plus label, tinted when [selected].
class ChatMenuLabel extends StatelessWidget {
  const ChatMenuLabel({
    required this.icon,
    required this.label,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : null;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
