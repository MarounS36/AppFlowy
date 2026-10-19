import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:flutter_test/flutter_test.dart';

Mentionable m(String id, String name) =>
    Mentionable(id: id, name: name, kind: 'board');

List<String> ids(String msg, List<Mentionable> items) =>
    findMentions(msg, items).map((e) => e.id).toList();

void main() {
  group('findMentions', () {
    test('matches whole name, not short names', () {
      expect(
        ids('set up my Move board', [m('1', 'Move'), m('2', 'Mo')]),
        ['1'],
      );
    });
    test('whole word only', () {
      expect(ids('please remove it', [m('1', 'Move')]), isEmpty);
      expect(ids('Moves are fun', [m('1', 'Move')]), isEmpty);
      expect(ids('Move2 plan', [m('1', 'Move')]), isEmpty);
    });
    test('case-insensitive, multi-word, punctuation boundaries', () {
      expect(ids('see "trip plan"!', [m('1', 'Trip Plan')]), ['1']);
      expect(ids('MOVE.', [m('1', 'move')]), ['1']);
    });
    test('names are literal', () {
      expect(ids('a c++ list', [m('1', 'c++ ')]), ['1']);
      expect(ids('abc', [m('1', 'a.c')]), isEmpty);
    });
    test('same-name items both returned, in order', () {
      expect(
        ids('open Home now', [m('1', 'Home'), m('2', 'Other'), m('3', 'Home')]),
        ['1', '3'],
      );
    });
  });

  group('targetWeekStart', () {
    void expectWeek(DateTime now, String msg, DateTime monday) =>
        expect(targetWeekStart(now, msg), monday);

    test('Wednesday default is this Monday', () {
      expectWeek(DateTime(2026, 10, 21, 15), 'plan', DateTime(2026, 10, 19));
    });
    test('Saturday default is next Monday', () {
      expectWeek(DateTime(2026, 10, 24), 'plan', DateTime(2026, 10, 26));
    });
    test('this week / next week overrides', () {
      expectWeek(DateTime(2026, 10, 24), 'This Week', DateTime(2026, 10, 19));
      expectWeek(DateTime(2026, 10, 21), 'NEXT WEEK', DateTime(2026, 10, 26));
    });
    test('across DST and month end', () {
      expectWeek(DateTime(2026, 10, 28), 'next week', DateTime(2026, 11, 2));
    });
  });
}
