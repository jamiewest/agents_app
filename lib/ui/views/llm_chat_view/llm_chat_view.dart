// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/widgets.dart';

import '../../chat_view_model/chat_view_model.dart';
import '../../chat_view_model/chat_view_model_provider.dart';
import '../../dialogs/adaptive_dialog.dart';
import '../../dialogs/adaptive_snack_bar/adaptive_snack_bar.dart';
import '../../llm_exception.dart';
import '../../platform_helper/platform_helper.dart' as ph;
import '../../providers/interface/attachments.dart';
import '../../providers/interface/chat_message.dart';
import '../../providers/interface/llm_provider.dart';
import '../../providers/interface/tool_approval.dart';
import '../../strings/llm_chat_view_strings.dart';
import '../../styles/llm_chat_view_style.dart';
import '../chat_history_view.dart';
import '../chat_input/chat_input.dart';
import '../response_builder.dart';
import '../tool_approval_view.dart';
import 'llm_response.dart';

/// A widget that displays a chat interface for interacting with an LLM
/// (Language Model).
///
/// This widget provides a complete chat interface, including a message history
/// view and an input area for sending new messages. It is configured with an
/// [LlmProvider] to manage the chat interactions.
///
/// Example usage:
/// ```dart
/// LlmChatView(
///   provider: MyLlmProvider(),
///   style: LlmChatViewStyle(
///     backgroundColor: Colors.white,
///     // ... other style properties
///   ),
/// )
/// ```
@immutable
class LlmChatView extends StatefulWidget {
  /// Creates an [LlmChatView] widget.
  ///
  /// This widget provides a chat interface for interacting with an LLM
  /// (Language Model). It requires an [LlmProvider] to manage the chat
  /// interactions and can be customized with various style and configuration
  /// options.
  ///
  /// - [provider]: The [LlmProvider] that manages the chat interactions.
  /// - [style]: Optional. The [LlmChatViewStyle] to customize the appearance of
  ///   the chat interface.
  /// - [responseBuilder]: Optional. A custom [ResponseBuilder] to handle the
  ///   display of LLM responses.
  /// - [messageSender]: Optional. A custom [LlmStreamGenerator] to handle the
  ///   sending of messages. If provided, this is used instead of the
  ///   `sendMessageStream` method of the provider. It's the responsibility of
  ///   the caller to ensure that the [messageSender] properly streams the
  ///   response. This is useful for augmenting the user's prompt with
  ///   additional information, in the case of prompt engineering or RAG. It's
  ///   also useful for simple logging.
  /// - [suggestions]: Optional. A list of predefined suggestions to display
  ///   when the chat history is empty. Defaults to an empty list.
  /// - [welcomeMessage]: Optional. A welcome message to display when the chat
  ///   is first opened.
  /// - [onCancelCallback]: Optional. The action to perform when the user
  ///   cancels a chat operation. By default, a snackbar is displayed with the
  ///   canceled message.
  /// - [onErrorCallback]: Optional. The action to perform when an
  ///   error occurs during a chat operation. By default, an alert dialog is
  ///   displayed with the error message.
  /// - [cancelMessage]: Optional. The message to display when the user cancels
  ///   a chat operation. Defaults to 'CANCEL'.
  /// - [errorMessage]: Optional. The message to display when an error occurs
  ///   during a chat operation. Defaults to 'ERROR'.
  /// - [enableAttachments]: Optional. Whether to enable file and image attachments in the chat input.
  /// - [enableVoiceNotes]: Optional. Whether to enable voice notes in the chat input.
  /// - [strings]: Optional. Custom strings for the chat interface. If not provided,
  ///   the default strings will be used.
  LlmChatView({
    required LlmProvider provider,
    LlmChatViewStyle? style,
    ResponseBuilder? responseBuilder,
    LlmStreamGenerator? messageSender,
    LlmSubmissionCallback? onMessageSubmitted,
    SpeechToTextConverter? speechToText,
    List<String> suggestions = const [],
    String? welcomeMessage,
    this.onCancelCallback,
    this.onErrorCallback,
    this.cancelMessage = 'CANCEL',
    this.errorMessage = 'ERROR',
    this.enableAttachments = true,
    this.enableVoiceNotes = true,
    this.enableImageAttachments = true,
    this.autofocus,
    LlmChatViewStrings? strings,
    super.key,
  }) : viewModel = ChatViewModel(
         provider: provider,
         responseBuilder: responseBuilder,
         messageSender: messageSender,
         onMessageSubmitted: onMessageSubmitted,
         speechToText: speechToText,
         style: style,
         suggestions: suggestions,
         welcomeMessage: welcomeMessage,
         enableAttachments: enableAttachments,
         enableVoiceNotes: enableVoiceNotes,
         enableImageAttachments: enableImageAttachments,
         strings: strings ?? LlmChatViewStrings.defaults,
       );

