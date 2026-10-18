import 'dart:convert';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/core/config/kv_keys.dart';
import 'package:appflowy_backend/log.dart';

import 'assistant_models.dart';

const _maxApplied = 20;
const _maxTurns = 10;

/// Persists [AssistantState] for one user in [KeyValueStorage].
class AssistantStore {
  AssistantStore({required KeyValueStorage kv, required String userId})
      : _kv = kv,
        _key = '${KVKeys.assistant}.$userId';

  final KeyValueStorage _kv;
  final String _key;

  /// Missing or unreadable data yields a fresh state. Proposals left
  /// `applying` by an interrupted run become `partial`.
  Future<AssistantState> load() async {
    final raw = await _kv.get(_key);
    if (raw == null) return AssistantState();
    try {
      final state =
          AssistantState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      for (final a in state.applied) {
        if (a.status == AppliedStatus.applying) {
          a.status = AppliedStatus.partial;
        }
      }
      return state;
    } catch (e) {
      Log.error('Failed to load Assistant state: $e');
      return AssistantState();
    }
  }

  /// Keeps the newest 20 applied proposals and last 10 turns.
  Future<void> save(AssistantState state) {
    final json = state.toJson();
    json['applied'] =
        _last(state.applied, _maxApplied).map((e) => e.toJson()).toList();
    json['thread'] =
        _last(state.thread, _maxTurns).map((e) => e.toJson()).toList();
    return _kv.set(_key, jsonEncode(json));
  }
}

List<T> _last<T>(List<T> items, int n) =>
    items.length <= n ? items : items.sublist(items.length - n);
