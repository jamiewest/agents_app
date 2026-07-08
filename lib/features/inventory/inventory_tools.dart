// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

import 'inventory_item.dart';
import 'inventory_store.dart';

/// The name of the tool that adds an inventory item.
const String addInventoryItemToolName = 'add_inventory_item';

/// The name of the tool that updates an inventory item.
const String updateInventoryItemToolName = 'update_inventory_item';

/// The name of the tool that removes an inventory item.
const String removeInventoryItemToolName = 'remove_inventory_item';

/// The name of the tool that finds inventory items.
const String findInventoryItemsToolName = 'find_inventory_items';

/// The name of the tool that summarizes the inventory.
const String summarizeInventoryToolName = 'summarize_inventory';

const Map<String, Object?> _itemPropertiesSchema = {
  'name': {
    'type': 'string',
    'description': 'What the item is, such as "Ryzen 9 7950X".',
  },
  'category': {
    'type': 'string',
    'description': 'A free-form grouping, such as "CPU" or "cable".',
  },
  'location': {
    'type': 'string',
    'description': 'Where the item is kept, such as "office shelf B".',
  },
  'condition': {
    'type': 'string',
    'description': 'The item condition, such as "new" or "used".',
  },
  'quantity': {
    'type': 'integer',
    'minimum': 0,
    'description': 'How many are on hand. Zero means out of stock.',
  },
  'unitPrice': {
    'type': 'number',
    'description': 'The per-unit value or purchase price.',
  },
  'tags': {
    'type': 'array',
    'items': {'type': 'string'},
    'description': 'Free-form labels for filtering, such as ["ddr5"].',
  },
  'attributes': {
    'type': 'object',
    'additionalProperties': {'type': 'string'},
    'description': 'Arbitrary item-specific fields, such as {"socket": "AM5"}.',
  },
  'notes': {'type': 'string', 'description': 'Free-form notes.'},
};

/// Creates the tools an agent uses to manage the shared item inventory in
/// [store]: add, update, remove, find/filter, and summarize.
List<AIFunction> createInventoryTools(InventoryStore store) => [
  _createAddTool(store),
  _createUpdateTool(store),
  _createRemoveTool(store),
  _createFindTool(store),
  _createSummarizeTool(store),
];

AIFunction _createAddTool(InventoryStore store) => AIFunctionFactory.create(
  name: addInventoryItemToolName,
  description:
      'Adds an item to the user\'s inventory and returns it with its '
      'assigned id. Use find_inventory_items first when the item may '
      'already exist — update its quantity instead of adding a duplicate.',
  parametersSchema: const {
    'type': 'object',
    'properties': _itemPropertiesSchema,
    'required': ['name'],
    'additionalProperties': false,
  },
  callback: (arguments, {CancellationToken? cancellationToken}) =>
      _catching(() async {
        final item = await store.add(
          name: arguments['name']?.toString() ?? '',
          category: arguments['category']?.toString(),
          location: arguments['location']?.toString(),
          condition: arguments['condition']?.toString(),
          quantity: (arguments['quantity'] as num?)?.toInt() ?? 1,
          unitPrice: (arguments['unitPrice'] as num?)?.toDouble(),
          tags: _stringList(arguments['tags']),
          attributes: _stringMap(arguments['attributes']),
          notes: arguments['notes']?.toString(),
        );
        return item.toJson();
      }),
);

AIFunction _createUpdateTool(InventoryStore store) => AIFunctionFactory.create(
  name: updateInventoryItemToolName,
  description:
      'Changes fields of an existing inventory item by id. Only the '
      'supplied fields change; pass an empty string to clear a text field. '
      'tags and attributes replace the stored values wholesale. Returns '
      'the updated item.',
  parametersSchema: {
    'type': 'object',
    'properties': {
      'id': const {'type': 'integer', 'description': 'The id of the item.'},
      ..._itemPropertiesSchema,
    },
    'required': const ['id'],
    'additionalProperties': false,
  },
  callback: (arguments, {CancellationToken? cancellationToken}) =>
      _catching(() async {
        final id = (arguments['id'] as num?)?.toInt();
        if (id == null) return _error('An integer "id" is required.');
        Object? text(String key) => arguments.containsKey(key)
            ? _normalizeOrNull(arguments[key]?.toString())
            : InventoryStore.unchanged;
        final item = await store.update(
          id,
          name: arguments.containsKey('name')
              ? arguments['name']?.toString()
              : InventoryStore.unchanged,
          category: text('category'),
          location: text('location'),
          condition: text('condition'),
          quantity: arguments.containsKey('quantity')
              ? (arguments['quantity'] as num?)?.toInt()
              : InventoryStore.unchanged,
          unitPrice: arguments.containsKey('unitPrice')
              ? (arguments['unitPrice'] as num?)?.toDouble()
              : InventoryStore.unchanged,
          tags: arguments.containsKey('tags')
              ? _stringList(arguments['tags'])
              : InventoryStore.unchanged,
          attributes: arguments.containsKey('attributes')
              ? _stringMap(arguments['attributes'])
              : InventoryStore.unchanged,
          notes: arguments.containsKey('notes')
              ? _normalizeOrNull(arguments['notes']?.toString())
              : InventoryStore.unchanged,
        );
        if (item == null) return _error('No inventory item with id $id.');
        return item.toJson();
      }),
);

