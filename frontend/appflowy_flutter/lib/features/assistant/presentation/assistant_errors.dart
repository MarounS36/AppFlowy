import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/generated/locale_keys.g.dart';

/// Locale key (untranslated) describing [kind] to the user.
String assistantErrorKey(OrganizeErrorKind kind) => switch (kind) {
      OrganizeErrorKind.unauthorized => LocaleKeys.assistant_signInAgain,
      OrganizeErrorKind.notInvited => LocaleKeys.assistant_notInvited,
      OrganizeErrorKind.userLimit => LocaleKeys.assistant_userLimit,
      OrganizeErrorKind.globalLimit => LocaleKeys.assistant_globalLimit,
      OrganizeErrorKind.noteMissing ||
      OrganizeErrorKind.tooLarge ||
      OrganizeErrorKind.failed =>
        LocaleKeys.assistant_failed,
    };

/// Retrying can only help after a token refresh or a transient failure.
bool assistantCanRetry(OrganizeErrorKind kind) => const {
      OrganizeErrorKind.unauthorized,
      OrganizeErrorKind.failed,
    }.contains(kind);
