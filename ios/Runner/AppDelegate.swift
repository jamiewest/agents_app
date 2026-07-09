import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    SpeechBridge.register(with: engineBridge.applicationRegistrar.messenger())
  }
}

/// On-device speech-to-text for the wearable pipeline
/// (`agents_app/wearable_speech` method channel; Dart side is
/// `AppleSpeechEngine`). Mirrors macos/Runner/MainFlutterWindow.swift —
/// kept in this file to avoid Xcode project edits.
final class SpeechBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "agents_app/wearable_speech", binaryMessenger: messenger)
    channel.setMethodCallHandler(handle)
  }

  private static func handle(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    guard call.method == "transcribeFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      finish(result, FlutterError(
        code: "bad_args", message: "expected {path: String}", details: nil))
      return
    }
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        finish(result, FlutterError(
          code: "speech_unauthorized",
          message: "speech recognition not authorized (\(status.rawValue))",
          details: nil))
        return
      }
      transcribe(path: path, result: result)
    }
  }

  private static func transcribe(
    path: String, result: @escaping FlutterResult
  ) {
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      finish(result, FlutterError(
        code: "speech_unavailable",
        message: "recognizer unavailable for current locale", details: nil))
      return
    }
    let request = SFSpeechURLRecognitionRequest(
      url: URL(fileURLWithPath: path))
    request.shouldReportPartialResults = false
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    // The task callback fires repeatedly; FlutterResult must be called
    // exactly once.
    var completed = false
    recognizer.recognitionTask(with: request) { recognitionResult, error in
      if completed { return }
      if let error = error {
        completed = true
        finish(result, FlutterError(
          code: "speech_failed", message: error.localizedDescription,
          details: nil))
        return
      }
      if let recognitionResult = recognitionResult, recognitionResult.isFinal {
        completed = true
        finish(
          result,
          ["text": recognitionResult.bestTranscription.formattedString])
      }
    }
  }

  /// Channel results must be delivered on the platform (main) thread.
  private static func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }
}
