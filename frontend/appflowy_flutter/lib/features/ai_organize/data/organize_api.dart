import 'dart:convert';

import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:http/http.dart' as http;

class OrganizeSuggestion {
  const OrganizeSuggestion({this.title, this.folderId, required this.reason});

  final String? title;
  final String? folderId;
  final String reason;
}

class OrganizeApiException implements Exception {
  const OrganizeApiException(this.kind);

  final OrganizeErrorKind kind;

  @override
  String toString() => 'OrganizeApiException(${kind.name})';
}

/// Calls the InkNest Supabase `organize` function.
class OrganizeApi {
  OrganizeApi({required this.url, http.Client? client})
      : _client = client ?? http.Client();

  final String url;
  final http.Client _client;

  Future<OrganizeSuggestion> organize({
    required String token,
    required Map<String, dynamic> body,
  }) async {
    final http.Response res;
    try {
      res = await _client
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
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          return OrganizeSuggestion(
            title: json['title'] as String?,
            folderId: json['folder_id'] as String?,
            reason: json['reason'] as String,
          );
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
}
