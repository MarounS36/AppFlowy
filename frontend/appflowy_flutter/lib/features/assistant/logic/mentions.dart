class Mentionable {
  const Mentionable({required this.id, required this.name, required this.kind});

  final String id;
  final String name;

  /// 'board' | 'page' | 'database'
  final String kind;
}

/// Items whose trimmed name (>= 3 chars) appears in [message] as a whole,
/// case-insensitive word/phrase. Input order is kept.
List<Mentionable> findMentions(String message, List<Mentionable> items) {
  return items.where((item) {
    final name = item.name.trim();
    if (name.length < 3) return false;
    return RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(name)}(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    ).hasMatch(message);
  }).toList();
}

/// Monday 00:00 local of the week a scheduling [message] refers to;
/// [current] (an open proposal's week) when it names none.
DateTime targetWeekStart(DateTime now, String message, {DateTime? current}) {
  final text = message.toLowerCase();
  // DateTime(y, m, d) normalises overflow and stays correct across DST.
  final thisMonday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
  final nextMonday =
      DateTime(thisMonday.year, thisMonday.month, thisMonday.day + 7);
  if (text.contains('next week')) return nextMonday;
  if (text.contains('this week')) return thisMonday;
  return current ?? (now.weekday >= DateTime.friday ? nextMonday : thisMonday);
}
