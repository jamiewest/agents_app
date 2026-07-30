import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_fonts/google_fonts.dart';
import 'package:llama_cpp_flutter/chat.dart' as llama;
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'app/agents_app.dart';
import 'data/prompt_log_inspector.dart';
import 'data/theme_settings.dart';
import 'features/inventory/inventory_access_settings.dart';
import 'features/inventory/inventory_store.dart';
import 'features/inventory/inventory_tools.dart';
import 'features/local_models/local_llama_agent_factory.dart';
import 'features/local_models/local_llama_model_host.dart';

// This is how we build and run the application, dont stray.
// <start>
final _builder = Host.createApplicationBuilder()
  ..services.addFlutter((flutter) {
    // Captures every Logger event into an in-app store with runtime level
    // controls (Settings > Logs & diagnostics). Replaces the old blanket
    // trace minimum level, which logged every streamed update.
    flutter.useAppLogging();
    flutter.services.addDownloadService();
    flutter.services.addRecordStore();
    flutter.services.tryAddSingleton<ThemeSettings>(
      (sp) => ThemeSettings(sp.getRequiredService<KeyValueStore>()),
    );
    // Unified log of every prompt sent to any model (local or cloud), so the
    // in-app inspector shows exactly what each model received.
    flutter.services.tryAddSingleton<PromptLog>((sp) => PromptLog());
    // Durable ledger of every model call's token usage, per conversation.
    flutter.services.tryAddSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    );
    // Durable ledger of agent runs — one record per chat turn, scheduled
    // execution, or hosted request. Carries no token counts of its own:
    // those live in the usage ledger above and are joined on the run id.
    flutter.services.tryAddSingleton<AgentRunTelemetryStore>(
      (sp) => AgentRunTelemetryStore(sp.getRequiredService<RecordStore>()),
    );
    // The local llama render seam writes its exact wire-format prompt through
    // a PromptInspector; the bridging subclass mirrors those into the shared
    // PromptLog alongside cloud requests.
    flutter.services.tryAddSingleton<llama.PromptInspector>(
      (sp) => PromptLogInspector(sp.getRequiredService<PromptLog>()),
    );
    flutter.services.tryAddSingleton<ThinkingSettings>(
      (sp) => ThinkingSettings(sp.getRequiredService<KeyValueStore>()),
    );
    // Live "which tool is the model running" signal, driven from inside the
    // chat client pipeline and mirrored under the streaming chat bubble.
    flutter.services.tryAddSingleton<ToolActivity>((sp) => ToolActivity());
    // Live in-chat terminal mirroring the shell commands each conversation's
    // agent executes, fed from inside the tool pipeline.
    flutter.services.tryAddSingleton<TerminalActivity>(
      (sp) => TerminalActivity(),
    );
    // Holds the one resident local llama model: same-model agent switches
    // reuse it, a different model evicts and reloads it, and it is never more
    // than one model at a time.
    flutter.services.tryAddSingleton<LocalLlamaModelHost>(
      (sp) => LocalLlamaModelHost(),
    );
    // App-wide idle signal: fed by the widget root (pointer/keyboard/lifecycle)
    // and by AgentLlmProvider (generation in flight); read by the background
    // title summarizer to decide when it is safe to work.
    flutter.services.tryAddSingleton<AppActivityMonitor>(
      (sp) => AppActivityMonitor(),
    );
    // Conversation metadata stores plus scheduled agent tasks, from the
    // package. The summarizer names conversations from their content using
    // whatever local model is already resident, while the app is idle; it
    // runs under the Host lifecycle.
    flutter.services
      ..addConversations()
      ..addTaskScheduler()
      ..addChatTitleSummarizer(
        residentTitleClient: (sp) => residentLocalTitleClient(sp),
      );
    // App-wide item inventory the agents manage through the inventory
    // tools. sqflite has no web backend wired up here, so the store — and
    // with it the tools — exists only on native builds.
    if (!kIsWeb) {
      flutter.services.tryAddSingleton<InventoryStore>(
        (sp) => InventoryStore(
          sqflite.databaseFactory,
          resolvePath: () async =>
              path.join(await sqflite.getDatabasesPath(), 'inventory.db'),
        ),
      );
    }
    // Pushover credentials live in the secret store; while they are
    // configured, agents that opt in through their access settings get
    // the notification tools.
    flutter.services.tryAddSingleton<PushoverSettings>(
      (sp) => PushoverSettings(sp.getRequiredService<SecretStore>()),
    );
    // The web-search endpoint URL lives in the secret store; while it is
    // configured, agents whose web-search access is on get the local
    // `web_search` and `open_web_page` tools instead of the provider's
    // hosted search marker. Native-only: the headless page loader those
    // tools rely on is unsupported on Flutter web, which keeps hosted
    // search instead.
    if (!kIsWeb) {
      // Opt-in HTTP tracing for the web tools: every `web_search` and
      // `open_web_page` call is mirrored here for the Settings inspector
      // while the toggle is on.
      flutter.services.tryAddSingleton<WebSearchTraceLog>(
        (sp) => WebSearchTraceLog(
          keyValueStore: sp.getRequiredService<KeyValueStore>(),
        ),
      );
      flutter.services.tryAddSingleton<WebSearchSettings>(
        // The hidden-WebView renderer serves clients that opt into
        // JavaScript rendering; on platforms without a headless WebView
        // those clients fall back to plain HTTP.
        (sp) => WebSearchSettings(
          sp.getRequiredService<SecretStore>(),
          renderer: HeadlessWebViewHtmlRenderer.isSupported
              ? HeadlessWebViewHtmlRenderer()
              : null,
          trace: sp.getRequiredService<WebSearchTraceLog>(),
        ),
      );
    }
    // Per-agent opt-in for the inventory tools. Lives outside the agent
    // record because AgentAccessConfig belongs to agents_flutter, which
    // knows nothing about this app's inventory.
    flutter.services.tryAddSingleton<InventoryAccessSettings>(
      (sp) => InventoryAccessSettings(sp.getRequiredService<KeyValueStore>()),
    );
    flutter.services.tryAddSingleton<EmbeddingSettings>(
      (sp) => EmbeddingSettings(
        keyValueStore: sp.getRequiredService<KeyValueStore>(),
        manager: sp.getRequiredService<ConfiguredAgentsManager>(),
      ),
    );
    // What the user chose to tell every agent about themselves, and which
    // agents they offer to paired devices. Both are app-local per-user
    // state that no agents_flutter model has a place for.
    flutter.services.tryAddSingleton<UserProfileSettings>(
      (sp) => UserProfileSettings(sp.getRequiredService<KeyValueStore>()),
    );
    flutter.services.tryAddSingleton<NetworkSharingSettings>(
      NetworkSharingSettings.new,
    );
    flutter.useFlutterHarnessAgent();
    flutter.useConfiguredAgents(
      // One summary log record per agent run (request in, response out) in
      // the Agents.Traffic category — never one record per streamed update.
      logAgentTraffic: true,
      chatClientFactory: (sp) => LoggingConfiguredChatClientFactory(
        log: sp.getRequiredService<PromptLog>(),
        usageSink: sp.getRequiredService<UsageStore>(),
        toolActivity: sp.getRequiredService<ToolActivity>(),
        customClientResolver:
            ({required source, required model, httpClient, scope}) =>
                createLocalLlamaClient(
                  sp,
                  source: source,
                  model: model,
                  scope: scope,
                ),
      ),
      configureHarnessForScope: (sp) => (agent, options, scope) {
        // The shared inventory is app-wide, not conversation-scoped, but
        // like the other tool capabilities each agent opts in through its
        // editor. The store is absent on web, where sqflite has no
        // backend.
        final inventory = sp.getService<InventoryStore>();
        if (inventory != null &&
            sp.getRequiredService<InventoryAccessSettings>().enabledFor(
              agent.id,
            )) {
          final chatOptions = options.chatOptions ?? ai.ChatOptions();
          chatOptions.tools = [
            ...?chatOptions.tools,
            ...createInventoryTools(inventory),
          ];
          options.chatOptions = chatOptions;
        }

        // Everything else — pushover, web search + tracing, the terminal
        // mirror, user profile, and durable conversation persistence — is
        // the standard wiring the package provides.
        ConversationScopeWiring.apply(
          sp,
          agent,
          options,
          scope,
          memoryApplicationId: 'agents_app',
        );
      },
    );
    flutter.wrapWith((sp, child) => child);
    flutter.runApp((services) => AgentsApp(services: services));
  });

final host = _builder.build();

Future<void> main() async {
  // Outfit ships as bundled assets (assets/google_fonts/), so startup never
  // depends on fonts.gstatic.com; fail loudly in debug if a weight ever
  // falls off the bundle instead of silently fetching.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['google_fonts'], license);
  });
  await host.run();
}
// </start>
