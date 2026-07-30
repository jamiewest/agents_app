import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:go_router/go_router.dart';

import '../features/local_models/local_llama_agent_factory.dart';
import '../data/theme_settings.dart';
import 'app_bootstrap.dart';
import 'app_router.dart';
import '../ui/app_theme.dart';

// Optional seed values so the demo can start with a working Anthropic agent.
// Supply them as compile-time defines, e.g.
//   flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-...
// They are only used to pre-populate the runtime configuration on first launch;
// thereafter sources, models, and agents are managed entirely in the UI.
const _seedApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const _seedModel = String.fromEnvironment(
  'ANTHROPIC_MODEL',
  defaultValue: 'claude-haiku-4-5-20251001',
);

class AgentsApp extends StatefulWidget {
  /// Creates the agents app.
  const AgentsApp({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<AgentsApp> createState() => _AgentsAppState();
}

class _AgentsAppState extends State<AgentsApp> with WidgetsBindingObserver {
  late final GoRouter _router;
  late final TaskSchedulerService _scheduler;
  late final AppActivityMonitor _activity;
  late final LocalModelWarmup _warmup;

  @override
  void initState() {
    super.initState();
    final bootstrap = AppBootstrap(
      widget.services,
      seedApiKey: _seedApiKey,
      seedModel: _seedModel,
    );
    _scheduler = widget.services.getRequiredService<TaskSchedulerService>()
      ..start();
    // When local inference is the only engine configured, the model the first
    // message needs is knowable now — load it in the background so that
    // message does not pay for it. Chained off the bootstrap future rather
    // than awaited: startup must not block on a model load.
    _warmup = LocalModelWarmup(
      manager: widget.services.getRequiredService<ConfiguredAgentsManager>(),
      ready: bootstrap.ensureInitialized,
      warm: (target) => warmLocalLlamaModel(
        widget.services,
        source: target.source,
        model: target.model,
      ),
    );
    unawaited(_warmup.start());
    _router = createAppRouter(
      services: widget.services,
      bootstrap: bootstrap,
      scheduler: _scheduler,
    );
    // Feed the idle monitor so the background title summarizer knows when the
    // user is active. Pointer events come through the root [Listener] in build.
    _activity = widget.services.getRequiredService<AppActivityMonitor>();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _warmup.stop();
    _scheduler.stop();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _activity.reportUserActivity();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activity.reportForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final themeSettings = widget.services.getRequiredService<ThemeSettings>();
    void reportActivity(PointerEvent _) => _activity.reportUserActivity();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: reportActivity,
      onPointerSignal: reportActivity,
      onPointerHover: reportActivity,
      child: ListenableBuilder(
        listenable: themeSettings,
        builder: (context, _) => MaterialApp.router(
          title: 'agents_app',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            seedColor: themeSettings.seed.color,
            brightness: Brightness.light,
          ),
          darkTheme: buildAppTheme(
            seedColor: themeSettings.seed.color,
            brightness: Brightness.dark,
          ),
          themeMode: themeSettings.mode,
          routerConfig: _router,
        ),
      ),
    );
  }
}
