import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr.writeln('The llama Apple framework can only be installed on macOS.');
    exitCode = 64;
    return;
  }

  final packageConfig = File('.dart_tool/package_config.json');
  if (!packageConfig.existsSync()) {
    stderr.writeln('Run flutter pub get before bootstrapping llama_flutter.');
    exitCode = 66;
    return;
  }

  final config = jsonDecode(await packageConfig.readAsString());
  final packages = config['packages'] as List<Object?>;
  final llama = packages.cast<Map<String, Object?>>().where(
    (package) => package['name'] == 'llama_flutter',
  );
  if (llama.isEmpty) {
    stderr.writeln('llama_flutter is missing from package_config.json.');
    exitCode = 69;
    return;
  }

  final configUri = packageConfig.absolute.uri;
  final rootUri = configUri.resolve(llama.single['rootUri']! as String);
  final packageRoot = Directory.fromUri(rootUri);
  final script = File('${packageRoot.path}/scripts/fetch_llama_xcframework.sh');
  if (!script.existsSync()) {
    stderr.writeln('Framework fetcher not found at ${script.path}.');
    exitCode = 69;
    return;
  }

  final process = await Process.start(
    script.path,
    const <String>[],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
