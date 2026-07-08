// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'inventory_item.dart';

/// The field a [InventoryStore.summarize] call groups by.
enum InventoryGroupBy {
  /// Group by the item category.
  category('category'),

  /// Group by the item location.
  location('location'),

  /// Group by the item condition.
  condition('condition');

  const InventoryGroupBy(this.column);

  /// The backing database column.
  final String column;
}

/// One group of an [InventorySummary].
class InventoryGroup {
  /// Creates a summary group.
  const InventoryGroup({
    required this.name,
    required this.itemCount,
    required this.totalQuantity,
    required this.totalValue,
  });

  /// The group's value, or `(unspecified)` when items have none.
  final String name;

  /// How many distinct items fall in the group.
  final int itemCount;

  /// The summed quantity across the group's items.
  final int totalQuantity;

  /// The summed `quantity * unitPrice` across the group's items.
  ///
  /// Items without a unit price contribute nothing.
  final double totalValue;

  /// A JSON-friendly view of this group.
  Map<String, Object?> toJson() => {
    'name': name,
    'itemCount': itemCount,
    'totalQuantity': totalQuantity,
    'totalValue': totalValue,
  };
}

/// Aggregate statistics over the whole inventory.
class InventorySummary {
  /// Creates a summary.
  const InventorySummary({
    required this.itemCount,
    required this.totalQuantity,
    required this.totalValue,
    required this.groupedBy,
    required this.groups,
  });

  /// How many distinct items exist.
  final int itemCount;

  /// The summed quantity across all items.
  final int totalQuantity;

  /// The summed `quantity * unitPrice` across all items.
  ///
  /// Items without a unit price contribute nothing.
  final double totalValue;

  /// The field the [groups] are keyed by.
  final InventoryGroupBy groupedBy;

  /// Per-group breakdowns, largest item count first.
  final List<InventoryGroup> groups;

  /// A JSON-friendly view of this summary.
  Map<String, Object?> toJson() => {
    'itemCount': itemCount,
    'totalQuantity': totalQuantity,
    'totalValue': totalValue,
    'groupedBy': groupedBy.name,
    'groups': [for (final group in groups) group.toJson()],
  };
}

/// Durable app-wide item inventory backed by SQLite.
///
/// The database opens lazily on first use. Construction is cheap, so the
/// store can be registered as a synchronous singleton; supply a
/// [DatabaseFactory] and path resolver so tests can run against an
/// in-memory ffi database.
class InventoryStore {
  /// Creates a store over [databaseFactory].
  ///
  /// [resolvePath] returns the database file path (or an in-memory path in
  /// tests); it is awaited once, when the database first opens.
  InventoryStore(DatabaseFactory databaseFactory, {required this._resolvePath})
    : _databaseFactory = databaseFactory;

  /// Sentinel for [update] parameters that keep their current value.
  ///
  /// Distinguishes "not provided" from an explicit `null`, which clears the
  /// field.
  static const Object unchanged = _Unchanged();

  static const String _table = 'inventory_items';

  final DatabaseFactory _databaseFactory;
  final Future<String> Function() _resolvePath;
  Future<Database>? _database;

  Future<Database> _open() => _database ??= _openDatabase();

