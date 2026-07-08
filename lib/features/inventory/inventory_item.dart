// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A single tracked inventory item.
///
/// The shape is intentionally generic so any kind of item can be tracked:
/// the typed columns cover what every physical item has (a name, where it
/// is, how many, what it cost), while [tags] and [attributes] carry
/// domain-specific details — for computer parts, attributes like
/// `"socket": "AM5"` or `"capacity": "2TB"`.
@immutable
class InventoryItem {
  /// Creates an inventory item.
  const InventoryItem({
    required this.id,
    required this.name,
    this.category,
    this.location,
    this.condition,
    this.quantity = 1,
    this.unitPrice,
    this.tags = const [],
    this.attributes = const {},
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Reads an item from a database [row].
  factory InventoryItem.fromRow(Map<String, Object?> row) => InventoryItem(
    id: row['id']! as int,
    name: row['name']! as String,
    category: row['category'] as String?,
    location: row['location'] as String?,
    condition: row['condition'] as String?,
    quantity: row['quantity']! as int,
    unitPrice: (row['unit_price'] as num?)?.toDouble(),
    tags: (jsonDecode(row['tags']! as String) as List)
        .map((tag) => tag.toString())
        .toList(),
    attributes: (jsonDecode(row['attributes']! as String) as Map).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    notes: row['notes'] as String?,
    createdAt: DateTime.parse(row['created_at']! as String),
    updatedAt: DateTime.parse(row['updated_at']! as String),
  );

  /// The database-assigned identifier.
  final int id;

  /// What the item is, e.g. "Ryzen 9 7950X".
  final String name;

  /// A free-form grouping, e.g. "CPU" or "cable".
  final String? category;

  /// Where the item is kept, e.g. "office shelf B".
  final String? location;

  /// The item's condition, e.g. "new" or "used".
  final String? condition;

  /// How many of the item are on hand. Zero is valid (out of stock).
  final int quantity;

  /// The per-unit value or purchase price, when known.
  final double? unitPrice;

  /// Free-form labels for filtering, e.g. `["ddr5", "spare"]`.
  final List<String> tags;

  /// Arbitrary domain-specific fields, e.g. `{"socket": "AM5"}`.
  final Map<String, String> attributes;

  /// Free-form notes.
  final String? notes;

  /// When the item was first added (UTC).
  final DateTime createdAt;

  /// When the item was last changed (UTC).
  final DateTime updatedAt;

  /// The database column values for this item, without the id.
  Map<String, Object?> toRow() => {
    'name': name,
    'category': category,
    'location': location,
    'condition': condition,
    'quantity': quantity,
    'unit_price': unitPrice,
    'tags': jsonEncode(tags),
    'attributes': jsonEncode(attributes),
    'notes': notes,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// A JSON-friendly view of this item, as returned by the inventory tools.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (category != null) 'category': category,
    if (location != null) 'location': location,
    if (condition != null) 'condition': condition,
    'quantity': quantity,
    if (unitPrice != null) 'unitPrice': unitPrice,
    if (tags.isNotEmpty) 'tags': tags,
    if (attributes.isNotEmpty) 'attributes': attributes,
    if (notes != null) 'notes': notes,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
