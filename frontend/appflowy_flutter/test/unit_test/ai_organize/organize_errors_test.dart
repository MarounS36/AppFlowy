import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_errors.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('error kind maps to its string', () {
    const expected = {
      OrganizeErrorKind.unauthorized: LocaleKeys.aiOrganize_signInAgain,
      OrganizeErrorKind.notInvited: LocaleKeys.aiOrganize_notInvited,
      OrganizeErrorKind.userLimit: LocaleKeys.aiOrganize_userLimit,
      OrganizeErrorKind.globalLimit: LocaleKeys.aiOrganize_globalLimit,
      OrganizeErrorKind.noteMissing: LocaleKeys.aiOrganize_noteMissing,
      OrganizeErrorKind.tooLarge: LocaleKeys.aiOrganize_failed,
      OrganizeErrorKind.failed: LocaleKeys.aiOrganize_failed,
    };
    expect(expected.keys, containsAll(OrganizeErrorKind.values));
    expected.forEach((k, v) => expect(organizeErrorKey(k), v, reason: k.name));
  });

  test('retry is true only for unauthorized and failed', () {
    for (final k in OrganizeErrorKind.values) {
      expect(
        organizeCanRetry(k),
        {OrganizeErrorKind.unauthorized, OrganizeErrorKind.failed}.contains(k),
        reason: k.name,
      );
    }
  });
}
