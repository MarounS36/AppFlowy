import 'package:appflowy/features/ai_organize/data/ai_function_client.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:http/http.dart' as http;

/// Replaces the last path segment of the organize URL with `assist`.
String assistUrlFrom(String organizeUrl) {
  if (organizeUrl.isEmpty) return '';
  final i = organizeUrl.lastIndexOf('/');
  return '${organizeUrl.substring(0, i + 1)}assist';
}

class AssistReply {
  const AssistReply({required this.note, required this.actions});

  final String note;
  final List<AssistAction> actions;
}

/// Calls the InkNest Supabase `assist` function.
class AssistApi {
  AssistApi({required this.url, http.Client? client})
      : _client = client ?? http.Client();

  final String url;
  final http.Client _client;

  Future<AssistReply> send({
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
      return AssistReply(
        note: json['note'] as String,
        actions: [
          for (final a in json['actions'] as List)
            AssistAction(
              type: (a as Map)['type'] as String,
              fields: Map<String, dynamic>.from(a),
            ),
        ],
      );
    } catch (_) {
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
  }
}