  /// The strings used throughout the chat interface.
  ///
  /// This provides access to all the text strings used in the chat interface,
  /// allowing for easy customization and internationalization.
  LlmChatViewStrings get strings => viewModel.strings;

  /// Whether to enable file and image attachments in the chat input.
  ///
  /// When set to false, the attachment button and related functionality will be
  /// disabled.
  final bool enableAttachments;

  /// Whether to enable voice notes in the chat input.
  ///
  /// When set to false, the voice recording button and related functionality
  /// will be disabled.
  final bool enableVoiceNotes;

  /// Whether to offer image attachments (camera and gallery) in the chat
  /// input.
  ///
  /// Set to false for models that cannot accept image input; file and link
  /// attachments remain available. Has no effect when [enableAttachments]
  /// is false.
  final bool enableImageAttachments;

  /// The view model containing the chat state and configuration.
  ///
  /// This [ChatViewModel] instance holds the LLM provider, transcript,
  /// response builder, welcome message, and LLM icon for the chat interface.
  /// It encapsulates the core data and functionality needed for the chat view.
  late final ChatViewModel viewModel;

  /// The action to perform when the user cancels a chat operation.
  ///
  /// By default, a snackbar is displayed with the canceled message.
  final void Function(BuildContext context)? onCancelCallback;

  /// The action to perform when an error occurs during a chat operation.
  ///
  /// By default, an alert dialog is displayed with the error message.
  final void Function(BuildContext context, LlmException error)?
  onErrorCallback;

  /// The text message to display when the user cancels a chat operation.
  ///
  /// Defaults to 'CANCEL'.
  final String cancelMessage;

  /// The text message to display when an error occurs during a chat operation.
  ///
  /// Defaults to 'ERROR'.
  final String errorMessage;

  /// Whether to autofocus the chat input field when the view is displayed.
  ///
  /// Defaults to `null`, which means it will be determined based on the
  /// presence of suggestions. If there are no suggestions, the input field
  /// will be focused automatically.
  final bool? autofocus;

  @override
  State<LlmChatView> createState() => _LlmChatViewState();
}

