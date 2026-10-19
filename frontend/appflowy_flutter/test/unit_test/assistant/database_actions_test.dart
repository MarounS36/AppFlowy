import 'package:appflowy/features/assistant/actions/database_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/database_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGateway extends Mock implements DatabaseGateway {}

AssistAction act(String type, Map<String, dynamic> f) =>
    AssistAction(type: type, fields: {'type': type, ...f});

const title = DbField(
  id: 'f1',
  name: 'Title',
  type: FieldType.RichText,
  writable: true,
);
const link =
    DbField(id: 'f2', name: 'Link', type: FieldType.URL, writable: false);
const status = DbField(
  id: 'f3',
  name: 'Status',
  type: FieldType.SingleSelect,
  writable: true,
  options: [(id: 'o1', name: 'Done')],
);
const pages =
    DbField(id: 'f4', name: 'Pages', type: FieldType.Number, writable: true);
const author = DbField(
  id: 'f5',
  name: 'Author',
  type: FieldType.Relation,
  writable: false,
);
const tags = DbField(
  id: 'f6',
  name: 'Tags',
  type: FieldType.MultiSelect,
  writable: true,
  options: [(id: 'o2', name: 'Fun')],
);
const readOn = DbField(
  id: 'f7',
  name: 'Read on',
  type: FieldType.DateTime,
  writable: true,
);
const owned = DbField(
  id: 'f8',
  name: 'Owned',
  type: FieldType.Checkbox,
  writable: true,
);
const created = DbField(
  id: 'f9',
  name: 'Created',
  type: FieldType.CreatedTime,
  writable: false,
);
const allFields = [
  title,
  link,
  status,
  pages,
  author,
  tags,
  readOn,
  owned,
  created,
];

typedef DbRow = ({String id, Map<String, String> cells});

DbSnapshot snap({
  List<DbField> fields = allFields,
  List<DbRow> rows = const [],
  bool locked = false,
}) =>
    DbSnapshot(
      id: 'd1',
      name: 'Books',
      layout: ViewLayoutPB.Grid,
      fields: fields,
      rows: rows,
      isLocked: locked,
    );

const dune = (
  id: 'r1',
  cells: {'f1': 'Dune', 'f3': 'Done', 'f4': '100', 'f9': '2026-10-01'},
);
const linked = (id: 'r2', cells: {'f1': 'Emma', 'f5': '1 linked'});
const ranged = (
  id: 'r3',
  cells: {'f1': 'Odyssey', 'f7': '2026-10-19 → 2026-10-21'},
);

