import 'dart:async';

import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/action_engine.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';

final calls = <String>[];

/// The bound temp set each validate call saw.
final boundSeen = <Set<String>>[];

/// Driven by the action's fields: `ref` (id it touches), `temp_id`, `fail`,
/// `outcome` (undo result name, or 'throw').
class Fake implements ActionHandler {
  Fake(this.type, [this.stage = AssistStage.schedule]);

  @override
  final String type;
  @override
  final AssistStage stage;

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    boundSeen.add({...scope.boundTemps});
    final ref = a.fields['ref'] as String?;
    if (ref == null) return null;
    final ok = ref.startsWith('new:')
        ? scope.boundTemps.contains(ref)
        : scope.knownIds.contains(ref);
    return ok ? null : 'unknown $ref';
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(text: '$type ${labels[a.fields['ref']]}');

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final n = a.fields['n'];
    calls.add('apply $n');
    final ref = a.fields['ref'] as String?;
    final resolved = ref == null ? null : scope.resolve(ref);
    // Binds before failing (a careless handler) to test the engine's rollback.
    if (a.tempId case final t?) scope.bind(t, 'real$n');
    if (a.fields['fail'] == true) throw StateError('boom $n');
    return UndoRecord(
      type: type,
      data: {'n': n, 'ref': resolved, 'outcome': a.fields['outcome']},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    calls.add('undo ${r.data['n']}');
    final o = r.data['outcome'] as String?;
    if (o == 'throw') throw StateError('gone');
    return o == null ? UndoOutcome.reverted : UndoOutcome.values.byName(o);
  }
}

AssistAction act(
  int n, {
  String type = 'x',
  String? temp,
  Object? ref,
  bool fail = false,
  String? outcome,
  Map<String, dynamic> extra = const {},
}) =>
    AssistAction(
      type: type,
      fields: {
        'type': type,
        'n': n,
        if (temp != null) 'temp_id': temp,
        if (ref != null) 'ref': ref,
        if (fail) 'fail': true,
        if (outcome != null) 'outcome': outcome,
        ...extra,
      },
    );

final engine = ActionEngine([
  Fake('x'),
  Fake('b'),
  Fake('p', AssistStage.pages),
  Fake('w', AssistStage.workspace),
]);

ValidationScope scope({Set<String>? boundTemps}) => ValidationScope(
      knownIds: {'k1'},
      weekStart: DateTime(2026, 10, 19),
      boundTemps: boundTemps,
    );

List<Object?> kept(List<AssistAction> actions, {Set<String>? boundTemps}) =>
    engine
        .filterValid(
          actions,
          scope: scope(boundTemps: boundTemps),
          stage: AssistStage.pages,
        )
        .map((a) => a.fields['n'])
        .toList();

AppliedProposal proposal(
  List<AssistAction> actions, {
  List<UndoRecord>? records,
  Map<String, String>? tempIds,
  AppliedStatus status = AppliedStatus.applying,
}) =>
    AppliedProposal(
      id: 'p1',
      appliedAt: DateTime(2026, 10, 19),
      actions: actions,
      records: records,
      tempIds: tempIds,
      status: status,
    );

