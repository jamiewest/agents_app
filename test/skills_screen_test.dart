// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/skill_detail_screen.dart';
import 'package:agents_app/ui/screens/skills_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

(ServiceProvider, SkillStore) _setup() {
  final services =
      (ServiceCollection()
            ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
            ..addSkillStore())
          .buildServiceProvider();
  return (services, services.getRequiredService<SkillStore>());
}

StoredSkill _skill() => StoredSkill(
  id: 's1',
  name: 'commit-style',
  description: 'How to write commit messages for this project.',
  instructions: 'Use imperative mood. Keep the subject under 50 characters.',
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
);

/// Hosts the Skills branch under a real router so skill cards can navigate
/// to the detail page, mirroring the app's route layout.
Widget _host(ServiceProvider services, {String initialLocation = '/skills'}) =>
    MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: initialLocation,
        routes: [
          GoRoute(
            path: '/skills',
            builder: (context, state) => SkillsScreen(services: services),
            routes: [
              GoRoute(
                path: 's/:id',
                builder: (context, state) => SkillDetailScreen(
                  services: services,
                  skillId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      ),
    );

void main() {
  testWidgets('a saved skill renders as a card that opens its detail page', (
    tester,
  ) async {
    final (services, store) = _setup();
    await store.save(_skill());

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    expect(find.text('commit-style'), findsOneWidget);

    await tester.tap(find.text('commit-style'));
    await tester.pumpAndSettle();

    expect(find.text('Instructions'), findsOneWidget);
    expect(find.textContaining('imperative mood'), findsOneWidget);
  });

  testWidgets('an empty store shows the empty state', (tester) async {
    final (services, _) = _setup();

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();

    expect(find.text('No skills yet.'), findsOneWidget);
  });

  testWidgets('the editor dialog creates a skill', (tester) async {
    final (services, store) = _setup();

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New skill'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'release-notes',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'When to use it'),
      'How to draft release notes.',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            (widget.decoration?.hintText?.contains('instructions the agent') ??
                false),
      ),
      'List user-facing changes first.',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('release-notes'), findsOneWidget);
    final saved = await store.getByName('release-notes');
    expect(saved, isNotNull);
    expect(saved!.instructions, 'List user-facing changes first.');
  });

  testWidgets('an invalid name disables Save and shows the reason', (
    tester,
  ) async {
    final (services, _) = _setup();

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New skill'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Not A Slug',
    );
    await tester.pump();

    expect(
      find.textContaining('lowercase letters, numbers, and hyphens'),
      findsOneWidget,
    );
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('deleting from the detail page returns to the list', (
    tester,
  ) async {
    final (services, store) = _setup();
    await store.save(_skill());

    await tester.pumpWidget(_host(services, initialLocation: '/skills/s/s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete skill'));
    await tester.pumpAndSettle();

    expect(find.text('No skills yet.'), findsOneWidget);
    expect(await store.get('s1'), isNull);
  });
}
