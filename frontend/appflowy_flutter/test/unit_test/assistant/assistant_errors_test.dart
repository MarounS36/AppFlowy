import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/presentation/assistant_errors.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('error kind maps to its string', () {
    const expected = {
      OrganizeErrorKind.unauthorized: LocaleKeys.assistant_signInAgain,
      OrganizeErrorKind.notInvited: LocaleKeys.assistant_notInvited,
      OrganizeErrorKind.userLimit: LocaleKeys.assistant_userLimit,
      OrganizeErrorKind.globalLimit: LocaleKeys.assistant_globalLimit,
      OrganizeErrorKind.noteMissing: LocaleKeys.assistant_failed,
      OrganizeErrorKind.tooLarge: LocaleKeys.assistant_failed,
      OrganizeErrorKind.failed: LocaleKeys.assistant_failed,
    };
    expect(expected.keys, containsAll(OrganizeErrorKind.values));
    expected.forEach((k, v) => expect(assistantErrorKey(k), v, reason: k.name));
  });

  test('retry is true only for unauthorized and failed', () {
    for (final k in OrganizeErrorKind.values) {
      expect(
        assistantCanRetry(k),
        {OrganizeErrorKind.unauthorized, OrganizeErrorKind.failed}.contains(k),
        reason: k.name,
      );
    }
  });
}
