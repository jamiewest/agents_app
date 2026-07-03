import 'package:agents_app/data/local_model_presets.dart';
import 'package:agents_app/data/thinking_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThinkingSettings', () {
    test('persists per-model preferences and reloads them', () async {
      final kv = InMemoryKeyValueStore();
      final settings = ThinkingSettings(kv);

      expect(settings.enabledFor('m1'), isFalse);
      await settings.setEnabled('m1', true);
      expect(settings.enabledFor('m1'), isTrue);

      final reloaded = ThinkingSettings(kv);
      await reloaded.load();
      expect(reloaded.enabledFor('m1'), isTrue);

      await reloaded.setEnabled('m1', false);
      expect(reloaded.enabledFor('m1'), isFalse);
      expect(await kv.keys(prefix: 'agents_app.thinking.'), isEmpty);
    });
  });

  group('localModelPresets', () {
    test('materialize as valid, runnable model configs', () {
      final names = <String>{};
      for (final preset in localModelPresets) {
        expect(names.add(preset.name), isTrue, reason: 'duplicate name');
        expect(preset.url, startsWith('https://huggingface.co/'));
        expect(preset.url, endsWith('.gguf'));

        final model = preset.toModelConfig(id: 'm-test', sourceId: 's1');
        expect(model.settings['llama.modelUrl'], preset.url);
        expect(
          int.parse(model.settings['llama.contextSize']!),
          greaterThanOrEqualTo(4096),
        );
        expect(model.capabilities.minMemoryMb, greaterThanOrEqualTo(4096));
      }
    });

    test('thinking capability is set only where advertised', () {
      final thinking = {
        for (final preset in localModelPresets)
          preset.name: preset
              .toModelConfig(id: 'm', sourceId: 's')
              .capabilities
              .supportsThinking,
      };
      expect(thinking['Qwen3 4B'], isTrue);
      expect(thinking['Gemma 3 1B'], isFalse);
    });
  });
}
