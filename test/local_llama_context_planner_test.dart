import 'package:agents_app/data/local_llama_context_planner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_flutter/orchestration.dart' as llama;

/// An estimate shaped like a small on-device model: 2 GiB of weights,
/// 64 KiB of KV per token, 128 MiB fixed overhead.
const _estimate = llama.ModelMemoryEstimate(
  weightsBytes: 2 * 1024 * 1024 * 1024,
  kvBytesPerToken: 64 * 1024,
  fixedOverheadBytes: 128 * 1024 * 1024,
);

llama.MemorySnapshot _memory(int availableBytes) => llama.MemorySnapshot(
  totalBytes: 16 * 1024 * 1024 * 1024,
  availableBytes: availableBytes,
);

void main() {
  group('planLocalLlamaContext', () {
    test('keeps the configured size when memory is plentiful', () {
      final plan = planLocalLlamaContext(
        estimate: _estimate,
        memory: _memory(12 * 1024 * 1024 * 1024),
        desiredContextTokens: 16384,
      );
      expect(plan.contextTokens, 16384);
      expect(plan.isReduced, isFalse);
      expect(plan.memoryCritical, isFalse);
    });

    test('shrinks to what the budget fits, at token granularity', () {
      // Budget after 20% headroom: 4 GiB * 0.8 = 3.2 GiB. Minus weights and
      // overhead leaves ~1.07 GiB of KV budget: ~17.5K tokens at 64 KiB.
      final plan = planLocalLlamaContext(
        estimate: _estimate,
        memory: _memory(4 * 1024 * 1024 * 1024),
        desiredContextTokens: 32768,
      );
      expect(plan.contextTokens, lessThan(32768));
      expect(plan.contextTokens, greaterThanOrEqualTo(minUsefulContextTokens));
      expect(plan.contextTokens % llama.contextTokenGranularity, 0);
      expect(plan.isReduced, isTrue);
      expect(plan.memoryCritical, isFalse);
    });

    test('caps at the trained context even when memory allows more', () {
      const trained = llama.ModelMemoryEstimate(
        weightsBytes: 2 * 1024 * 1024 * 1024,
        kvBytesPerToken: 64 * 1024,
        fixedOverheadBytes: 128 * 1024 * 1024,
        trainedContextTokens: 8192,
      );
      final plan = planLocalLlamaContext(
        estimate: trained,
        memory: _memory(12 * 1024 * 1024 * 1024),
        desiredContextTokens: 32768,
      );
      expect(plan.contextTokens, 8192);
      expect(plan.memoryCritical, isFalse);
    });

    test('loads at the floor and flags critical when nothing fits', () {
      // Barely more than the weights themselves: even the 8K floor's KV
      // cannot fit the headroom-adjusted budget.
      final plan = planLocalLlamaContext(
        estimate: _estimate,
        memory: _memory(2 * 1024 * 1024 * 1024 + 256 * 1024 * 1024),
        desiredContextTokens: 16384,
      );
      expect(plan.contextTokens, minUsefulContextTokens);
      expect(plan.memoryCritical, isTrue);
    });

    test('respects a configured size below the useful floor', () {
      final plan = planLocalLlamaContext(
        estimate: _estimate,
        memory: _memory(2 * 1024 * 1024 * 1024 + 256 * 1024 * 1024),
        desiredContextTokens: 4096,
      );
      expect(plan.contextTokens, 4096);
      expect(plan.memoryCritical, isTrue);
    });

    test('never grows past the configured size', () {
      final plan = planLocalLlamaContext(
        estimate: _estimate,
        memory: _memory(64 * 1024 * 1024 * 1024),
        desiredContextTokens: 8192,
      );
      expect(plan.contextTokens, 8192);
      expect(plan.isReduced, isFalse);
    });
  });
}
