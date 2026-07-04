import 'dart:io';

import 'package:agents_app/data/local_model_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// These exercise the native (`dart:io`) implementation directly, with the
/// store rooted in a temp directory so no platform channels are needed. The
/// web/OPFS behaviour is only observable in a real browser and is verified
/// by reloading the app.
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('local_model_store_test');
    debugLocalModelStoreRoot = temp;
  });

  tearDown(() {
    debugLocalModelStoreRoot = null;
    temp.deleteSync(recursive: true);
  });

  File pickedFile(String name, String content) {
    final file = File('${temp.path}/$name')..writeAsStringSync(content);
    return file;
  }

  group('local model store (native)', () {
    test('reports persistence supported', () {
      expect(localModelPersistenceSupported, isTrue);
    });

    test('persist copies the picked file and restore finds it', () async {
      // Arrange
      final source = pickedFile('picked.gguf', 'weights');

      // Act
      await persistLocalModelFile(
        modelId: 'm1',
        kindKey: 'model',
        sourcePath: source.path,
      );
      final restored = await restoreLocalModelLocation(
        modelId: 'm1',
        kindKey: 'model',
      );

      // Assert
      expect(restored, isNotNull);
      expect(restored, isNot(source.path));
      expect(File(restored!).readAsStringSync(), 'weights');
      expect(File('$restored.part').existsSync(), isFalse);
    });

    test('restore returns null when nothing is stored', () async {
      expect(
        await restoreLocalModelLocation(modelId: 'm1', kindKey: 'model'),
        isNull,
      );
    });

    test('re-picking overwrites the stored copy', () async {
      // Arrange
      final first = pickedFile('a.gguf', 'old');
      final second = pickedFile('b.gguf', 'new');
      await persistLocalModelFile(
        modelId: 'm1',
        kindKey: 'model',
        sourcePath: first.path,
      );

      // Act
      await persistLocalModelFile(
        modelId: 'm1',
        kindKey: 'model',
        sourcePath: second.path,
      );

      // Assert
      final restored = await restoreLocalModelLocation(
        modelId: 'm1',
        kindKey: 'model',
      );
      expect(File(restored!).readAsStringSync(), 'new');
    });

    test('re-saving the restored path itself leaves the copy intact', () async {
      // Arrange
      final source = pickedFile('picked.gguf', 'weights');
      await persistLocalModelFile(
        modelId: 'm1',
        kindKey: 'model',
        sourcePath: source.path,
      );
      final restored = (await restoreLocalModelLocation(
        modelId: 'm1',
        kindKey: 'model',
      ))!;

      // Act: bootstrap registered the stored copy and the editor re-saved it.
      await persistLocalModelFile(
        modelId: 'm1',
        kindKey: 'model',
        sourcePath: restored,
      );

      // Assert
      expect(File(restored).readAsStringSync(), 'weights');
    });

    test(
      'persist of a missing source never throws and stores nothing',
      () async {
        await expectLater(
          persistLocalModelFile(
            modelId: 'm1',
            kindKey: 'model',
            sourcePath: '${temp.path}/does-not-exist.gguf',
          ),
          completes,
        );
        expect(
          await restoreLocalModelLocation(modelId: 'm1', kindKey: 'model'),
          isNull,
        );
      },
    );

    test('delete removes one kind or the whole model', () async {
      // Arrange
      final source = pickedFile('picked.gguf', 'weights');
      for (final kind in ['model', 'mmproj']) {
        await persistLocalModelFile(
          modelId: 'm1',
          kindKey: kind,
          sourcePath: source.path,
        );
      }

      // Act + Assert: single kind.
      await deleteLocalModelFiles('m1', kindKey: 'mmproj');
      expect(
        await restoreLocalModelLocation(modelId: 'm1', kindKey: 'mmproj'),
        isNull,
      );
      expect(
        await restoreLocalModelLocation(modelId: 'm1', kindKey: 'model'),
        isNotNull,
      );

      // Act + Assert: whole model.
      await deleteLocalModelFiles('m1');
      expect(
        await restoreLocalModelLocation(modelId: 'm1', kindKey: 'model'),
        isNull,
      );
    });

    test('delete of a model with nothing stored never throws', () async {
      await expectLater(deleteLocalModelFiles('m1'), completes);
      await expectLater(
        deleteLocalModelFiles('m1', kindKey: 'mmproj'),
        completes,
      );
    });

    test('prune keeps listed models and removes the rest', () async {
      // Arrange
      final source = pickedFile('picked.gguf', 'weights');
      for (final id in ['keep', 'drop']) {
        await persistLocalModelFile(
          modelId: id,
          kindKey: 'model',
          sourcePath: source.path,
        );
      }

      // Act
      await pruneLocalModelFiles({'keep'});

      // Assert
      expect(
        await restoreLocalModelLocation(modelId: 'keep', kindKey: 'model'),
        isNotNull,
      );
      expect(
        await restoreLocalModelLocation(modelId: 'drop', kindKey: 'model'),
        isNull,
      );
    });
  });
}
