import 'dart:convert';

import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:http/http.dart' as http;

/// POSTs JSON with a Bearer token to an InkNest AI function and returns the
/// decoded 200 body. Every failure is thrown as [OrganizeApiException].
Future<Map<String, dynamic>> postAiFunction({
  required http.Client client,
  required String url,
  required String token,
  required Map<String, dynamic> body,
}) async {
  final http.Response res;
  try {
    res = await client
        .post(
          Uri.parse(url),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 150));
  } catch (_) {
    // Timeout, bad URL, unencodable body, TLS/socket errors: all `failed`.
    throw const OrganizeApiException(OrganizeErrorKind.failed);
  }

  switch (res.statusCode) {
    case 200:
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        throw const OrganizeApiException(OrganizeErrorKind.failed);
      }
    case 401:
      throw const OrganizeApiException(OrganizeErrorKind.unauthorized);
    case 403:
      throw const OrganizeApiException(OrganizeErrorKind.notInvited);
    case 413:
      throw const OrganizeApiException(OrganizeErrorKind.tooLarge);
    case 429:
      var global = false;
      try {
        global = (jsonDecode(res.body) as Map)['error'] == 'global_limit';
      } catch (_) {}
      throw OrganizeApiException(
        global ? OrganizeErrorKind.globalLimit : OrganizeErrorKind.userLimit,
      );
    default:
      throw const OrganizeApiException(OrganizeErrorKind.failed);
  }
}
