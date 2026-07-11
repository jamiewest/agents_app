import 'package:agents_app/data/channel_store.dart';
import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/channel.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_app/main.dart' show ChatScreen;
import 'package:agents_app/ui/screens/chats_home.dart'
    show ChatDetailPane, ChatsHome, ChatsRootPane;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';

import 'support/chat_test_harness.dart';

/// A mirror of the app's nested /chats shell: the inner stateful shell whose
/// builder is [ChatsHome] (the persistent sidebar) and whose single branch is
/// the detail navigator ([ChatsRootPane] plus the open chat/channel). Kept in
/// step with `createAppRouter` so navigation and pop semantics match the app.
GoRouter _buildRouter(
  ServiceProvider services, {
  String initial = '/chats',
}) => GoRouter(
  initialLocation: initial,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          ChatsHome(services: services, navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/chats',
              builder: (context, state) => ChatsRootPane(services: services),
              routes: [
                GoRoute(
                  path: 'c/:conversationId',
                  builder: (context, state) => ChatDetailPane(
                    services: services,
                    conversationId: state.pathParameters['conversationId'],
                  ),
                ),
                GoRoute(
                  path: 'new/:agentId',
                  builder: (context, state) => ChatDetailPane(
                    services: services,
                    newChatAgentId: state.pathParameters['agentId'],
                    privateChat: state.uri.queryParameters['private'] == '1',
                    channelId: state.uri.queryParameters['channel'],
                  ),
                ),
                GoRoute(
                  path: 'channel/:channelId',
                  builder: (context, state) => Scaffold(
                    body: Text('channel:${state.pathParameters['channelId']}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/settings/agents/add',
      builder: (context, state) =>
          const Scaffold(body: Text('settings:agents:add')),
    ),
  ],
);

Widget _host(GoRouter router) => MaterialApp.router(routerConfig: router);

/// Opens the collapsed conversations-list section titled [title] by tapping
/// its header. Sections without the open conversation start collapsed.
Future<void> _expandSection(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installConnectivityMocks);

  group('ChatsHome', () {
    testWidgets('discards a new chat when no message is sent', (tester) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      expect(find.text('No conversations yet'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('Ask Test Agent anything.'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      expect(conversations, isEmpty);
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets(
      'shows a new chat when the user backs out immediately after sending',
      (tester) async {
        final records = InMemoryRecordStore();
        final services = buildTestServices(records);
        await seedTestAgent(services);

        await tester.pumpWidget(_host(_buildRouter(services)));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test Agent'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Remember this chat');
        await tester.pump();
        await tester.tap(findSubmitButton());
        await tester.pump();

        await tester.pageBack();
        await tester.pumpAndSettle();

        final conversations = await ConversationStore(
          records,
        ).listForAgent(testAgent.id);
        expect(conversations, hasLength(1));
        expect(conversations.single.title, 'Remember this chat');
        await _expandSection(tester, 'Test Agent');
        expect(find.text('Remember this chat'), findsAtLeastNWidgets(1));
      },
    );

    testWidgets('saves the user message when backing out mid-response', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(
        records,
        chatClient: BlockingChatClient(),
      );
      await seedTestAgent(services);

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Save before answering');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();

      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Save before answering');
      expect(conversations.single.lastMessagePreview, 'Save before answering');
      await _expandSection(tester, 'Test Agent');
      expect(find.text('Save before answering'), findsAtLeastNWidgets(1));
    });

    testWidgets('saves the conversation as soon as send is tapped', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(
        records,
        chatClient: BlockingChatClient(),
      );
      await seedTestAgent(services);

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Saved on submit');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Saved on submit');
      expect(conversations.single.lastMessagePreview, 'Saved on submit');
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('keeps a submit-saved conversation when popping immediately', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(
        records,
        chatClient: BlockingChatClient(),
      );
      await seedTestAgent(services);

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Do not delete me');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Do not delete me');
      await _expandSection(tester, 'Test Agent');
      expect(find.text('Do not delete me'), findsAtLeastNWidgets(1));
    });

    testWidgets('lists conversations newest first with previews', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      final store = ConversationStore(records);
      await store.save(
        testConversation(
          id: 'older',
          title: 'Older chat',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
          preview: 'older preview',
        ),
      );
      await store.save(
        testConversation(
          id: 'newer',
          title: 'Newer chat',
          updatedAt: DateTime.utc(2026, 6, 30, 12),
          preview: 'newer preview',
        ),
      );

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _expandSection(tester, 'Test Agent');
      expect(find.text('Newer chat'), findsOneWidget);
      expect(find.text('Older chat'), findsOneWidget);
      expect(find.textContaining('newer preview'), findsOneWidget);
      expect(find.textContaining('older preview'), findsOneWidget);

      final newerTop = tester.getTopLeft(find.text('Newer chat')).dy;
      final olderTop = tester.getTopLeft(find.text('Older chat')).dy;
      expect(newerTop, lessThan(olderTop));
    });

    testWidgets('an agent rename updates the list without remounting', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      final store = ConversationStore(records);
      await store.save(
        testConversation(
          id: 'c1',
          title: 'Some chat',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();
      expect(find.text('Test Agent'), findsOneWidget);

      // Rename in Settings; the visible list must follow via agentChanges,
      // not a remount.
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await tester.runAsync(
        () => manager.saveAgent(testAgent.copyWith(name: 'Renamed Agent')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Renamed Agent'), findsOneWidget);
      expect(find.text('Test Agent'), findsNothing);
    });

    testWidgets('renames a conversation from the tile menu', (tester) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      final store = ConversationStore(records);
      await store.save(
        testConversation(
          id: 'conversation-1',
          title: 'Original title',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _expandSection(tester, 'Test Agent');
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Manual title');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final loaded = await store.get('conversation-1');
      expect(loaded!.title, 'Manual title');
      expect(loaded.titleSource, ConversationTitleSource.manual);
      expect(find.text('Manual title'), findsOneWidget);
    });

    testWidgets('deleting a conversation cascades through all three stores', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      // Create a real conversation by chatting, so the transcript and
      // session stores have rows to cascade over.
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cascade me');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      final store = ConversationStore(records);
      final conversationId = (await store.listForAgent(testAgent.id)).single.id;
      expect(
        await ChatTranscriptStore(records).load(conversationId),
        isNotEmpty,
      );

      await _expandSection(tester, 'Test Agent');
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Delete conversation'),
      );
      await tester.pumpAndSettle();

      expect(await store.get(conversationId), isNull);
      expect(await ChatTranscriptStore(records).load(conversationId), isEmpty);
      expect(
        await ConversationSessionStore(records).listFor(conversationId),
        isEmpty,
      );
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('deleting the open conversation returns to the chats list', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      final store = ConversationStore(records);
      await store.save(
        testConversation(
          id: 'open-one',
          title: 'Open conversation',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );

      await tester.pumpWidget(
        _host(_buildRouter(services, initial: '/chats/c/open-one')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Conversation actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Delete conversation'),
      );
      await tester.pumpAndSettle();

      expect(await store.get('open-one'), isNull);
      expect(find.byType(ChatScreen), findsNothing);
      expect(
        find.text('Select a conversation or start a new chat.'),
        findsOneWidget,
      );
    });

    testWidgets('detail-pane button collapses and reopens the sidebar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      await ConversationStore(records).save(
        testConversation(
          id: 'open-one',
          title: 'Open conversation',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );

      await tester.pumpWidget(
        _host(_buildRouter(services, initial: '/chats/c/open-one')),
      );
      await tester.pumpAndSettle();
      expect(find.text('AGENT TEAMS'), findsOneWidget);

      // The open chat's app bar hides the sidebar; the icon flips to the
      // unfilled "show" affordance.
      await tester.tap(find.byTooltip('Hide conversations'));
      await tester.pumpAndSettle();
      expect(find.text('AGENT TEAMS'), findsNothing);
      expect(tester.widget<Icon>(find.byIcon(Symbols.view_sidebar)).fill, 0);

      await tester.tap(find.byTooltip('Show conversations'));
      await tester.pumpAndSettle();
      expect(find.text('AGENT TEAMS'), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Symbols.view_sidebar)).fill, 1);
    });

    testWidgets(
      'medium single-pane chat pairs back with the conversations drawer',
      (tester) async {
        // The default 800x600 surface is the medium layout: too narrow for
        // the persistent sidebar, too wide for the compact shell drawer.
        final records = InMemoryRecordStore();
        final services = buildTestServices(records);
        await seedTestAgent(services);
        final store = ConversationStore(records);
        await store.save(
          testConversation(
            id: 'open-one',
            title: 'Open conversation',
            updatedAt: DateTime.utc(2026, 6, 30, 9),
          ),
        );
        await store.save(
          testConversation(
            id: 'other-one',
            title: 'Other conversation',
            updatedAt: DateTime.utc(2026, 6, 30, 8),
          ),
        );

        await tester.pumpWidget(
          _host(_buildRouter(services, initial: '/chats/c/open-one')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.text('AGENT TEAMS'), findsNothing);
        expect(find.byTooltip('Back'), findsOneWidget);

        await tester.tap(find.byTooltip('Show conversations'));
        await tester.pumpAndSettle();
        expect(find.text('AGENT TEAMS'), findsOneWidget);

        // Navigating from the drawer closes it and switches the open chat.
        await tester.tap(find.textContaining('Other conversation'));
        await tester.pumpAndSettle();
        expect(find.text('AGENT TEAMS'), findsNothing);
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.byTooltip('Show conversations'), findsOneWidget);
      },
    );

    testWidgets('renames and deletes a channel; conversations are kept', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      final channels = ChannelStore(records);
      final conversations = ConversationStore(records);
      final channel = Channel(
        id: 'channel-1',
        name: 'Research',
        createdAt: DateTime.utc(2026, 6, 30, 9),
        updatedAt: DateTime.utc(2026, 6, 30, 9),
      );
      await channels.save(channel);
      await conversations.save(
        testConversation(
          id: 'in-channel',
          title: 'Channel chat',
          updatedAt: DateTime.utc(2026, 6, 30, 10),
          channelId: 'channel-1',
        ),
      );

      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _expandSection(tester, 'Channels');
      await tester.tap(find.byTooltip('Channel actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Deep Research');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect((await channels.get('channel-1'))!.name, 'Deep Research');
      expect(find.text('Deep Research'), findsOneWidget);

      await tester.tap(find.byTooltip('Channel actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete channel'));
      await tester.pumpAndSettle();

      expect(await channels.get('channel-1'), isNull);
      expect(await conversations.get('in-channel'), isNotNull);
      await _expandSection(tester, 'Test Agent');
      expect(find.text('Channel chat'), findsOneWidget);
    });
  });
}
