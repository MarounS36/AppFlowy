import 'dart:convert';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/core/config/kv_keys.dart';
import 'package:appflowy_backend/log.dart';

import 'organize_models.dart';

const _maxEntries = 200;

/// Persists [OrganizeState] for one user in [KeyValueStorage].
class OrganizeStore {
  OrganizeStore({required KeyValueStorage kv, required String userId})
      : _kv = kv,
        _key = '${KVKeys.aiOrganize}.$userId';

  final KeyValueStorage _kv;
  final String _key;

  /// Missing or unreadable data yields a fresh state. Proposals left in
  /// `processing` by an interrupted run become `stale` (they have a result)
  /// or `failed` (they don't).
  Future<OrganizeState> load() async {
    final raw = await _kv.get(_key);
    if (raw == null) {
      return OrganizeState();
    }
    try {
      final state =
          OrganizeState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      for (final p in state.proposals) {
        if (p.state != ProposalState.processing) continue;
        if (p.proposedTitle != null || p.proposedFolderId != null) {
          p.state = ProposalState.stale;
        } else {
          p.state = ProposalState.failed;
          p.error = OrganizeErrorKind.failed;
        }
      }
      return state;
    } catch (e) {
      Log.error('Failed to load AI Organize state: $e');
      return OrganizeState();
    }
  }

  /// Keeps the newest 200 proposals and history entries.
  Future<void> save(OrganizeState state) {
    final json = state.toJson();
    json['proposals'] = _newest(
      state.proposals,
      (p) => p.createdAt,
    ).map((e) => e.toJson()).toList();
    json['history'] = _newest(
      state.history,
      (h) => h.appliedAt,
    ).map((e) => e.toJson()).toList();
    return _kv.set(_key, jsonEncode(json));
  }
}

/// The [_maxEntries] newest items, in their original order.
List<T> _newest<T>(List<T> items, DateTime Function(T) time) {
  if (items.length <= _maxEntries) return items;
  final keep = ([...items]..sort((a, b) => time(b).compareTo(time(a))))
      .take(_maxEntries)
      .toSet();
  return items.where(keep.contains).toList();
}
