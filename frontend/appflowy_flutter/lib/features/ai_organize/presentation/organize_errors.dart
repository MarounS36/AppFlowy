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

/// Retrying cannot help when the user is not invited or a limit is hit.
bool organizeCanRetry(OrganizeErrorKind kind) => !const {
      OrganizeErrorKind.notInvited,
      OrganizeErrorKind.userLimit,
      OrganizeErrorKind.globalLimit,
    }.contains(kind);
