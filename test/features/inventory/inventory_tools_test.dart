// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:agents_app/features/inventory/inventory_store.dart';
import 'package:agents_app/features/inventory/inventory_tools.dart';
import 'package:extensions/ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late InventoryStore store;
  late List<AIFunction> tools;

  AIFunction tool(String name) =>
      tools.singleWhere((tool) => tool.name == name);

  Future<Map<String, Object?>> invoke(
    String name,
    Map<String, Object?> arguments,
  ) async =>
      await tool(name).invoke(AIFunctionArguments(arguments))
          as Map<String, Object?>;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('inventory_tools_test');
    store = InventoryStore(
      databaseFactoryFfi,
      resolvePath: () async => path.join(tempDir.path, 'inventory.db'),
    );
    tools = createInventoryTools(store);
  });

  tearDown(() async {
    await store.destroy();
    await tempDir.delete(recursive: true);
  });

  test('exposes the five inventory tools', () {
    expect(
      [for (final tool in tools) tool.name],
      [
        addInventoryItemToolName,
        updateInventoryItemToolName,
        removeInventoryItemToolName,
        findInventoryItemsToolName,
        summarizeInventoryToolName,
      ],
    );
  });

  test('add_inventory_item stores and returns the item', () async {
    final result = await invoke(addInventoryItemToolName, {
      'name': 'Ryzen 9 7950X',
      'category': 'CPU',
      'quantity': 2,
      'unitPrice': 549.99,
      'tags': ['am5'],
      'attributes': {'socket': 'AM5'},
    });

    expect(result['id'], isA<int>());
    expect(result['name'], 'Ryzen 9 7950X');
    expect(result['quantity'], 2);
    expect(result['tags'], ['am5']);
    expect(result['attributes'], {'socket': 'AM5'});

    final stored = await store.get(result['id']! as int);
    expect(stored!.category, 'CPU');
  });

  test('add_inventory_item reports invalid input as an error', () async {
    final result = await invoke(addInventoryItemToolName, {'name': '  '});
    expect(result['error'], contains('name'));
  });

  test('update_inventory_item changes provided fields and clears with '
      'empty strings', () async {
    final added = await store.add(
      name: 'DDR5 kit',
      location: 'bin 3',
      quantity: 4,
    );

    final result = await invoke(updateInventoryItemToolName, {
      'id': added.id,
      'quantity': 3,
      'location': '',
    });

    expect(result['quantity'], 3);
    expect(result.containsKey('location'), isFalse);
    expect(result['name'], 'DDR5 kit');
  });

  test('update_inventory_item errors on unknown ids', () async {
    final result = await invoke(updateInventoryItemToolName, {
      'id': 9999,
      'quantity': 1,
    });
    expect(result['error'], contains('9999'));
  });

  test('remove_inventory_item deletes and errors on unknown ids', () async {
    final added = await store.add(name: 'GPU riser');

    final removed = await invoke(removeInventoryItemToolName, {'id': added.id});
    expect(removed, {'removed': true, 'id': added.id});
    expect(await store.get(added.id), isNull);

    final again = await invoke(removeInventoryItemToolName, {'id': added.id});
    expect(again['error'], contains('${added.id}'));
  });

  test('find_inventory_items searches and filters', () async {
    await store.add(name: 'WD SN850X', category: 'SSD');
    await store.add(name: 'Samsung 990 Pro', category: 'SSD');
    await store.add(name: 'HDMI cable', category: 'cable');

    final byQuery = await invoke(findInventoryItemsToolName, {
      'query': 'samsung',
    });
    expect(byQuery['count'], 1);

    final byCategory = await invoke(findInventoryItemsToolName, {
      'category': 'ssd',
    });
    expect(byCategory['count'], 2);

    final all = await invoke(findInventoryItemsToolName, {});
    expect(all['count'], 3);
  });

  test('summarize_inventory reports totals and validates groupBy', () async {
    await store.add(
      name: 'SSD',
      category: 'storage',
      quantity: 2,
      unitPrice: 100,
    );
    await store.add(
      name: 'HDD',
      category: 'storage',
      quantity: 1,
      unitPrice: 50,
    );

    final summary = await invoke(summarizeInventoryToolName, {});
    expect(summary['itemCount'], 2);
    expect(summary['totalQuantity'], 3);
    expect(summary['totalValue'], 250);
    expect(summary['groupedBy'], 'category');

    final invalid = await invoke(summarizeInventoryToolName, {
      'groupBy': 'color',
    });
    expect(invalid['error'], contains('color'));
  });
}