  Future<Database> _openDatabase() async => _databaseFactory.openDatabase(
    await _resolvePath(),
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category TEXT,
            location TEXT,
            condition TEXT,
            quantity INTEGER NOT NULL DEFAULT 1,
            unit_price REAL,
            tags TEXT NOT NULL DEFAULT '[]',
            attributes TEXT NOT NULL DEFAULT '{}',
            notes TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX ${_table}_category ON $_table (category)',
        );
      },
    ),
  );

  String _now() => DateTime.now().toUtc().toIso8601String();

  /// Adds a new item and returns it with its assigned id.
  ///
  /// Throws [ArgumentError] when [name] is blank or [quantity] is negative.
  Future<InventoryItem> add({
    required String name,
    String? category,
    String? location,
    String? condition,
    int quantity = 1,
    double? unitPrice,
    List<String> tags = const [],
    Map<String, String> attributes = const {},
    String? notes,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be blank');
    }
    if (quantity < 0) {
      throw ArgumentError.value(quantity, 'quantity', 'must not be negative');
    }
    final db = await _open();
    final now = _now();
    final item = InventoryItem(
      id: 0,
      name: name.trim(),
      category: _normalize(category),
      location: _normalize(location),
      condition: _normalize(condition),
      quantity: quantity,
      unitPrice: unitPrice,
      tags: tags,
      attributes: attributes,
      notes: _normalize(notes),
      createdAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
    );
    final id = await db.insert(_table, item.toRow());
    return (await get(id))!;
  }

  /// Returns the item with [id], or `null` when it does not exist.
  Future<InventoryItem?> get(int id) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : InventoryItem.fromRow(rows.first);
  }

  /// Applies the provided changes to the item with [id].
  ///
  /// Parameters left at [unchanged] keep their current value; an explicit
  /// `null` clears the field. [tags] and [attributes] replace the stored
  /// value wholesale. Returns the updated item, or `null` when no item has
  /// [id].
  Future<InventoryItem?> update(
    int id, {
    Object? name = unchanged,
    Object? category = unchanged,
    Object? location = unchanged,
    Object? condition = unchanged,
    Object? quantity = unchanged,
    Object? unitPrice = unchanged,
    Object? tags = unchanged,
    Object? attributes = unchanged,
    Object? notes = unchanged,
  }) async {
    final values = <String, Object?>{};
    if (!identical(name, unchanged)) {
      final newName = (name as String?)?.trim();
      if (newName == null || newName.isEmpty) {
        throw ArgumentError.value(name, 'name', 'must not be blank');
      }
      values['name'] = newName;
    }
    if (!identical(category, unchanged)) {
      values['category'] = _normalize(category as String?);
    }
    if (!identical(location, unchanged)) {
      values['location'] = _normalize(location as String?);
    }
    if (!identical(condition, unchanged)) {
      values['condition'] = _normalize(condition as String?);
    }
    if (!identical(quantity, unchanged)) {
      final newQuantity = quantity! as int;
      if (newQuantity < 0) {
        throw ArgumentError.value(
          newQuantity,
          'quantity',
          'must not be negative',
        );
      }
      values['quantity'] = newQuantity;
    }
    if (!identical(unitPrice, unchanged)) {
      values['unit_price'] = (unitPrice as num?)?.toDouble();
    }
    if (!identical(tags, unchanged)) {
      values['tags'] = jsonEncode(tags as List<String>? ?? const <String>[]);
    }
    if (!identical(attributes, unchanged)) {
      values['attributes'] = jsonEncode(
        attributes as Map<String, String>? ?? const <String, String>{},
      );
    }
    if (!identical(notes, unchanged)) {
      values['notes'] = _normalize(notes as String?);
    }
    if (values.isEmpty) return get(id);

    values['updated_at'] = _now();
    final db = await _open();
    final updated = await db.update(
      _table,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
    return updated == 0 ? null : get(id);
  }

  /// Deletes the item with [id]; returns whether an item was removed.
  Future<bool> remove(int id) async {
    final db = await _open();
    return await db.delete(_table, where: 'id = ?', whereArgs: [id]) > 0;
  }

  /// Finds items matching every provided filter, most recently updated
  /// first.
  ///
  /// [query] matches case-insensitively across name, category, location,
  /// condition, notes, tags, and attributes. [category], [location], and
  /// [condition] match their field exactly (case-insensitively); [tag]
  /// matches one tag exactly (case-insensitively).
  Future<List<InventoryItem>> find({
    int? id,
    String? query,
    String? category,
    String? location,
    String? condition,
    String? tag,
    int limit = 50,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (id != null) {
      where.add('id = ?');
      args.add(id);
    }
    void exact(String column, String? value) {
      if (value == null || value.trim().isEmpty) return;
      where.add("LOWER(IFNULL($column, '')) = ?");
      args.add(value.trim().toLowerCase());
    }

    exact('category', category);
    exact('location', location);
    exact('condition', condition);
    if (tag != null && tag.trim().isNotEmpty) {
      where.add('LOWER(tags) LIKE ?');
      args.add('%${jsonEncode(tag.trim().toLowerCase())}%');
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add(
        "LOWER(name || ' ' || IFNULL(category, '') || ' ' || "
        "IFNULL(location, '') || ' ' || IFNULL(condition, '') || ' ' || "
        "IFNULL(notes, '') || ' ' || tags || ' ' || attributes) LIKE ?",
      );
      args.add('%${query.trim().toLowerCase()}%');
    }

    final db = await _open();
    final rows = await db.query(
      _table,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
    );
    return [for (final row in rows) InventoryItem.fromRow(row)];
  }

  /// Aggregates counts, quantities, and value over the whole inventory,
  /// broken down by [groupBy].
  Future<InventorySummary> summarize({
    InventoryGroupBy groupBy = InventoryGroupBy.category,
  }) async {
    final db = await _open();
    final totals = (await db.rawQuery(
      'SELECT COUNT(*) AS item_count, '
      'IFNULL(SUM(quantity), 0) AS total_quantity, '
      'IFNULL(SUM(quantity * unit_price), 0) AS total_value '
      'FROM $_table',
    )).first;
    final groupRows = await db.rawQuery(
      "SELECT IFNULL(${groupBy.column}, '') AS group_name, "
      'COUNT(*) AS item_count, '
      'IFNULL(SUM(quantity), 0) AS total_quantity, '
      'IFNULL(SUM(quantity * unit_price), 0) AS total_value '
      'FROM $_table GROUP BY group_name '
      'ORDER BY item_count DESC, group_name ASC',
    );
    return InventorySummary(
      itemCount: totals['item_count']! as int,
      totalQuantity: (totals['total_quantity']! as num).toInt(),
      totalValue: (totals['total_value']! as num).toDouble(),
      groupedBy: groupBy,
      groups: [
        for (final row in groupRows)
          InventoryGroup(
            name: (row['group_name']! as String).isEmpty
                ? '(unspecified)'
                : row['group_name']! as String,
            itemCount: row['item_count']! as int,
            totalQuantity: (row['total_quantity']! as num).toInt(),
            totalValue: (row['total_value']! as num).toDouble(),
          ),
      ],
    );
  }

  /// Closes the database if it was opened.
  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) await (await database).close();
  }

  /// Closes the store and deletes the database file.
  Future<void> destroy() async {
    await close();
    await _databaseFactory.deleteDatabase(await _resolvePath());
  }

  static String? _normalize(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _Unchanged {
  const _Unchanged();
}
