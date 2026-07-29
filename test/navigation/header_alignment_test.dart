import 'dart:io' as io;

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/local_model_store_io.dart';
import 'package:agents_app/data/pushover_settings.dart';
import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/navigation/app_bootstrap.dart';
import 'package:agents_app/navigation/app_router.dart';
import 'package:agents_app/ui/app_theme.dart';
import 'package:agents_app/ui/screens/chats_home.dart'
    show AgentTeamsBrand, SidebarToggleButton;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _source = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);
const _model = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'fake-model',
);
const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Test Agent',
  modelId: 'model-1',
);

ServiceProvider _buildServices() {
  final kv = InMemoryKeyValueStore();
  final services = ServiceCollection()
    ..addSingleton<ThemeSettings>((_) => ThemeSettings(kv))
    ..addSingleton<PushoverSettings>(
      (sp) => PushoverSettings(sp.getRequiredService<SecretStore>()),
    )
    ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
    ..addSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    )
    ..addSingleton<AgentRunTelemetryStore>(
      (sp) => AgentRunTelemetryStore(sp.getRequiredService<RecordStore>()),
    )
    ..addConfiguredAgents(
      keyValueStore: (_) => InMemoryKeyValueStore(),
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            _NullChatClient(),
      ),
    );
  return services.buildServiceProvider();
}

Future<void> _seedUsableAgent(ServiceProvider services) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_source);
  await manager.saveModel(_model);
  await manager.saveAgent(_agent);
}

GoRouter _router(ServiceProvider services) => createAppRouter(
  services: services,
  bootstrap: AppBootstrap(services),
  scheduler: TaskSchedulerService(services),
  initialLocation: '/chats',
);

Widget _app(GoRouter router) => MaterialApp.router(routerConfig: router);

/// The centre of the first [Icon] inside [ancestor].
double _iconCenterY(WidgetTester tester, Finder ancestor) => tester
    .getCenter(find.descendant(of: ancestor, matching: find.byType(Icon)).first)
    .dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Root the local model store in a temp directory: bootstrap's restore pass
  // would otherwise call path_provider, whose platform channel never answers
  // in widget tests.
  late io.Directory storeRoot;
  setUp(() {
    storeRoot = io.Directory.systemTemp.createTempSync('header_alignment_test');
    debugLocalModelStoreRoot = storeRoot;
  });
  tearDown(() {
    debugLocalModelStoreRoot = null;
    storeRoot.deleteSync(recursive: true);
  });

  group('header alignment', () {
    testWidgets('every wide-layout pane heads itself on the same band', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(_router(services)));
      await tester.pumpAndSettle();

      // The rail's first destination, the sidebar's brand, and the detail
      // pane's sidebar toggle are three separate widget trees; the whole
      // point of the band is that they resolve to one line.
      final railIconY = _iconCenterY(tester, find.byType(NavigationRail));
      final brandIconY = _iconCenterY(tester, find.byType(AgentTeamsBrand));
      final brandTextY = tester.getCenter(find.text('AGENT TEAMS')).dy;
      final toggleIconY = _iconCenterY(
        tester,
        find.byType(SidebarToggleButton),
      );

      expect(railIconY, AppHeaderBand.centerY);
      expect(brandIconY, AppHeaderBand.centerY);
      expect(brandTextY, AppHeaderBand.centerY);
      expect(toggleIconY, AppHeaderBand.centerY);
    });

    testWidgets('an open chat heads itself on the band the sidebar uses', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final services = _buildServices();
      await _seedUsableAgent(services);

      final router = _router(services);
      await tester.pumpWidget(_app(router));
      await tester.pumpAndSettle();

      router.go('/chats/new/${_agent.id}');
      await tester.pumpAndSettle();

      // The chat's own app bar is the line everything else was moved onto,
      // so measure it rather than assuming Material's default holds.
      final titleY = tester
          .getCenter(
            find
                .descendant(
                  of: find.byType(AppBar),
                  matching: find.byType(Text),
                )
                .first,
          )
          .dy;
      final leadingIconY = _iconCenterY(
        tester,
        find.byType(SidebarToggleButton),
      );
      final brandIconY = _iconCenterY(tester, find.byType(AgentTeamsBrand));
      final railIconY = _iconCenterY(tester, find.byType(NavigationRail));

      expect(titleY, AppHeaderBand.centerY);
      expect(leadingIconY, AppHeaderBand.centerY);
      expect(brandIconY, AppHeaderBand.centerY);
      expect(railIconY, AppHeaderBand.centerY);
    });

    testWidgets('the compact drawer heads itself on the band too', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(_router(services)));
      await tester.pumpAndSettle();

      // Compact widths navigate through a drawer instead of the rail, so the
      // brand row there has to land on the band the page's own header uses.
      final pageTitleY = tester.getCenter(find.text('Chats')).dy;

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();

      final brandIconY = _iconCenterY(tester, find.byType(AgentTeamsBrand));
      final brandTextY = tester.getCenter(find.text('AGENT TEAMS')).dy;

      expect(pageTitleY, AppHeaderBand.centerY);
      expect(brandIconY, AppHeaderBand.centerY);
      expect(brandTextY, AppHeaderBand.centerY);
    });

    test('the band matches the app bars it has to line up with', () {
      // AppBar centres its title in toolbarHeight, which the app theme does
      // not override. If that ever diverges, every pane that heads itself
      // without an AppBar silently drifts off the line.
      expect(AppHeaderBand.height, kToolbarHeight);
      expect(AppHeaderBand.centerY, kToolbarHeight / 2);
    });
  });
}

final class _NullChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(messages: const []);

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => const Stream.empty();

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}
