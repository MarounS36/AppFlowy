part of 'database_actions.dart';

class _RowAdd extends _Base {
  _RowAdd(super.gw);

  @override
  String get type => 'row.add';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      super.validate(a, scope) ??
      _checkCells(scope, a.fields['database_id'], a.fields['cells']);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final cells = _cellsOf(a);
    final title = cells[labels['${a.fields['database_id']}#primary']] ??
        cells.values.firstOrNull ??
        '';
    return ActionPreview(
      text: 'Add row: $title',
      after: [
        for (final e in cells.entries) '${labels[e.key] ?? e.key}: ${e.value}',
      ].join('; '),
      editable: [...cells.keys],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final cells = await prepare(await mustDb(dbId), _cellsOf(a), scope);
    final id = await gw.addRow(dbId, cells);
    final Map<String, String> after;
    try {
      after = await gw.row(dbId, id) ?? (throw StateError('Row not found'));
    } catch (_) {
      try {
        await gw.removeRow(dbId, id);
      } catch (_) {}
      rethrow;
    }
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, id);
    return UndoRecord(
      type: type,
      data: {'database_id': dbId, 'row_id': id, 'after': after},
    );
  }

  /// Only if its writable cells are unchanged since.
  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final dbId = r.data['database_id'] as String;
    final id = r.data['row_id'] as String;
    final (s, stop) = await undoDb(dbId);
    if (stop != null) return stop;
    final cur = await gw.row(dbId, id);
    if (cur == null) return UndoOutcome.skippedGone;
    final after = r.data['after'] as Map;
    bool same(DbField f) {
      final a = '${after[f.id] ?? ''}', b = cur[f.id] ?? '';
      return a == b || _blank(f, a) && _blank(f, b);
    }

    if (!s!.fields.where((f) => f.writable).every(same)) {
      return UndoOutcome.skippedChanged;
    }
    await gw.removeRow(dbId, id);
    return UndoOutcome.reverted;
  }
}

class _RowUpdate extends _Base {
  _RowUpdate(super.gw);

  @override
  String get type => 'row.update';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final f = a.fields;
    if (f['cells'] is! Map || (f['cells'] as Map).isEmpty) {
      return 'Nothing to change';
    }
    return super.validate(a, scope) ??
        (_isRow(scope, f['database_id'], f['row_id'])
            ? _checkCells(scope, f['database_id'], f['cells'], f['row_id'])
            : 'Unknown row_id');
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final row = a.fields['row_id'];
    final cells = _cellsOf(a);
    String old(String k) => labels['$row#$k'] ?? '';
    String name(String k) => labels[k] ?? k;
    final changed = cells.keys.where((k) => old(k) != cells[k]);
    return ActionPreview(
      text: 'Change row: ${labels[row] ?? ''}',
      before: changed.map((k) => '${name(k)}: ${old(k)}').join('; '),
      after: changed.map((k) => '${name(k)}: ${cells[k]}').join('; '),
      editable: [...cells.keys],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final id = scope.resolve(a.fields['row_id'] as String);
    final s = await mustDb(dbId);
    final cur = await gw.row(dbId, id) ?? (throw StateError('Row not found'));
    // The live row may differ from what the AI saw: no date ranges, and no
    // cell too long for the context to have held it whole.
    for (final k in _cellsOf(a).keys.map(scope.resolve)) {
      final text = cur[k] ?? '';
      if (_isRangeIn(field(s, k)?.type, text) || text.length > _cellCap) {
        throw StateError("This cell can't be changed here");
      }
    }
    final cells = await prepare(s, _cellsOf(a), scope);
    final before = {for (final k in cells.keys) k: cur[k] ?? ''};
    await gw.updateRow(dbId, id, cells);
    final Map<String, String> now;
    try {
      now = await gw.row(dbId, id) ?? (throw StateError('Row not found'));
    } catch (_) {
      try {
        await gw.updateRow(dbId, id, before);
      } catch (_) {}
      rethrow;
    }
    return UndoRecord(
      type: type,
      data: {
        'database_id': dbId,
        'row_id': id,
        'before': before,
        'after': {for (final k in cells.keys) k: now[k] ?? ''},
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final dbId = r.data['database_id'] as String;
    final id = r.data['row_id'] as String;
    final (_, stop) = await undoDb(dbId);
    if (stop != null) return stop;
    final cur = await gw.row(dbId, id);
    if (cur == null) return UndoOutcome.skippedGone;
    final after = Map<String, String>.from(r.data['after'] as Map);
    if (after.entries.any((e) => cur[e.key] != e.value)) {
      return UndoOutcome.skippedChanged;
    }
    await gw.updateRow(
      dbId,
      id,
      Map<String, String>.from(r.data['before'] as Map),
    );
    return UndoOutcome.reverted;
  }
}

/// Known limit: undoing a remove re-adds the row under a NEW id.
class _RowRemove extends _Base {
  _RowRemove(super.gw);

  @override
  String get type => 'row.remove';

  /// Only rows whose non-empty cells are all writable (timestamp metadata
  /// aside) and not date ranges, so undo can restore them.
  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final dbId = a.fields['database_id'];
    final id = a.fields['row_id'];
    final bad = super.validate(a, scope);
    if (bad != null) return bad;
    if (!_isRow(scope, dbId, id)) return 'Unknown row_id';
    final cells = scope.items[id]?['cells'] as Map? ?? const {};
    final lost = cells.entries.any(
      (e) =>
          '${e.value}'.isNotEmpty &&
              scope.readOnlyIds.contains(e.key) &&
              !_metaNames.contains(scope.items[e.key]?['type']) ||
          _isRangeIn(_typeOf(scope.items[e.key]?['type']), e.value),
    );
    return lost ? "Row has data that can't be restored" : null;
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Remove row: ${labels[a.fields['row_id']] ?? ''}',
        destructive: true,
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final id = scope.resolve(a.fields['row_id'] as String);
    final s = await mustDb(dbId);
    final cur = await gw.row(dbId, id) ?? (throw StateError('Row not found'));
    final keep = <String, String>{};
    for (final f in s.fields) {
      final v = cur[f.id] ?? '';
      if (_blank(f, v) || _isMeta(f.type)) continue;
      if (!f.writable || _isRangeIn(f.type, v)) {
        throw StateError("${f.name} can't be restored");
      }
      keep[f.id] = v;
    }
    if (await gw.rowHasExtras(dbId, id)) {
      throw StateError(
        "The row's page, icon, cover or files can't be restored",
      );
    }
    await gw.removeRow(dbId, id);
    return UndoRecord(
      type: type,
      data: {'database_id': dbId, 'row_id': id, 'cells': keep},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    // Idempotent: a repeated undo must not add a second row.
    if (r.data['restored_id'] != null) return UndoOutcome.reverted;
    final dbId = r.data['database_id'] as String;
    final (s, stop) = await undoDb(dbId);
    if (stop != null) return stop;
    if (await gw.row(dbId, r.data['row_id'] as String) != null) {
      return UndoOutcome.skippedChanged;
    }
    final cells = {
      for (final e in (r.data['cells'] as Map).entries)
        if (field(s!, e.key as String)?.writable ?? false)
          e.key as String: e.value as String,
    };
    r.data['restored_id'] = await gw.addRow(dbId, cells);
    return UndoOutcome.reverted;
  }
}