void main() {
  setUp(() {
    calls.clear();
    boundSeen.clear();
  });

  group('filterValid', () {
    test('filterValid drops forward temp refs', () {
      expect(
        kept([
          act(1, ref: 'new:1'),
          act(2, temp: 'new:1'),
          act(3, ref: 'new:1'),
        ]),
        [2, 3],
      );
    });

    test('drops unknown types, stages above, bad ids; keeps order', () {
      expect(
        kept([
          act(1, type: 'nope'),
          act(2, type: 'w'),
          act(3, ref: 'missing'),
          act(4, ref: 'k1', type: 'p'),
          act(5),
        ]),
        [4, 5],
      );
    });

    test('a validate that throws drops the action', () {
      expect(kept([act(1, ref: 42), act(2)]), [2]);
    });

    test('nested column and field temp ids are bound', () {
      expect(
        kept([
          act(
            1,
            extra: {
              'columns': [
                {'temp_id': 'new:c1', 'name': 'A'},
              ],
            },
          ),
          act(
            2,
            extra: {
              'fields': [
                {'temp_id': 'new:f1', 'name': 'B', 'type': 'text'},
              ],
            },
          ),
          act(3, ref: 'new:c1'),
          act(4, ref: 'new:f1'),
        ]),
        [1, 2, 3, 4],
      );
    });

    test('temps of dropped actions stay unbound', () {
      expect(
        kept([act(1, ref: 'missing', temp: 'new:z'), act(2, ref: 'new:z')]),
        isEmpty,
      );
    });

    test('starts from scope.boundTemps without mutating it', () {
      final bound = {'new:9'};
      expect(
        kept(
          [act(1, ref: 'new:9'), act(2, temp: 'new:2')],
          boundTemps: bound,
        ),
        [1, 2],
      );
      expect(bound, {'new:9'});
    });

    test('only new: ids are declared', () {
      kept([
        act(
          1,
          temp: 'c1',
          extra: {
            'columns': [
              {'temp_id': 'col'},
              {'temp_id': 'new:c'},
            ],
          },
        ),
        act(2),
      ]);
      expect(boundSeen.last, {'new:c'});
    });

    test('re-declaring a temp id drops the action', () {
      expect(
        kept(
          [
            act(1, temp: 'new:1'),
            act(2, temp: 'new:1'),
            act(
              3,
              extra: {
                'columns': [
                  {'temp_id': 'new:1'},
                ],
              },
            ),
            act(
              4,
              extra: {
                'fields': [
                  {'temp_id': 'new:2'},
                  {'temp_id': 'new:2'},
                ],
              },
            ),
            act(5, temp: 'new:9'),
            act(6, ref: 'new:1'),
          ],
          boundTemps: {'new:9'},
        ),
        [1, 6],
      );
    });
  });

  test('typesUpTo lists handler types at or below the stage, sorted', () {
    expect(engine.typesUpTo(AssistStage.none), isEmpty);
    expect(engine.typesUpTo(AssistStage.schedule), ['b', 'x']);
    expect(engine.typesUpTo(AssistStage.pages), ['b', 'p', 'x']);
    expect(engine.typesUpTo(AssistStage.workspace), ['b', 'p', 'w', 'x']);
  });

  test('describe delegates to the handler', () {
    expect(engine.describe(act(1, ref: 'k1'), {'k1': 'Move'}).text, 'x Move');
  });

  test('ApplyScope resolves bound temps and plain ids, throws on unbound', () {
    final s = ApplyScope({'new:1': 'r1'});
    expect(s.resolve('new:1'), 'r1');
    expect(s.resolve('abc'), 'abc');
    expect(() => s.resolve('new:2'), throwsStateError);
    s.bind('new:2', 'r2');
    expect(s.tempIds, {'new:1': 'r1', 'new:2': 'r2'});
  });

  group('apply', () {
    test('apply runs in order and binds temp ids', () async {
      final p = proposal(
        [act(1, temp: 'new:1'), act(2, ref: 'new:1'), act(3, ref: 'k1')],
      );
      await engine.apply(p);
      expect(calls, ['apply 1', 'apply 2', 'apply 3']);
      expect(p.tempIds, {'new:1': 'real1'});
      expect(p.records.map((r) => r.data['ref']), [null, 'real1', 'k1']);
      expect(p.status, AppliedStatus.applied);
      expect(p.error, isNull);
    });

    test('apply stops at first failure and reports partial', () async {
      final p = proposal([act(1), act(2, fail: true), act(3)]);
      await engine.apply(p);
      expect(calls, ['apply 1', 'apply 2']);
      expect(p.records, hasLength(1));
      expect(p.status, AppliedStatus.partial);
      expect(p.error, contains('boom 2'));
    });

    test('resolving an unbound temp fails the action, apply goes partial',
        () async {
      final p = proposal([act(1), act(2, ref: 'new:7'), act(3)]);
      await engine.apply(p);
      expect(calls, ['apply 1', 'apply 2']);
      expect(p.records, hasLength(1));
      expect(p.status, AppliedStatus.partial);
      expect(p.error, contains('new:7'));
    });

    test('apply resumes without re-running done actions', () async {
      final done = UndoRecord(type: 'x', data: {'n': 0});
      final p = proposal(
        [act(1, temp: 'new:1'), act(2), act(3, ref: 'new:1'), act(4)],
        records: [done, done],
        tempIds: {'new:1': 'real1'},
        status: AppliedStatus.partial,
      )..error = 'old';
      await engine.apply(p);
      expect(calls, ['apply 3', 'apply 4']);
      expect(p.records, hasLength(4));
      expect(p.records[2].data['ref'], 'real1');
      expect(p.status, AppliedStatus.applied);
      expect(p.error, isNull);
    });

    test('apply on an applied proposal is a no-op', () async {
      final p = proposal([act(1)], status: AppliedStatus.applied);
      await engine.apply(p);
      expect(calls, isEmpty);
      expect(p.records, isEmpty);
      expect(p.status, AppliedStatus.applied);
    });

    test('onProgress is awaited after each action', () async {
      final p = proposal([act(1), act(2), act(3, fail: true)]);
      final seen = <int>[];
      final gate = Completer<void>();
      final done = engine.apply(
        p,
        onProgress: () async {
          seen.add(p.records.length);
          if (seen.length == 1) await gate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['apply 1']);
      gate.complete();
      await done;
      expect(seen, [1, 2]);
      expect(calls, ['apply 1', 'apply 2', 'apply 3']);
    });

    test('onProgress failure goes partial; retry resumes at the next action',
        () async {
      final p = proposal([act(1, temp: 'new:1'), act(2, ref: 'new:1')]);
      await engine.apply(p, onProgress: () async => throw StateError('disk'));
      expect(p.status, AppliedStatus.partial);
      expect(p.error, contains('disk'));
      expect(p.records, hasLength(1));
      expect(p.tempIds, {'new:1': 'real1'});
      await engine.apply(p);
      expect(calls, ['apply 1', 'apply 2']);
      expect(p.records[1].data['ref'], 'real1');
      expect(p.status, AppliedStatus.applied);
    });

    test('a handler that binds then throws leaves no binding', () async {
      final p =
          proposal([act(1, temp: 'new:1'), act(2, temp: 'new:2', fail: true)]);
      await engine.apply(p);
      expect(p.status, AppliedStatus.partial);
      expect(p.tempIds, {'new:1': 'real1'});
    });

    test('a missing handler fails the action with a clear error', () async {
      final p = proposal([act(1), act(2, type: 'nope')]);
      await engine.apply(p);
      expect(p.status, AppliedStatus.partial);
      expect(p.records, hasLength(1));
      expect(p.error, contains('No handler for nope'));
    });
  });

  group('undo', () {
    test('undo walks in reverse and counts outcomes', () async {
      final p = proposal([
        act(1),
        act(2, outcome: 'skippedChanged'),
        act(3, outcome: 'skippedGone'),
        act(4),
      ]);
      await engine.apply(p);
      calls.clear();
      final r = await engine.undo(p);
      expect(calls, ['undo 4', 'undo 3', 'undo 2', 'undo 1']);
      expect([r.reverted, r.skippedChanged, r.skippedGone], [2, 1, 1]);
      expect(p.status, AppliedStatus.undone);
    });

    test('undo continues past a throwing handler', () async {
      final p = proposal([act(1), act(2, outcome: 'throw'), act(3)]);
      await engine.apply(p);
      calls.clear();
      final r = await engine.undo(p);
      expect(calls, ['undo 3', 'undo 2', 'undo 1']);
      expect([r.reverted, r.skippedChanged, r.skippedGone], [2, 1, 0]);
      expect(p.status, AppliedStatus.undone);
    });

    test('undo of an undone proposal does nothing', () async {
      final p = proposal([act(1)]);
      await engine.apply(p);
      await engine.undo(p);
      calls.clear();
      final r = await engine.undo(p);
      expect(calls, isEmpty);
      expect([r.reverted, r.skippedChanged, r.skippedGone], [0, 0, 0]);
    });
  });
}