class _LlmChatViewState extends State<LlmChatView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  LlmResponse? _pendingPromptResponse;
  ChatMessage? _initialMessage;
  ChatMessage? _associatedResponse;
  LlmResponse? _pendingSttResponse;

  @override
  void initState() {
    super.initState();
    widget.viewModel.provider.addListener(_onHistoryChanged);
  }

  @override
  void didUpdateWidget(covariant LlmChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every rebuild constructs a fresh ChatViewModel, so compare the
    // providers themselves — they are stable across rebuilds and only
    // change when the owner swaps agents (e.g. after a settings reload).
    final oldProvider = oldWidget.viewModel.provider;
    final newProvider = widget.viewModel.provider;
    if (identical(oldProvider, newProvider)) return;

    oldProvider.removeListener(_onHistoryChanged);
    newProvider.addListener(_onHistoryChanged);

    // In-flight responses stream from the old provider; detach silently so
    // a stale stream cannot keep mutating messages, without surfacing a
    // cancel snackbar for a swap the user didn't ask for.
    _pendingPromptResponse?.detach();
    _pendingPromptResponse = null;
    _pendingSttResponse?.detach();
    _pendingSttResponse = null;
  }

  @override
  void dispose() {
    super.dispose();
    widget.viewModel.provider.removeListener(_onHistoryChanged);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for AutomaticKeepAliveClientMixin

    final chatStyle = LlmChatViewStyle.resolveFor(
      context,
      widget.viewModel.style,
    );
    final provider = widget.viewModel.provider;
    final pendingApproval =
        provider is ToolApprovalSupport && _pendingPromptResponse == null
        ? provider.pendingToolApproval
        : null;
    return ListenableBuilder(
      listenable: widget.viewModel.provider,
      builder: (context, child) => ChatViewModelProvider(
        viewModel: widget.viewModel,
        child: GestureDetector(
          onTap: () {
            // Dismiss keyboard when tapping anywhere in the view
            FocusScope.of(context).unfocus();
          },
          child: Container(
            color: chatStyle.backgroundColor,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      ChatHistoryView(
                        // can only edit if we're not waiting on the LLM or if
                        // we're not already editing an LLM response
                        onEditMessage:
                            _pendingPromptResponse == null &&
                                _associatedResponse == null
                            ? _onEditMessage
                            : null,
                        onSelectSuggestion: _onSelectSuggestion,
                      ),
                    ],
                  ),
                ),
                if (pendingApproval != null)
                  ToolApprovalView(
                    request: pendingApproval,
                    onDecision: _onToolApprovalDecision,
                    strings: widget.strings,
                  ),
                SafeArea(
                  child: ChatInput(
                    initialMessage: _initialMessage,
                    autofocus:
                        widget.autofocus ??
                        widget.viewModel.suggestions.isEmpty,
                    onCancelEdit: _associatedResponse != null
                        ? _onCancelEdit
                        : null,
                    onSendMessage: _onSendMessage,
                    onCancelMessage: _pendingPromptResponse == null
                        ? null
                        : _onCancelMessage,
                    onTranslateStt: _onTranslateStt,
                    onCancelStt: _pendingSttResponse == null
                        ? null
                        : _onCancelStt,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onSendMessage(
    String prompt,
    Iterable<Attachment> attachments,
  ) async {
    _initialMessage = null;
    _associatedResponse = null;

    // check the viewmodel for a user-provided message sender to use instead
    final sendMessageStream =
        widget.viewModel.messageSender ??
        widget.viewModel.provider.sendMessageStream;

    await widget.viewModel.onMessageSubmitted?.call(
      prompt,
      attachments: attachments,
    );

    _pendingPromptResponse = LlmResponse(
      stream: sendMessageStream(prompt, attachments: attachments),
      // Painting during streaming is driven by the message's own
      // notifications (ChatMessage.append), so only the live bubble
      // rebuilds; the stream can outlive this state when the user
      // navigates away mid-response.
      onUpdate: (_) {},
      onDone: _onPromptDone,
    );

    setState(() {});
  }

  void _onPromptDone(LlmException? error) {
    if (!mounted) {
      _pendingPromptResponse = null;
      return;
    }
    setState(() => _pendingPromptResponse = null);
    unawaited(_showLlmException(error));
  }

  void _onCancelMessage() => _pendingPromptResponse?.cancel();

  void _onToolApprovalDecision(ToolApprovalDecision decision) {
    final provider = widget.viewModel.provider;
    if (provider is! ToolApprovalSupport) return;

    _initialMessage = null;
    _associatedResponse = null;
    _pendingPromptResponse = LlmResponse(
      stream: provider.sendToolApprovalStream(decision),
      // Streaming repaints ride the message's own notifications.
      onUpdate: (_) {},
      onDone: _onPromptDone,
    );
    setState(() {});
  }

  void _onEditMessage(ChatMessage message) {
    assert(_pendingPromptResponse == null);

    // remove the last llm message
    final history = widget.viewModel.provider.history.toList();
    assert(history.last.origin.isLlm);
    final llmMessage = history.removeLast();

    // remove the last user message
    assert(history.last.origin.isUser);
    final userMessage = history.removeLast();

    // set the history to the new history
    widget.viewModel.provider.history = history;

    // set the text  to the last userMessage to provide initial prompt and
    // attachments for the user to edit
    setState(() {
      _initialMessage = userMessage;
      _associatedResponse = llmMessage;
    });
  }

  Future<void> _onTranslateStt(
    XFile file,
    Iterable<Attachment> currentAttachments,
  ) async {
    assert(widget.enableVoiceNotes);
    _initialMessage = null;
    _associatedResponse = null;

    final response = StringBuffer();
    _pendingSttResponse = LlmResponse(
      stream:
          widget.viewModel.speechToText?.call(file) ??
          _convertSpeechToText(file),
      onUpdate: (text) => response.write(text),
      onDone: (error) async => _onSttDone(
        error,
        response.toString().trim(),
        file,
        currentAttachments,
      ),
    );

    setState(() {});
  }

  Stream<String> _convertSpeechToText(XFile file) async* {
    // Use the model to transcribe the attached audio to text. "Transcribe"
    // (not "translate") so a multimodal model returns the spoken words in their
    // original language rather than translating them to English.
    const prompt =
        'Transcribe the attached audio to text; provide just the transcribed '
        'text itself. Be careful to separate the background audio from the '
        'foreground audio and only transcribe the foreground audio.';
    final attachments = [await FileAttachment.fromFile(file)];

    yield* widget.viewModel.provider.generateStream(
      prompt,
      attachments: attachments,
    );
  }

  Future<void> _onSttDone(
    LlmException? error,
    String response,
    XFile file,
    Iterable<Attachment> attachments,
  ) async {
    assert(_pendingSttResponse != null);
    _pendingSttResponse = null;

    // Delete the recording first so completing after the widget unmounts
    // still cleans it up.
    unawaited(ph.deleteFile(file));

    if (!mounted) return;
    setState(() {
      // Preserve any existing attachments from the current input. A
      // canceled or failed transcription yields an empty string, which
      // ChatMessage.user rejects.
      _initialMessage = response.isEmpty
          ? null
          : ChatMessage.user(response, attachments);
    });

    // show any error that occurred
    unawaited(_showLlmException(error));
  }

  void _onCancelStt() => _pendingSttResponse?.cancel();

  Future<void> _showLlmException(LlmException? error) async {
    if (error == null) return;

    // stop from the progress from indicating in case there was a failure
    // before any text response happened; the progress indicator uses a null
    // text message to keep progressing. plus we don't want to just show an
    // empty LLM message. A failed STT run in an empty chat has no bubble at
    // all, so guard the lookup.
    final llmMessage = widget.viewModel.provider.history.lastOrNull;
    if (llmMessage != null &&
        llmMessage.origin.isLlm &&
        llmMessage.text == null) {
      llmMessage.append(
        error is LlmCancelException
            ? widget.cancelMessage
            : widget.errorMessage,
      );
    }

    switch (error) {
      case LlmCancelException():
        if (widget.onCancelCallback != null) {
          widget.onCancelCallback!(context);
        } else {
          AdaptiveSnackBar.show(context, 'LLM operation canceled by user');
        }
        break;
      case LlmFailureException():
      case LlmException():
        if (widget.onErrorCallback != null) {
          widget.onErrorCallback!(context, error);
        } else {
          await AdaptiveAlertDialog.show(
            context: context,
            content: Text(error.toString()),
            showOK: true,
            copyText: error.toString(),
            copyLabel: widget.strings.copy,
          );
        }
    }
  }

  void _onSelectSuggestion(String suggestion) => _onSendMessage(suggestion, []);

  void _onHistoryChanged() {
    // if the history is cleared, clear the initial message
    if (widget.viewModel.provider.history.isEmpty) {
      setState(() {
        _initialMessage = null;
        _associatedResponse = null;
      });
    }
  }

  void _onCancelEdit() {
    assert(_initialMessage != null);
    assert(_associatedResponse != null);

    // add the original message and response back to the history
    final history = widget.viewModel.provider.history.toList();
    history.addAll([_initialMessage!, _associatedResponse!]);
    widget.viewModel.provider.history = history;

    setState(() {
      _initialMessage = null;
      _associatedResponse = null;
    });
  }
}
