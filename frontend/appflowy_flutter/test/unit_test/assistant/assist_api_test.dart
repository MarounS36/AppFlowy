import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/data/assist_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AssistApi _api(MockClientHandler h) =>
    AssistApi(url: 'https://x.test/assist', client: MockClient(h));

Future<OrganizeErrorKind> _kind(AssistApi api) async {
  try {
    await api.send(token: 't', body: {});
  } on OrganizeApiException catch (e) {
    return e.kind;
  }
  fail('expected OrganizeApiException');
}

void main() {
  test('assistUrlFrom swaps last segment', () {
    expect(
      assistUrlFrom('https://x.supabase.co/functions/v1/organize'),
      'https://x.supabase.co/functions/v1/assist',
    );
    expect(assistUrlFrom(''), '');
  });

  test('send parses note and actions', () async {
    final api = _api(
      (_) async => http.Response(
        '{"note":"n","actions":[{"type":"create_page","title":"T"}]}',
        200,
      ),
    );
    final r = await api.send(token: 't', body: {});
    expect(r.note, 'n');
    expect(r.actions.single.type, 'create_page');
    expect(r.actions.single.fields['title'], 'T');
    expect(r.actions.single.fields['type'], 'create_page');
  });

  test('send maps 429 global_limit', () async {
    final api =
        _api((_) async => http.Response('{"error":"global_limit"}', 429));
    expect(await _kind(api), OrganizeErrorKind.globalLimit);
  });

  test('malformed actions -> failed', () async {
    for (final b in [
      '{"note":"n","actions":"x"}',
      '{"actions":[]}',
      '{"note":"n","actions":[{"title":"no type"}]}',
    ]) {
      expect(
        await _kind(_api((_) async => http.Response(b, 200))),
        OrganizeErrorKind.failed,
        reason: b,
      );
    }
  });
}
