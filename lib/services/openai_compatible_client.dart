import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/models.dart';

/// One client for every provider: OpenRouter, Gemini (OpenAI-compat endpoint),
/// NVIDIA NIM, Groq, Mistral, Custom (incl. self-hosted OmniRoute).
///
/// Base URLs (all OpenAI-compatible):
///   openrouter  https://openrouter.ai/api/v1
///   gemini      https://generativelanguage.googleapis.com/v1beta/openai
///   nvidia      https://integrate.api.nvidia.com/v1
///   groq        https://api.groq.com/openai/v1
///   mistral     https://api.mistral.ai/v1
class OpenAICompatibleClient {
  final Dio _dio;
  OpenAICompatibleClient([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 120),
            ));

  /// Marks every request this app sends. The local proxy refuses requests that
  /// carry it, so pointing a provider at the app's own proxy cannot loop.
  static const originHeader = 'X-AI-Dev-Hub-Origin';

  /// Trim, drop a pasted "/chat/completions" or "/models" tail and trailing slashes.
  static String normalizeBase(String base) => base
      .trim()
      .replaceAll(RegExp(r'/(chat/completions|models)/*$'), '')
      .replaceAll(RegExp(r'/+$'), '');

  static String _join(String base, String path) => '${normalizeBase(base)}/$path';

  Options _opts(Endpoint e, {bool stream = false}) => Options(
        responseType: stream ? ResponseType.stream : ResponseType.json,
        headers: {
          // No key -> no Authorization header (an empty "Bearer " gets rejected).
          if (e.apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${e.apiKey.trim()}',
          originHeader: '1',
          'Content-Type': 'application/json',
          if (stream) 'Accept': 'text/event-stream',
          ...e.extraHeaders,
        },
        validateStatus: (_) => true, // we classify errors ourselves
      );

  /// Raw SSE payloads (the text after `data: `), including the final `[DONE]`.
  /// Used directly by the proxy server for byte-faithful passthrough.
  Stream<String> streamRaw(Endpoint e, ChatRequest req,
      {CancelToken? cancel}) async* {
    final Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        _join(e.baseUrl, 'chat/completions'),
        data: jsonEncode(req.toBody(e.model)),
        options: _opts(e, stream: true),
        cancelToken: cancel,
      );
    } on DioException catch (ex) {
      if (CancelToken.isCancel(ex)) rethrow;
      throw TransientError(ex.message ?? 'network error');
    }

    final status = res.statusCode ?? 0;
    if (status != 200) {
      final body = await _readAll(res.data!.stream);
      throw classify(status, body, res.headers);
    }

    // SSE parsing: split on newlines, keep `data:` lines, tolerate chunk splits.
    var buffer = '';
    await for (final chunk in res.data!.stream.cast<List<int>>()) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      int nl;
      while ((nl = buffer.indexOf('\n')) != -1) {
        final line = buffer.substring(0, nl).trimRight();
        buffer = buffer.substring(nl + 1);
        if (line.startsWith('data:')) {
          final payload = line.substring(5).trim();
          if (payload.isNotEmpty) yield payload;
        }
      }
    }
    final tail = buffer.trim();
    if (tail.startsWith('data:')) {
      final payload = tail.substring(5).trim();
      if (payload.isNotEmpty) yield payload;
    }
  }

  /// Convenience for the chat UI: only the text deltas.
  Stream<String> streamText(Endpoint e, ChatRequest req,
      {CancelToken? cancel}) async* {
    await for (final p in streamRaw(e, req, cancel: cancel)) {
      if (p == '[DONE]') return;
      try {
        final j = jsonDecode(p) as Map<String, dynamic>;
        final choices = j['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'] as Map?;
        final text = delta?['content'];
        if (text is String && text.isNotEmpty) yield text;
      } catch (_) {/* ignore keep-alives / odd chunks */}
    }
  }

  /// GET /models — used by "Test connection" and live gateway model sync.
  Future<List<String>> listModels(Endpoint e) async {
    final res = await _dio.get(_join(e.baseUrl, 'models'), options: _opts(e));
    final status = res.statusCode ?? 0;
    if (status != 200) throw classify(status, '${res.data}', res.headers);
    final data = (res.data is Map ? res.data['data'] : null) as List? ?? [];
    return data.map((m) => (m as Map)['id'].toString()).toList();
  }

  /// Latency + auth check for the Providers screen.
  Future<Duration> testConnection(Endpoint e) async {
    final sw = Stopwatch()..start();
    await listModels(e);
    return sw.elapsed;
  }

  static LlmError classify(int status, String body, Headers headers) {
    final msg = body.length > 300 ? body.substring(0, 300) : body;
    if (status == 429) {
      final ra = int.tryParse(headers.value('retry-after') ?? '');
      return RateLimitError(msg, Duration(seconds: ra ?? 30));
    }
    if (status >= 500 || status == 408) return TransientError(msg, status);
    return FatalError(msg, status); // 400/401/403/404...
  }

  static Future<String> _readAll(Stream<Uint8List> s) async =>
      utf8.decode(await s.expand((c) => c).toList(), allowMalformed: true);
}
