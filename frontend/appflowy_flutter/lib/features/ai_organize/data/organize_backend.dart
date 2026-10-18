import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/organize_rules.dart';
import 'package:appflowy/features/page_access_level/data/repositories/rust_page_access_level_repository_impl.dart';
import 'package:appflowy/features/share_tab/data/models/share_access_level.dart';
import 'package:appflowy/shared/af_user_profile_extension.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/protobuf/flowy-document/entities.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:appflowy_result/appflowy_result.dart';

/// Thin wrappers over the AppFlowy backend used by AI Organize. No logic;
/// exercised on device only (unit tests mock it).
class OrganizeBackend {
  const OrganizeBackend();

  Future<String?> accessToken() async =>
      (await UserBackendService.getCurrentUserProfile())
          .toNullable()
          ?.authToken;

  /// Null if missing or in trash.
  Future<ViewPB?> view(String viewId) =>
      ViewBackendService.getView(viewId).toNullable();

  /// Throws FlowyError.
  Future<List<ViewPB>> allViews() async =>
      (await ViewBackendService.getAllViews().getOrThrow()).items;

  /// Null if the view is missing. Throws FlowyError if the text can't be read.
  Future<({NoteSnapshot snapshot, String text})?> readNote(
    String noteId,
  ) async {
    final note = await view(noteId);
    if (note == null) return null;
    final text = (await DocumentEventGetDocumentText(
      OpenDocumentPayloadPB(documentId: noteId),
    ).send().getOrThrow())
        .text;
    final siblings =
        await ViewBackendService.getChildViews(viewId: note.parentViewId)
                .toNullable() ??
            const <ViewPB>[];
    final i = siblings.indexWhere((v) => v.id == noteId);
    return (
      snapshot: NoteSnapshot(
        title: note.name,
        parentId: note.parentViewId,
        prevSiblingId: i > 0 ? siblings[i - 1].id : null,
        bodyHash: bodyHash(text),
      ),
      text: text,
    );
  }

  Future<bool> canEdit(String viewId) async {
    final level = await RustPageAccessLevelRepositoryImpl()
        .getAccessLevel(viewId)
        .toNullable();
    return level == ShareAccessLevel.readAndWrite ||
        level == ShareAccessLevel.fullAccess;
  }

  /// Throws FlowyError.
  Future<void> rename(String viewId, String name) =>
      ViewBackendService.updateView(viewId: viewId, name: name).getOrThrow();

  /// Throws FlowyError.
  Future<void> move(
    String viewId, {
    required String parentId,
    String? prevViewId,
  }) =>
      ViewBackendService.moveViewV2(
        viewId: viewId,
        newParentId: parentId,
        prevViewId: prevViewId,
      ).getOrThrow();
}