AIFunction _createRemoveTool(InventoryStore store) => AIFunctionFactory.create(
  name: removeInventoryItemToolName,
  description:
      'Deletes an inventory item by id. To reduce a quantity instead of '
      'deleting the record, use update_inventory_item.',
  parametersSchema: const {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer', 'description': 'The id of the item.'},
    },
    'required': ['id'],
    'additionalProperties': false,
  },
  callback: (arguments, {CancellationToken? cancellationToken}) =>
      _catching(() async {
        final id = (arguments['id'] as num?)?.toInt();
        if (id == null) return _error('An integer "id" is required.');
        final removed = await store.remove(id);
        if (!removed) return _error('No inventory item with id $id.');
        return {'removed': true, 'id': id};
      }),
);

AIFunction _createFindTool(InventoryStore store) => AIFunctionFactory.create(
  name: findInventoryItemsToolName,
  description:
      'Finds inventory items, most recently updated first. All filters '
      'are optional and combine; with none, the newest items are listed. '
      'Use "query" for free-text search and the other filters for exact '
      '(case-insensitive) matches.',
  parametersSchema: const {
    'type': 'object',
    'properties': {
      'id': {
        'type': 'integer',
        'description': 'Look up one item by its exact id.',
      },
      'query': {
        'type': 'string',
        'description':
            'Free text matched against name, category, location, '
            'condition, notes, tags, and attributes.',
      },
      'category': {'type': 'string', 'description': 'Exact category.'},
      'location': {'type': 'string', 'description': 'Exact location.'},
      'condition': {'type': 'string', 'description': 'Exact condition.'},
      'tag': {'type': 'string', 'description': 'Exact tag.'},
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'description': 'Maximum items to return. Defaults to 50.',
      },
    },
    'additionalProperties': false,
  },
  callback: (arguments, {CancellationToken? cancellationToken}) =>
      _catching(() async {
        final items = await store.find(
          id: (arguments['id'] as num?)?.toInt(),
          query: arguments['query']?.toString(),
          category: arguments['category']?.toString(),
          location: arguments['location']?.toString(),
          condition: arguments['condition']?.toString(),
          tag: arguments['tag']?.toString(),
          limit: (arguments['limit'] as num?)?.toInt() ?? 50,
        );
        return {
          'count': items.length,
          'items': [for (final InventoryItem item in items) item.toJson()],
        };
      }),
);

AIFunction _createSummarizeTool(InventoryStore store) =>
    AIFunctionFactory.create(
      name: summarizeInventoryToolName,
      description:
          'Reports inventory totals — distinct items, summed quantity, and '
          'total value — with a per-group breakdown. Items without a unit '
          'price contribute nothing to value totals.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'groupBy': {
            'type': 'string',
            'enum': ['category', 'location', 'condition'],
            'description':
                'The field to break totals down by. Defaults to '
                'category.',
          },
        },
        'additionalProperties': false,
      },
      callback: (arguments, {CancellationToken? cancellationToken}) =>
          _catching(() async {
            final groupByName = arguments['groupBy']?.toString();
            final groupBy = InventoryGroupBy.values.asNameMap()[groupByName];
            if (groupByName != null && groupBy == null) {
              return _error(
                'Unknown groupBy "$groupByName"; use category, location, '
                'or condition.',
              );
            }
            final summary = await store.summarize(
              groupBy: groupBy ?? InventoryGroupBy.category,
            );
            return summary.toJson();
          }),
    );

/// Runs [action], converting validation failures into an error result the
/// model can read and correct instead of an aborted run.
Future<Map<String, Object?>> _catching(
  Future<Map<String, Object?>> Function() action,
) async {
  try {
    return await action();
  } on ArgumentError catch (error) {
    return _error('Invalid ${error.name}: ${error.message}.');
  }
}

Map<String, Object?> _error(String message) => {'error': message};

List<String> _stringList(Object? value) =>
    value is List ? [for (final entry in value) entry.toString()] : const [];

Map<String, String> _stringMap(Object? value) => value is Map
    ? value.map((key, entry) => MapEntry(key.toString(), entry.toString()))
    : const {};

String? _normalizeOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