void main() {
  late _MockGateway gw;
  late Map<String, ActionHandler> h;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
    registerFallbackValue(ViewLayoutPB.Grid);
    registerFallbackValue(FieldType.RichText);
    registerFallbackValue(<({String name, FieldType type})>[]);
  });

  setUp(() {
    gw = _MockGateway();
    h = {for (final x in databaseHandlers(gw)) x.type: x};
    when(() => gw.databases()).thenAnswer(
      (_) async => [
        (id: 'd1', name: 'Books', layout: ViewLayoutPB.Grid, isLocked: false),
      ],
    );
    when(() => gw.rowHasExtras(any(), any())).thenAnswer((_) async => false);
  });

  void db(DbSnapshot? s) {
    when(() => gw.snapshot('d1')).thenAnswer((_) async => s);
    when(() => gw.snapshot('d1', rowCap: any(named: 'rowCap')))
        .thenAnswer((_) async => s);
  }

  /// [cells] is the live row; updateRow writes into it like the backend.
  Map<String, String>? cells;
  void row(String id, Map<String, String>? c) {
    cells = c;
    when(() => gw.row('d1', id)).thenAnswer(
      (_) async => cells == null ? null : {...cells!},
    );
    when(() => gw.updateRow('d1', id, any())).thenAnswer((i) async {
      cells = {...cells!, ...i.positionalArguments[2] as Map<String, String>};
    });
  }

  Future<ContextPart> context([
    List<DbRow> rows = const [dune, linked, ranged],
    bool locked = false,
  ]) {
    db(snap(rows: rows, locked: locked));
    return databaseContext(gw, ['d1']);
  }

  Future<ValidationScope> scope([
    List<DbRow> rows = const [dune, linked, ranged],
    bool locked = false,
  ]) async {
    final c = await context(rows, locked);
    return ValidationScope(
      knownIds: {...c.ids, 's1', 'p1'},
      weekStart: DateTime(2026, 10, 19),
      readOnlyIds: c.readOnlyIds,
      items: {
        ...c.items,
        's1': {'layout': 'space', 'parent_id': 'w'},
        // A grid that wasn't mentioned.
        'p1': {'layout': 'grid', 'parent_id': 's1'},
      },
    );
  }

  group('context', () {
    test('mentioned databases with fields, options and non-empty cells',
        () async {
      final c = await context();
      final d = (c.json['databases'] as List).single as Map;
      expect(d['id'], 'd1');
      expect(d['layout'], 'grid');
      expect((d['fields'] as List).first, {
        'id': 'f1',
        'name': 'Title',
        'type': 'text',
        'writable': true,
      });
      expect((d['fields'] as List)[2], {
        'id': 'f3',
        'name': 'Status',
        'type': 'select',
        'writable': true,
        'options': [
          {'id': 'o1', 'name': 'Done'},
        ],
      });
      expect((d['fields'] as List)[1]['writable'], false);
      expect(d['rows'], [
        {'id': 'r1', 'cells': dune.cells},
        {'id': 'r2', 'cells': linked.cells},
        {'id': 'r3', 'cells': ranged.cells},
      ]);
      expect(c.ids, containsAll(['d1', 'f1', 'f8', 'r1', 'r2']));
      expect(c.readOnlyIds, {'f2', 'f5', 'f9'});
      expect(c.labels['d1'], 'Books');
      expect(c.labels['f3'], 'Status');
      expect(c.labels['r1'], 'Dune');
      expect(c.items['r2'], {'database_id': 'd1', 'cells': linked.cells});
      expect(c.items['f3']!['type'], 'select');
    });

    test('a locked database is read-only; long cells are cut to 500', () async {
      final c = await context(
        [
          (id: 'r1', cells: {'f1': 'x' * 600}),
        ],
        true,
      );
      expect(c.readOnlyIds, contains('d1'));
      final rows = ((c.json['databases'] as List).single as Map)['rows'];
      expect(((rows as List).single['cells'] as Map)['f1'], 'x' * 500);
    });

    test('a row with no title is "Untitled row"; non-databases are skipped',
        () async {
      db(
        snap(
          rows: [
            (id: 'r3', cells: {'f1': '', 'f4': '3'}),
          ],
        ),
      );
      final c = await databaseContext(gw, ['p1', 'd1', 'd1']);
      expect(c.labels['r3'], 'Untitled row');
      expect(c.json['databases'] as List, hasLength(1));
      verifyNever(() => gw.snapshot('p1'));
    });
  });

  group('validate', () {
    test('a write to a URL field is rejected', () async {
      final s = await scope();
      expect(
        h['row.update']!.validate(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f2': 'http://x'},
          }),
          s,
        ),
        isNotNull,
      );
      expect(
        h['row.add']!.validate(
          act('row.add', {
            'database_id': 'd1',
            'temp_id': 'new:1',
            'cells': {'f1': 'Emma', 'f2': 'http://x'},
          }),
          s,
        ),
        isNotNull,
      );
      expect(
        h['row.update']!.validate(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f1': 'Dune II'},
          }),
          s,
        ),
        isNull,
      );
    });

    test('row.remove is rejected for a row with a non-empty relation cell',
        () async {
      final s = await scope();
      AssistAction remove(String id) => act(
            'row.remove',
            {'database_id': 'd1', 'row_id': id},
          );
      expect(h['row.remove']!.validate(remove('r2'), s), isNotNull);
      expect(
        h['row.remove']!.validate(remove('r1'), s),
        isNull,
        reason: 'a created-time value does not block',
      );
      expect(
        h['row.remove']!.validate(remove('r3'), s),
        isNotNull,
        reason: 'a date range cannot be restored',
      );
      expect(h['row.remove']!.validate(remove('zz'), s), isNotNull);
    });

    test('cell values must fit the field type', () async {
      final s = await scope();
      String? check(Map<String, String> c) => h['row.update']!.validate(
            act('row.update', {
              'database_id': 'd1',
              'row_id': 'r1',
              'cells': c,
            }),
            s,
          );
      expect(check({'f4': '12.5'}), isNull);
      expect(check({'f4': '-3'}), isNull);
      for (final bad in ['many', 'NaN', 'Infinity', '0x10', '1e3', '.5']) {
        expect(check({'f4': bad}), isNotNull, reason: bad);
      }
      expect(check({'f7': '2026-10-19'}), isNull);
      expect(check({'f7': '2026-10-19 09:30'}), isNull);
      expect(check({'f7': '2026-10-19 24:00'}), isNotNull);
      expect(check({'f7': '2026-10-19T09:30'}), isNotNull);
      expect(check({'f7': '2026-02-30'}), isNotNull);
      expect(check({'f7': '19/10/2026'}), isNotNull);
      expect(check({'f8': 'true'}), isNull);
      expect(check({'f8': 'No'}), isNull);
      expect(check({'f8': 'maybe'}), isNotNull);
      expect(check({'f3': 'Reading'}), isNull, reason: 'created on apply');
      expect(check({'f6': 'Fun, Long'}), isNull);
      expect(check({'f4': ''}), isNull, reason: 'empty clears');
      expect(check({'zz': 'x'}), isNotNull);
      expect(check({}), isNotNull, reason: 'row.update needs a cell');
      expect(
        h['row.update']!.validate(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r3',
            'cells': {'f7': '2026-10-20'},
          }),
          s,
        ),
        isNotNull,
        reason: 'a date range is read-only',
      );
    });

    test('nothing in a locked database is a target', () async {
      final s = await scope(const [dune], true);
      expect(
        h['row.update']!.validate(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f1': 'Dune II'},
          }),
          s,
        ),
        isNotNull,
      );
      expect(
        h['field.add']!.validate(
          act('field.add', {
            'database_id': 'd1',
            'temp_id': 'new:1',
            'name': 'Year',
            'field_type': 'number',
          }),
          s,
        ),
        isNotNull,
      );
    });

    test('ids must belong to a context database or an earlier action',
        () async {
      final s = await scope();
      expect(
        h['field.add']!.validate(
          act('field.add', {
            'database_id': 'p1',
            'temp_id': 'new:1',
            'name': 'N',
            'field_type': 'text',
          }),
          s,
        ),
        isNotNull,
      );
      final temps = ValidationScope(
        knownIds: s.knownIds,
        weekStart: s.weekStart,
        readOnlyIds: s.readOnlyIds,
        items: {
          ...s.items,
          'new:1': {'created_by': 'database.create'},
        },
        boundTemps: {'new:1', 'new:2'},
      );
      expect(
        h['row.add']!.validate(
          act('row.add', {
            'database_id': 'new:1',
            'temp_id': 'new:3',
            'cells': {'new:2': 'Dune'},
          }),
          temps,
        ),
        isNull,
      );
      expect(
        h['field.add']!.validate(
          act('field.add', {
            'database_id': 'd1',
            'temp_id': 'new:3',
            'name': 'N',
            'field_type': 'url',
          }),
          s,
        ),
        isNotNull,
      );
    });

    test('database.create needs a page parent, a layout and known types',
        () async {
      final s = await scope();
      AssistAction create({
        String parent = 's1',
        String layout = 'grid',
        String type = 'text',
      }) =>
          act('database.create', {
            'temp_id': 'new:1',
            'parent_id': parent,
            'name': 'Reading list',
            'layout': layout,
            'fields': [
              {'temp_id': 'new:2', 'name': 'Title', 'type': type},
            ],
          });
      expect(h['database.create']!.validate(create(), s), isNull);
      expect(
        h['database.create']!.validate(create(parent: 'f1'), s),
        isNotNull,
      );
      expect(
        h['database.create']!.validate(create(layout: 'list'), s),
        isNotNull,
      );
      expect(h['database.create']!.validate(create(type: 'url'), s), isNotNull);
    });

    test('option.add only on select fields, never a duplicate name', () async {
      final s = await scope();
      String? add(String field, String name) => h['option.add']!.validate(
            act('option.add', {
              'database_id': 'd1',
              'field_id': field,
              'name': name,
            }),
            s,
          );
      expect(add('f3', 'Reading'), isNull);
      expect(add('f3', 'done'), isNotNull);
      expect(add('f1', 'Reading'), isNotNull);
      expect(add('f6', 'a, b'), isNotNull);
    });
  });

  group('describe', () {
    test('row.update shows before → after per changed cell', () async {
      final c = await context();
      final p = h['row.update']!.describe(
        act('row.update', {
          'database_id': 'd1',
          'row_id': 'r1',
          'cells': {'f1': 'Dune', 'f3': 'Reading', 'f4': '120'},
        }),
        c.labels,
      );
      expect(p.text, 'Change row: Dune');
      expect(p.before, 'Status: Done; Pages: 100');
      expect(p.after, 'Status: Reading; Pages: 120');
      expect(p.editable, ['f1', 'f3', 'f4']);
    });

    test('preview lines', () async {
      final l = (await context()).labels;
      ActionPreview d(String type, Map<String, dynamic> f) =>
          h[type]!.describe(act(type, f), l);
      expect(
        d('database.create', {
          'name': 'Reading list',
          'layout': 'grid',
          'fields': [
            {'temp_id': 'new:2', 'name': 'Title', 'type': 'text'},
            {'temp_id': 'new:3', 'name': 'Author', 'type': 'text'},
          ],
        }).text,
        'New grid: Reading list (Title, Author)',
      );
      final add = d('row.add', {
        'database_id': 'd1',
        'cells': {'f4': '300', 'f1': 'Emma'},
      });
      expect(add.text, 'Add row: Emma');
      expect(add.after, 'Pages: 300; Title: Emma');
      expect(add.editable, ['f4', 'f1']);
      final remove = d('row.remove', {'database_id': 'd1', 'row_id': 'r1'});
      expect(remove.text, 'Remove row: Dune');
      expect(remove.destructive, isTrue);
      expect(
        d('field.add', {'name': 'Year', 'field_type': 'number'}).text,
        'Add field: Year (number)',
      );
      final rename = d('field.rename', {'field_id': 'f4', 'name': 'Length'});
      expect([rename.before, rename.after], ['Pages', 'Length']);
      expect(
        d('option.add', {'field_id': 'f3', 'name': 'Reading'}).text,
        'Add option Reading to Status',
      );
      for (final t in [
        'database.create',
        'field.add',
        'field.rename',
        'option.add',
      ]) {
        expect(d(t, {'fields': <Map>[]}).editable, ['name'], reason: t);
      }
    });
  });

  group('database.create', () {
    test('binds the database and each field temp in order', () async {
      when(
        () =>
            gw.createDatabase('s1', 'Reading list', ViewLayoutPB.Board, any()),
      ).thenAnswer((_) async => (id: 'd9', fieldIds: ['fa', 'fb']));
      final s = ApplyScope({});
      final r = await h['database.create']!.apply(
        act('database.create', {
          'temp_id': 'new:1',
          'parent_id': 's1',
          'name': ' Reading list ',
          'layout': 'board',
          'fields': [
            {'temp_id': 'new:2', 'name': 'Title', 'type': 'text'},
            {'temp_id': 'new:3', 'name': 'Status', 'type': 'select'},
          ],
        }),
        s,
      );
      expect(s.tempIds, {'new:1': 'd9', 'new:2': 'fa', 'new:3': 'fb'});
      expect(r.type, 'database.create');
      final fields = verify(
        () => gw.createDatabase(any(), any(), any(), captureAny()),
      ).captured.single;
      expect(fields, [
        (name: 'Title', type: FieldType.RichText),
        (name: 'Status', type: FieldType.SingleSelect),
      ]);
    });

    test('undo moves it to Trash; gone is skipped', () async {
      final rec = UndoRecord(
        type: 'database.create',
        data: {'database_id': 'd1'},
      );
      when(() => gw.deleteDatabase('d1')).thenAnswer((_) async {});
      expect(await h['database.create']!.undo(rec), UndoOutcome.reverted);
      verify(() => gw.deleteDatabase('d1')).called(1);
      when(() => gw.databases()).thenAnswer((_) async => []);
      expect(await h['database.create']!.undo(rec), UndoOutcome.skippedGone);
    });
  });

  group('row.add', () {
    test('creates missing select options first, then the row', () async {
      db(snap());
      when(() => gw.addOption('d1', any(), any()))
          .thenAnswer((_) async => 'o9');
      when(() => gw.addRow('d1', any())).thenAnswer((_) async => 'r9');
      row('r9', {'f1': 'Emma'});
      final s = ApplyScope({});
      final r = await h['row.add']!.apply(
        act('row.add', {
          'database_id': 'd1',
          'temp_id': 'new:4',
          'cells': {
            'f1': 'Emma',
            'f3': 'reading',
            'f6': 'fun, Classic, classic',
            'f8': 'true',
          },
        }),
        s,
      );
      verifyInOrder([
        () => gw.addOption('d1', 'f3', 'reading'),
        () => gw.addOption('d1', 'f6', 'Classic'),
        () => gw.addRow('d1', {
              'f1': 'Emma',
              'f3': 'reading',
              'f6': 'fun, Classic',
              'f8': 'Yes',
            }),
      ]);
      verifyNever(() => gw.addOption('d1', 'f6', 'fun'));
      expect(s.tempIds, {'new:4': 'r9'});
      expect(r.data['row_id'], 'r9');
    });

    test('a bad value for the live field fails before any write', () async {
      db(snap());
      final s = ApplyScope({'new:2': 'f2'});
      await expectLater(
        h['row.add']!.apply(
          act('row.add', {
            'database_id': 'd1',
            'temp_id': 'new:4',
            'cells': {'new:2': 'http://x'},
          }),
          s,
        ),
        throwsStateError,
      );
      verifyNever(() => gw.addRow(any(), any()));
      expect(s.tempIds, {'new:2': 'f2'});
    });

    test('undo deletes the row only if unchanged since', () async {
      db(snap());
      when(() => gw.addRow('d1', any())).thenAnswer((_) async => 'r9');
      when(() => gw.removeRow('d1', 'r9')).thenAnswer((_) async {});
      row('r9', {'f1': 'Emma', 'f4': ''});
      final r = await h['row.add']!.apply(
        act('row.add', {
          'database_id': 'd1',
          'cells': {'f1': 'Emma'},
        }),
        ApplyScope({}),
      );
      cells = {'f1': 'Emma', 'f4': '7'};
      expect(await h['row.add']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.removeRow(any(), any()));
      cells = {'f1': 'Emma', 'f4': '', 'f9': '2026-10-20', 'f8': 'No'};
      expect(
        await h['row.add']!.undo(r),
        UndoOutcome.reverted,
        reason: 'read-only fields and a blank checkbox are not changes',
      );
      verify(() => gw.removeRow('d1', 'r9')).called(1);
      cells = null;
      expect(await h['row.add']!.undo(r), UndoOutcome.skippedGone);
    });
  });

  group('row.update', () {
    test('undo restores only the written writable cells; skipped if changed',
        () async {
      db(snap());
      row('r1', {'f1': 'Dune', 'f2': 'http://a', 'f4': '100'});
      final r = await h['row.update']!.apply(
        act('row.update', {
          'database_id': 'd1',
          'row_id': 'r1',
          'cells': {'f4': '120'},
        }),
        ApplyScope({}),
      );
      verify(() => gw.updateRow('d1', 'r1', {'f4': '120'})).called(1);

      cells = {...cells!, 'f2': 'http://b'};
      expect(await h['row.update']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.updateRow('d1', 'r1', {'f4': '100'})).called(1);
      expect(cells, {'f1': 'Dune', 'f2': 'http://b', 'f4': '100'});

      final again = await h['row.update']!.apply(
        act('row.update', {
          'database_id': 'd1',
          'row_id': 'r1',
          'cells': {'f4': '120'},
        }),
        ApplyScope({}),
      );
      cells = {...cells!, 'f4': '130'};
      expect(await h['row.update']!.undo(again), UndoOutcome.skippedChanged);
      expect(cells!['f4'], '130');
    });

    test('a live date range fails without writing', () async {
      db(snap());
      row('r1', {'f1': 'Dune', 'f7': '2026-10-19 → 2026-10-21'});
      await expectLater(
        h['row.update']!.apply(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f7': '2026-10-20'},
          }),
          ApplyScope({}),
        ),
        throwsStateError,
      );
      verifyNever(() => gw.updateRow(any(), any(), any()));
    });

    test('a gone row fails without writing', () async {
      db(snap());
      row('r1', null);
      await expectLater(
        h['row.update']!.apply(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f3': 'Reading'},
          }),
          ApplyScope({}),
        ),
        throwsStateError,
      );
      verifyNever(() => gw.addOption(any(), any(), any()));
    });
  });

  group('row.remove', () {
    test('records the writable cells; undo re-creates once', () async {
      db(snap());
      row('r1', {
        'f1': 'Dune',
        'f2': '',
        'f3': 'Done',
        'f4': '',
        'f5': '',
        'f8': 'No',
        'f9': '2026-10-01',
      });
      when(() => gw.removeRow('d1', 'r1')).thenAnswer((_) async {});
      final r = await h['row.remove']!.apply(
        act('row.remove', {'database_id': 'd1', 'row_id': 'r1'}),
        ApplyScope({}),
      );
      expect(r.data['cells'], {'f1': 'Dune', 'f3': 'Done'});

      when(() => gw.addRow('d1', any())).thenAnswer((_) async => 'r8');
      expect(await h['row.remove']!.undo(r), UndoOutcome.skippedChanged);
      cells = null;
      expect(await h['row.remove']!.undo(r), UndoOutcome.reverted);
      expect(await h['row.remove']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.addRow('d1', {'f1': 'Dune', 'f3': 'Done'})).called(1);
      expect(r.data['restored_id'], 'r8');
    });

    test('a live read-only value, date range or row page blocks the remove',
        () async {
      db(snap());
      Future<void> blocked() => expectLater(
            h['row.remove']!.apply(
              act('row.remove', {'database_id': 'd1', 'row_id': 'r1'}),
              ApplyScope({}),
            ),
            throwsStateError,
          );
      row('r1', {'f1': 'Dune', 'f5': '2 linked'});
      await blocked();
      row('r1', {'f1': 'Dune', 'f7': '2026-10-19 → 2026-10-21'});
      await blocked();
      row('r1', {'f1': 'Dune'});
      when(() => gw.rowHasExtras('d1', 'r1')).thenAnswer((_) async => true);
      await blocked();
      verifyNever(() => gw.removeRow(any(), any()));
    });
  });

  group('fields', () {
    const year = DbField(
      id: 'f10',
      name: 'Year',
      type: FieldType.Number,
      writable: true,
    );

    test('field.add binds; undo deletes it only while every cell is empty',
        () async {
      db(snap());
      when(() => gw.addField('d1', 'Year', FieldType.Number))
          .thenAnswer((_) async => 'f10');
      when(() => gw.removeField('d1', 'f10')).thenAnswer((_) async {});
      final s = ApplyScope({});
      final r = await h['field.add']!.apply(
        act('field.add', {
          'database_id': 'd1',
          'temp_id': 'new:5',
          'name': 'Year',
          'field_type': 'number',
        }),
        s,
      );
      expect(s.tempIds, {'new:5': 'f10'});

      db(
        snap(
          fields: [...allFields, year],
          rows: [
            (id: 'r1', cells: {'f10': '1965'}),
          ],
        ),
      );
      expect(await h['field.add']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.removeField(any(), any()));

      db(
        snap(
          fields: [...allFields, year],
          rows: [
            (id: 'r1', cells: {'f10': ''}),
          ],
        ),
      );
      expect(await h['field.add']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.removeField('d1', 'f10')).called(1);

      db(snap());
      expect(await h['field.add']!.undo(r), UndoOutcome.skippedGone);
    });

    test('field.rename undo renames back only if unchanged', () async {
      db(snap());
      when(() => gw.renameField('d1', 'f4', any())).thenAnswer((_) async {});
      final r = await h['field.rename']!.apply(
        act('field.rename', {
          'database_id': 'd1',
          'field_id': 'f4',
          'name': 'Length',
        }),
        ApplyScope({}),
      );
      const renamed = DbField(
        id: 'f4',
        name: 'Length',
        type: FieldType.Number,
        writable: true,
      );
      db(snap(fields: [title, renamed]));
      expect(await h['field.rename']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.renameField('d1', 'f4', 'Pages')).called(1);
      db(snap(fields: [title, pages]));
      expect(await h['field.rename']!.undo(r), UndoOutcome.skippedChanged);
    });
  });

  group('option.add', () {
    const withReading = DbField(
      id: 'f3',
      name: 'Status',
      type: FieldType.SingleSelect,
      writable: true,
      options: [(id: 'o1', name: 'Done'), (id: 'o9', name: 'Reading')],
    );

    test('never touches a row; undo removes it only while unused', () async {
      db(snap());
      when(() => gw.addOption('d1', 'f3', 'Reading'))
          .thenAnswer((_) async => 'o9');
      when(() => gw.removeOption('d1', 'f3', 'o9')).thenAnswer((_) async {});
      final r = await h['option.add']!.apply(
        act('option.add', {
          'database_id': 'd1',
          'field_id': 'f3',
          'name': 'Reading',
        }),
        ApplyScope({}),
      );
      expect(r.data['option_id'], 'o9');
      verifyNever(() => gw.addRow(any(), any()));
      verifyNever(() => gw.updateRow(any(), any(), any()));
      verifyNever(() => gw.removeRow(any(), any()));

      db(
        snap(
          fields: [title, withReading],
          rows: [
            (id: 'r1', cells: {'f3': 'Reading'}),
          ],
        ),
      );
      expect(await h['option.add']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.removeOption(any(), any(), any()));

      db(
        snap(
          fields: [title, withReading],
          rows: [
            (id: 'r1', cells: {'f3': 'Done'}),
          ],
        ),
      );
      expect(await h['option.add']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.removeOption('d1', 'f3', 'o9')).called(1);
      verifyNever(() => gw.updateRow(any(), any(), any()));

      db(snap());
      expect(await h['option.add']!.undo(r), UndoOutcome.skippedGone);
    });
  });

  group('locked', () {
    test('a lock set after the proposal stops apply and undo', () async {
      db(snap(locked: true));
      row('r1', {'f1': 'Dune', 'f4': '100'});
      await expectLater(
        h['row.update']!.apply(
          act('row.update', {
            'database_id': 'd1',
            'row_id': 'r1',
            'cells': {'f4': '120'},
          }),
          ApplyScope({}),
        ),
        throwsStateError,
      );
      await expectLater(
        h['field.add']!.apply(
          act('field.add', {
            'database_id': 'd1',
            'name': 'Year',
            'field_type': 'number',
          }),
          ApplyScope({}),
        ),
        throwsStateError,
      );
      verifyNever(() => gw.updateRow(any(), any(), any()));
      verifyNever(() => gw.addField(any(), any(), any()));
      final rec = UndoRecord(
        type: 'row.update',
        data: {
          'database_id': 'd1',
          'row_id': 'r1',
          'before': {'f4': '90'},
          'after': {'f4': '100'},
        },
      );
      expect(await h['row.update']!.undo(rec), UndoOutcome.skippedChanged);
      verifyNever(() => gw.updateRow(any(), any(), any()));
    });
  });

  group('date text', () {
    DateCellDataPB cell(DateTime? d, {bool time = false, DateTime? end}) =>
        DateCellDataPB(
          timestamp: d == null ? null : Int64(d.millisecondsSinceEpoch ~/ 1000),
          endTimestamp:
              end == null ? null : Int64(end.millisecondsSinceEpoch ~/ 1000),
          includeTime: time,
          isRange: end != null,
        );

    test('reads a date, a time and a range', () {
      expect(dateCellText(cell(null)), '');
      expect(dateCellText(cell(DateTime(2026, 10, 19, 9, 5))), '2026-10-19');
      expect(
        dateCellText(cell(DateTime(2026, 10, 19, 9, 5), time: true)),
        '2026-10-19 09:05',
      );
      final r = dateCellText(
        cell(DateTime(2026, 10, 19), end: DateTime(2026, 10, 21)),
      );
      expect(r, '2026-10-19 → 2026-10-21');
      expect(isDateRange(r), isTrue);
    });

    test('a time sets includeTime; a date-only write keeps the time of day',
        () {
      final timed = dateWrite('2026-10-20 14:30', cell(null));
      expect(timed.date, DateTime(2026, 10, 20, 14, 30));
      expect(timed.includeTime, isTrue);

      final keep = dateWrite(
        '2026-10-22',
        cell(DateTime(2026, 10, 19, 9, 5), time: true),
      );
      expect(keep.date, DateTime(2026, 10, 22, 9, 5));
      expect(keep.includeTime, isNull, reason: 'not forced to false');

      final plain = dateWrite('2026-10-22', cell(DateTime(2026, 10, 19)));
      expect(plain.date, DateTime(2026, 10, 22));
      expect(plain.includeTime, isNull);
    });
  });

  test('every handler is stage 3', () {
    expect(h.keys, {
      'database.create',
      'row.add',
      'row.update',
      'row.remove',
      'field.add',
      'field.rename',
      'option.add',
    });
    expect(h.values.every((x) => x.stage == AssistStage.workspace), isTrue);
  });
}
