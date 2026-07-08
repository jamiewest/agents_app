// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:agents_app/features/inventory/inventory_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late InventoryStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('inventory_store_test');
    store = InventoryStore(
      databaseFactoryFfi,
      resolvePath: () async => path.join(tempDir.path, 'inventory.db'),
    );
  });

  tearDown(() async {
    await store.destroy();
    await tempDir.delete(recursive: true);
  });

  test('add assigns ids and round-trips every field', () async {
    final item = await store.add(
      name: '  Ryzen 9 7950X ',
      category: 'CPU',
      location: 'office shelf B',
      condition: 'new',
      quantity: 2,
      unitPrice: 549.99,
      tags: const ['am5', 'spare'],
      attributes: const {'socket': 'AM5', 'cores': '16'},
      notes: 'Bought for the build server.',
    );

    expect(item.id, greaterThan(0));
    expect(item.name, 'Ryzen 9 7950X');
    expect(item.category, 'CPU');
    expect(item.location, 'office shelf B');
    expect(item.condition, 'new');
    expect(item.quantity, 2);
    expect(item.unitPrice, 549.99);
    expect(item.tags, ['am5', 'spare']);
    expect(item.attributes, {'socket': 'AM5', 'cores': '16'});
    expect(item.notes, 'Bought for the build server.');

    final loaded = await store.get(item.id);
    expect(loaded, isNotNull);
    expect(loaded!.toJson(), item.toJson());
  });

  test('add rejects blank names and negative quantities', () async {
    expect(() => store.add(name: '  '), throwsArgumentError);
    expect(() => store.add(name: 'SSD', quantity: -1), throwsArgumentError);
  });

  test('update changes only the provided fields', () async {
    final item = await store.add(
      name: 'DDR5 kit',
      category: 'RAM',
      location: 'bin 3',
      quantity: 4,
    );

    final updated = await store.update(item.id, quantity: 3);
    expect(updated!.quantity, 3);
    expect(updated.name, 'DDR5 kit');
    expect(updated.category, 'RAM');
    expect(updated.location, 'bin 3');
  });

  test('update clears fields with an explicit null', () async {
    final item = await store.add(name: 'SATA cable', location: 'drawer');
    final updated = await store.update(item.id, location: null);
    expect(updated!.location, isNull);
  });

  test('update returns null for an unknown id', () async {
    expect(await store.update(9999, quantity: 1), isNull);
  });

  test('update rejects blank names and negative quantities', () async {
    final item = await store.add(name: 'PSU');
    expect(() => store.update(item.id, name: ' '), throwsArgumentError);
    expect(() => store.update(item.id, quantity: -2), throwsArgumentError);
  });

  test('remove deletes the item and reports unknown ids', () async {
    final item = await store.add(name: 'GPU riser');
    expect(await store.remove(item.id), isTrue);
    expect(await store.get(item.id), isNull);
    expect(await store.remove(item.id), isFalse);
  });

  test('find matches free text across fields, case-insensitively', () async {
    await store.add(name: 'Noctua NH-D15', category: 'cooler');
    await store.add(name: 'Corsair RM850x', notes: 'modular PSU');
    await store.add(name: 'CAT6 cable', attributes: const {'length': '2m'});

    expect((await store.find(query: 'noctua')).single.name, 'Noctua NH-D15');
    expect((await store.find(query: 'MODULAR')).single.name, 'Corsair RM850x');
    expect((await store.find(query: '2m')).single.name, 'CAT6 cable');
    expect(await store.find(query: 'missing'), isEmpty);
  });

  test('find filters by exact field values and tag', () async {
    await store.add(name: 'WD SN850X', category: 'SSD', location: 'bin 1');
    await store.add(
      name: 'Samsung 990 Pro',
      category: 'SSD',
      location: 'bin 2',
      tags: const ['nvme', 'Spare'],
    );
    await store.add(name: 'HDMI cable', category: 'cable', location: 'bin 1');

    expect((await store.find(category: 'ssd')).length, 2);
    expect((await store.find(location: 'bin 1')).length, 2);
    expect(
      (await store.find(category: 'SSD', location: 'bin 1')).single.name,
      'WD SN850X',
    );
    expect((await store.find(tag: 'spare')).single.name, 'Samsung 990 Pro');
  });

  test('find looks up by id and honors the limit', () async {
    final first = await store.add(name: 'Fan splitter');
    await store.add(name: 'Thermal paste');
    await store.add(name: 'Zip ties');

    expect((await store.find(id: first.id)).single.name, 'Fan splitter');
    expect((await store.find(limit: 2)).length, 2);
  });

  test('summarize aggregates counts, quantities, and value', () async {
    await store.add(
      name: 'SN850X',
      category: 'SSD',
      quantity: 2,
      unitPrice: 100,
    );
    await store.add(
      name: '990 Pro',
      category: 'SSD',
      quantity: 1,
      unitPrice: 150,
    );
    await store.add(name: 'HDMI cable', category: 'cable', quantity: 5);
    await store.add(name: 'Mystery box');

    final summary = await store.summarize();
    expect(summary.itemCount, 4);
    expect(summary.totalQuantity, 9);
    expect(summary.totalValue, 350);
    expect(summary.groupedBy, InventoryGroupBy.category);

    final names = [for (final group in summary.groups) group.name];
    expect(names, ['SSD', '(unspecified)', 'cable']);
    final ssd = summary.groups.first;
    expect(ssd.itemCount, 2);
    expect(ssd.totalQuantity, 3);
    expect(ssd.totalValue, 350);
  });

  test('summarize groups by other fields', () async {
    await store.add(name: 'SSD', location: 'bin 1');
    await store.add(name: 'RAM', location: 'bin 1');
    await store.add(name: 'PSU', location: 'closet');

    final summary = await store.summarize(groupBy: InventoryGroupBy.location);
    expect(summary.groupedBy, InventoryGroupBy.location);
    expect(summary.groups.first.name, 'bin 1');
    expect(summary.groups.first.itemCount, 2);
  });
}
