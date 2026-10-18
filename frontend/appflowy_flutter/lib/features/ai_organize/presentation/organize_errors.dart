import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/generated/locale_keys.g.dart';

/// Locale key (untranslated) describing [kind] to the user.
String organizeErrorKey(OrganizeErrorKind kind) => switch (kind) {
      OrganizeErrorKind.unauthorized => LocaleKeys.aiOrganize_signInAgain,
      OrganizeErrorKind.notInvited => LocaleKeys.aiOrganize_notInvited,
      OrganizeErrorKind.userLimit => LocaleKeys.aiOrganize_userLimit,
      OrganizeErrorKind.globalLimit => LocaleKeys.aiOrganize_globalLimit,
      OrganizeErrorKind.noteMissing => LocaleKeys.aiOrganize_noteMissing,
      OrganizeErrorKind.tooLarge ||
      OrganizeErrorKind.failed =>
        LocaleKeys.aiOrganize_failed,
    };

/// Retrying can only help after a token refresh or a transient failure; not
/// when uninvited, at a limit, the note is gone or too large.
bool organizeCanRetry(OrganizeErrorKind kind) => const {
      OrganizeErrorKind.unauthorized,
      OrganizeErrorKind.failed,
    }.contains(kind);
