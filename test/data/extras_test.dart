import 'package:agents_app/data/local_model_presets.dart';
import 'package:agents_app/data/thinking_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart'
    show supportedChatFormatNames;
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

        // Vision requires a projector, and any explicit format must be a
        // name the runtime can resolve.
        if (preset.supportsVision) {
          expect(preset.mmprojUrl, isNotNull, reason: preset.name);
        }
        final format = preset.chatFormat;
        if (format != null) {
          expect(supportedChatFormatNames, contains(format));
        }
      }
    });

    test('multi-artifact presets keep model, mmproj, and MTP paired', () {
      String repoOf(String url) => url.split('/resolve/').first.toLowerCase();

      final gemma = localModelPresets.singleWhere(
        (p) => p.name == 'Gemma 4 E4B (Mac)',
      );
      final config = gemma.toModelConfig(id: 'm', sourceId: 's');
      // All three artifacts must come from the same (E4B) repo: E2B's
      // mmproj projects to a different embedding width and its drafter
      // reads a different hidden state — mixing repos breaks at load.
      expect(repoOf(gemma.mmprojUrl!), repoOf(gemma.url));
      expect(repoOf(gemma.draftModelUrl!), repoOf(gemma.url));
      expect(gemma.url.toLowerCase(), contains('e4b'));
      expect(gemma.draftModelUrl!.toLowerCase(), contains('e4b'));
      expect(config.settings[chatFormatSetting], 'gemma');
      expect(config.capabilities.supportsVision, isTrue);

      final lfm = localModelPresets.singleWhere(
        (p) => p.name == 'LFM2.5 VL 1.6B (Mac)',
      );
      final lfmConfig = lfm.toModelConfig(id: 'm', sourceId: 's');
      expect(repoOf(lfm.mmprojUrl!), repoOf(lfm.url));
      // LFM2.5 must pin the plain-JSON tool dialect, never fall back to
      // the tagged LFM2 style.
      expect(lfmConfig.settings[chatFormatSetting], 'lfm2.5-vl');
      expect(lfm.draftModelUrl, isNull);
      expect(lfmConfig.capabilities.supportsVision, isTrue);
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
