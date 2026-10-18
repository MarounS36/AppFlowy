import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/core/config/kv_keys.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';

/// The space new assistant-made pages go into: the last opened one, else the
/// first space.
Future<String> currentSpaceId() async {
  final space = await getIt<KeyValueStorage>().get(KVKeys.lastOpenedSpaceId);
  if (space != null && space.isNotEmpty) return space;
  final views = (await ViewBackendService.getAllViews()).getOrThrow().items;
  return views.firstWhere((v) => v.isSpace).id;
}
