import 'package:appflowy/features/ai_organize/data/ai_function_client.dart';
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
    final json = await postAiFunction(
      client: _client,
      url: url,
      token: token,
      body: body,
    );
    try {
      return OrganizeSuggestion(
        title: json['title'] as String?,
        folderId: json['folder_id'] as String?,
        reason: json['reason'] as String,
      );
    } catch (_) {
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
  }
}
