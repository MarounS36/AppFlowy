import 'dart:convert';

import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

OrganizeApi _api(MockClientHandler h) =>
    OrganizeApi(url: 'https://x.test/organize', client: MockClient(h));

Future<OrganizeErrorKind> _kind(OrganizeApi api) async {
  try {
    await api.organize(token: 't', body: {});
  } on OrganizeApiException catch (e) {
    return e.kind;
  }
  fail('expected OrganizeApiException');
}

void main() {
  test('sends bearer token and JSON', () async {
    late http.Request req;
    final api = _api((r) async {
      req = r;
      return http.Response('{"title":null,"folder_id":null,"reason":"r"}', 200);
    });
    await api.organize(token: 'tok', body: {'a': 1});
    expect(req.method, 'POST');
    expect(req.headers['Authorization'], 'Bearer tok');
    expect(req.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(req.body), {'a': 1});
  });

  test('parses suggestion', () async {
    final api = _api(
      (_) async =>
          http.Response('{"title":"T","folder_id":null,"reason":"r"}', 200),
    );
    final s = await api.organize(token: 't', body: {});
    expect(s.title, 'T');
    expect(s.folderId, isNull);
    expect(s.reason, 'r');
  });

  test('maps status codes', () async {
    const table = {
      401: OrganizeErrorKind.unauthorized,
      403: OrganizeErrorKind.notInvited,
      413: OrganizeErrorKind.tooLarge,
      500: OrganizeErrorKind.failed,
    };
    for (final e in table.entries) {
      final api = _api((_) async => http.Response('{}', e.key));
      expect(await _kind(api), e.value, reason: '${e.key}');
    }
  });

  test('distinguishes daily limits', () async {
    var api = _api((_) async => http.Response('{"error":"user_limit"}', 429));
    expect(await _kind(api), OrganizeErrorKind.userLimit);
    api = _api((_) async => http.Response('{"error":"global_limit"}', 429));
    expect(await _kind(api), OrganizeErrorKind.globalLimit);
  });

  test('network errors and bad bodies fail', () async {
    var api = _api((_) async => throw http.ClientException('down'));
    expect(await _kind(api), OrganizeErrorKind.failed);
    api = _api((_) async => http.Response('"oops"', 200));
    expect(await _kind(api), OrganizeErrorKind.failed);
  });
}
