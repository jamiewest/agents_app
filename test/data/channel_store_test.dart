import 'package:agents_app/data/channel_store.dart';
import 'package:agents_app/domain/channel.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryRecordStore records;
  late ChannelStore store;

  setUp(() {
    records = InMemoryRecordStore();
    store = ChannelStore(records);
  });

  Channel channel(String id, String name, DateTime updatedAt) => Channel(
    id: id,
    name: name,
    agentIds: const ['a1'],
    createdAt: DateTime.utc(2026, 7, 1),
    updatedAt: updatedAt,
  );

  group('ChannelStore', () {
    test('round-trips a channel', () async {
      final original = Channel(
        id: 'chan-1',
        name: 'Research',
        description: 'Long-running research work',
        agentIds: const ['a1', 'a2'],
        createdAt: DateTime.utc(2026, 7, 1),
        updatedAt: DateTime.utc(2026, 7, 2),
      );

      await store.save(original);
      final loaded = await store.get('chan-1');

      expect(loaded!.name, 'Research');
      expect(loaded.description, 'Long-running research work');
      expect(loaded.agentIds, ['a1', 'a2']);
      expect(loaded.updatedAt, DateTime.utc(2026, 7, 2));
    });

    test('lists newest first and deletes', () async {
      await store.save(channel('old', 'Old', DateTime.utc(2026, 7, 1)));
      await store.save(channel('new', 'New', DateTime.utc(2026, 7, 2)));

      expect((await store.listAll()).map((c) => c.id), ['new', 'old']);

      await store.delete('old');
      expect((await store.listAll()).map((c) => c.id), ['new']);
    });
  });

  group('channel file namespace', () {
    test('two conversations in one channel share files', () async {
      // Both conversation scopes resolve to the channel namespace, so a
      // file written in one conversation is visible in the other — and in
      // the channel's Files tab.
      final fromConversationA = RecordStoreAgentFileStore(
        records,
        namespace: 'chan-1',
      );
      final fromConversationB = RecordStoreAgentFileStore(
        records,
        namespace: 'chan-1',
      );
      final unrelated = RecordStoreAgentFileStore(
        records,
        namespace: 'conv-solo',
      );

      await fromConversationA.writeFileAsync('report.md', 'shared findings');

      expect(
        await fromConversationB.readFileAsync('report.md'),
        'shared findings',
      );
      expect(await unrelated.readFileAsync('report.md'), isNull);
    });
  });
}
