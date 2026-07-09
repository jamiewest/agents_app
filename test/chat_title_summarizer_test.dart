import 'package:agents_app/data/app_activity_monitor.dart';
import 'package:agents_app/data/chat_title_summarizer.dart';
import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/logging.dart';
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chat client that returns a fixed title, counts calls, and can run a hook
/// while "generating" (to simulate a concurrent rename or user activity).
class _FakeTitleClient extends ai.ChatClient {
  _FakeTitleClient(this.title, {this.onCall});

  final String title;
  final Future<void> Function()? onCall;
  int callCount = 0;

  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    callCount++;
    await onCall?.call();
    // Let any pending stream events (e.g. an activity cancel) land.
    await Future<void>.delayed(Duration.zero);
    return ai.ChatResponse(
      messages: [ai.ChatMessage.fromText(ai.ChatRole.assistant, title)],
    );
  }

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => const Stream.empty();

  @override
  void dispose() {}
}

Conversation _conv(
  String id,
  ConversationTitleSource source, {
  DateTime? updatedAt,
  String title = 'orig',
}) => Conversation(
  id: id,
  kind: ConversationKind.direct,
  title: title,
  titleSource: source,
  participantAgentIds: const ['agent-1'],
  createdAt: DateTime(2020),
  updatedAt: updatedAt ?? DateTime(2020),
);

Future<void> _seedTranscript(
  ChatTranscriptStore transcripts,
  String id, {
  bool withReply = true,
}) => transcripts.replace(
  conversationId: id,
  sessionId: 'sess-$id',
  messages: [
    ai.ChatMessage.fromText(ai.ChatRole.user, 'How do I center a div in CSS?'),
    if (withReply)
      ai.ChatMessage.fromText(
        ai.ChatRole.assistant,
        'Use a flex container and center on both axes.',
      ),
  ],
);

void main() {
  late RecordStore records;
  late ConversationStore conversations;
  late ChatTranscriptStore transcripts;
  late AppActivityMonitor activity;

  setUp(() {
    records = InMemoryRecordStore();
    conversations = ConversationStore(records);
    transcripts = ChatTranscriptStore(records);
    activity = AppActivityMonitor();
  });

  ChatTitleSummarizer summarizer(ai.ChatClient? Function() client) =>
      ChatTitleSummarizer(
        conversations: conversations,
        transcripts: transcripts,
        activity: activity,
        residentTitleClient: client,
        loggerFactory: NullLoggerFactory.instance,
      );

  test('summarizes firstMessage/none, leaves manual/summary alone', () async {
    for (final source in ConversationTitleSource.values) {
      await conversations.save(_conv('c-${source.name}', source));
      await _seedTranscript(transcripts, 'c-${source.name}');
    }
    final client = _FakeTitleClient('Centering a div');

    await summarizer(() => client).runPassForTest(CancellationToken.none);

    final first = (await conversations.get('c-firstMessage'))!;
    expect(first.title, 'Centering a div');
    expect(first.titleSource, ConversationTitleSource.summary);
    expect(
      (await conversations.get('c-none'))!.titleSource,
      ConversationTitleSource.summary,
    );

    final manual = (await conversations.get('c-manual'))!;
    expect(manual.title, 'orig');
    expect(manual.titleSource, ConversationTitleSource.manual);
    expect((await conversations.get('c-summary'))!.title, 'orig');
  });

  test('skips conversations with no assistant reply yet', () async {
    await conversations.save(_conv('c1', ConversationTitleSource.firstMessage));
    await _seedTranscript(transcripts, 'c1', withReply: false);

    await summarizer(() => _FakeTitleClient('X')).runPassForTest(
      CancellationToken.none,
    );

    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );
  });

  test('preserves updatedAt so the recency list does not reorder', () async {
    // UTC so the store's toUtc() round-trip compares equal (DateTime equality
    // is timezone-sensitive); the point is that the summarizer never bumps it.
    final stamp = DateTime.utc(2021, 5, 5, 12);
    await conversations.save(
      _conv('c1', ConversationTitleSource.firstMessage, updatedAt: stamp),
    );
    await _seedTranscript(transcripts, 'c1');

    await summarizer(
      () => _FakeTitleClient('New Title'),
    ).runPassForTest(CancellationToken.none);

    final updated = (await conversations.get('c1'))!;
    expect(updated.titleSource, ConversationTitleSource.summary);
    expect(updated.title, 'New Title');
    expect(updated.updatedAt, stamp);
  });

  test('does not clobber a title changed while generating', () async {
    await conversations.save(_conv('c1', ConversationTitleSource.firstMessage));
    await _seedTranscript(transcripts, 'c1');
    // Rename to manual mid-generation; the write-back guard must re-read and
    // leave the newer manual title intact.
    final client = _FakeTitleClient(
      'Generated',
      onCall: () async {
        final current = (await conversations.get('c1'))!;
        await conversations.save(
          current.copyWith(
            title: 'User Renamed',
            titleSource: ConversationTitleSource.manual,
          ),
        );
      },
    );

    await summarizer(() => client).runPassForTest(CancellationToken.none);

    final after = (await conversations.get('c1'))!;
    expect(after.titleSource, ConversationTitleSource.manual);
    expect(after.title, 'User Renamed');
  });

  test('does nothing when no local model is resident', () async {
    await conversations.save(_conv('c1', ConversationTitleSource.firstMessage));
    await _seedTranscript(transcripts, 'c1');

    await summarizer(() => null).runPassForTest(CancellationToken.none);

    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );
  });

  test('an already-cancelled token stops before any generation', () async {
    await conversations.save(_conv('c1', ConversationTitleSource.firstMessage));
    await _seedTranscript(transcripts, 'c1');
    final client = _FakeTitleClient('X');
    final cts = CancellationTokenSource()..cancel();

    await summarizer(() => client).runPassForTest(cts.token);

    expect(client.callCount, 0);
    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );
  });

  test('user activity mid-pass halts the remaining candidates', () async {
    await conversations.save(
      _conv(
        'c1',
        ConversationTitleSource.firstMessage,
        updatedAt: DateTime(2021, 2),
      ),
    );
    await conversations.save(
      _conv(
        'c2',
        ConversationTitleSource.firstMessage,
        updatedAt: DateTime(2021),
      ),
    );
    await _seedTranscript(transcripts, 'c1');
    await _seedTranscript(transcripts, 'c2');
    // Newest-first ordering means c1 is processed first; it reports activity,
    // which cancels the pass before c2 is reached.
    final client = _FakeTitleClient(
      'T',
      onCall: () async => activity.reportUserActivity(),
    );

    await summarizer(() => client).runPassForTest(CancellationToken.none);

    expect(client.callCount, 1);
    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );
    expect(
      (await conversations.get('c2'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );
  });

  test('idle loop titles when idle, skips when busy, exits on cancel', () async {
    await conversations.save(_conv('c1', ConversationTitleSource.firstMessage));
    await _seedTranscript(transcripts, 'c1');
    final client = _FakeTitleClient('Looped Title');
    // Start busy so the first ticks find the app not idle.
    final monitor = AppActivityMonitor()..beginInference();
    final summarizer = ChatTitleSummarizer(
      conversations: conversations,
      transcripts: transcripts,
      activity: monitor,
      residentTitleClient: () => client,
      loggerFactory: NullLoggerFactory.instance,
      idleThreshold: Duration.zero,
      checkInterval: const Duration(milliseconds: 5),
    );
    final cts = CancellationTokenSource();
    final done = summarizer.executeLogged(cts.token);

    // Not idle (a generation is in flight): no pass runs.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(client.callCount, 0);
    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.firstMessage,
    );

    // Becomes idle: a pass runs and titles the conversation.
    monitor.endInference();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      (await conversations.get('c1'))!.titleSource,
      ConversationTitleSource.summary,
    );

    // Cancelling the stopping token makes the loop exit.
    cts.cancel();
    await done.timeout(const Duration(seconds: 1));
  });

  group('sanitizeTitle', () {
    final cases = {
      '"Centering a Div"': 'Centering a Div',
      'Title: CSS Flexbox Layout.': 'CSS Flexbox Layout',
      'Line one\nLine two': 'Line one',
      '  Multiple   spaces  ': 'Multiple spaces',
      '“Curly quoted”': 'Curly quoted',
      "'single quoted'": 'single quoted',
    };
    cases.forEach((raw, expected) {
      test('cleans ${raw.replaceAll('\n', r'\n')}', () {
        expect(ChatTitleSummarizer.sanitizeTitle(raw), expected);
      });
    });
  });
}
