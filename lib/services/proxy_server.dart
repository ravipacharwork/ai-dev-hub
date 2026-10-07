import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import '../core/models.dart';
import 'openai_compatible_client.dart';
import 'router_service.dart';

/// OpenAI-compatible endpoint on the phone:
///   POST /v1/chat/completions   (stream and non-stream)
///   GET  /v1/models
/// Keep alive in the background with flutter_foreground_task (Android).
class ProxyServer {
  final RouterService router;
  final List<String> Function() modelIds;
  final List<HttpServer> _servers = [];
  String bearerToken;

  /// The embedded gateways are called by this app itself, so they must accept
  /// the app's origin header; the public proxy must not (loop protection).
  final bool allowAppOrigin;
  final String label;

  ProxyServer({
    required this.router,
    required this.modelIds,
    String? token,
    this.allowAppOrigin = false,
    this.label = 'AI Dev Hub proxy',
  }) : bearerToken = token ?? generateToken();

  static String generateToken() {
    final r = Random.secure();
    final bytes = List.generate(32, (_) => r.nextInt(256));
    return 'sk-local-${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  bool get running => _servers.isNotEmpty;
  bool lanActive = false; // false if LAN bind fell back to loopback

  /// [lan]=false binds loopback only (safe default). true binds all interfaces.
  Future<int> start({int port = 8080, bool lan = false}) async {
    await stop();
    final handler = const Pipeline()
        .addMiddleware(_loopGuard())
        .addMiddleware(_auth())
        .addHandler(_route);

    Future<HttpServer> bind(InternetAddress a, int p) => io.serve(handler, a, p, shared: true);

    HttpServer first;
    try {
      first = await bind(lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port);
      lanActive = lan;
    } on SocketException catch (e) {
      if (!lan) {
        throw SocketException('${e.message} (check INTERNET permission / try another port)');
      }
      // Wi-Fi sharing refused (hotspot/VPN/OEM restriction): stay on loopback.
      first = await bind(InternetAddress.loopbackIPv4, port);
      lanActive = false;
    }
    _servers.add(first);

    // "localhost" often resolves to ::1 first. Listen there too (best effort) so
    // apps using http://localhost:PORT do not get "connection refused".
    try {
      _servers.add(await bind(
          lanActive ? InternetAddress.anyIPv6 : InternetAddress.loopbackIPv6, first.port));
    } catch (_) {}
    return first.port;
  }

  Future<void> stop() async {
    for (final s in _servers) {
      await s.close(force: true);
    }
    _servers.clear();
  }

  /// Requests sent by this app itself (see OpenAICompatibleClient.originHeader)
  /// must never come back in: that would be a provider pointing at our own proxy.
  Middleware _loopGuard() => (inner) => (req) {
        if (!allowAppOrigin &&
            req.headers.containsKey(OpenAICompatibleClient.originHeader.toLowerCase())) {
          return _json(508, {
            'error': {
              'message': "This URL is AI Dev Hub's own local proxy. Don't add it as a "
                  'provider (it would call itself). Use your real provider URL instead.'
            }
          });
        }
        return inner(req);
      };

  Middleware _auth() => (inner) => (req) {
        final p = req.url.path;
        // Open health page so a browser test shows the server is up.
        if (req.method == 'GET' && (p.isEmpty || p == 'health' || p == 'v1' || p == 'v1/')) {
          return Response.ok(
              '$label is running.\n'
              'Call /v1/chat/completions or /v1/models with the header\n'
              'Authorization: Bearer <token from the Proxy screen>\n',
              headers: {'content-type': 'text/plain'});
        }
        final raw = (req.headers['authorization'] ?? '').trim();
        if (raw.isEmpty) {
          return _unauth('missing Authorization header (expected "Bearer <token>")');
        }
        final m = RegExp(r'^bearer\s+(.+)$', caseSensitive: false).firstMatch(raw);
        final got = (m?.group(1) ?? raw).trim(); // tolerate pasted whitespace / no scheme
        if (!_constEq(got, bearerToken.trim())) {
          return _unauth('invalid bearer token (copy the current one from the Proxy screen; '
              '"Regenerate" invalidates old tokens)');
        }
        return inner(req);
      };

  Response _unauth(String msg) => Response(401,
      body: jsonEncode({'error': {'message': msg}}),
      headers: {'content-type': 'application/json', 'www-authenticate': 'Bearer'});

  // Constant-time compare so the token can't be probed byte by byte.
  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Response> _route(Request req) async {
    final p = req.url.path;
    if (req.method == 'GET' && p == 'v1/models') {
      return _json(200, {
        'object': 'list',
        'data': [
          {'id': 'auto', 'object': 'model', 'owned_by': 'ai-dev-hub'},
          ...modelIds().map((m) => {'id': m, 'object': 'model', 'owned_by': 'ai-dev-hub'}),
        ],
      });
    }
    if (req.method == 'POST' && p == 'v1/chat/completions') {
      return _chat(req);
    }
    return _json(404, {'error': {'message': 'not found'}});
  }

  Future<Response> _chat(Request req) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json(400, {'error': {'message': 'invalid JSON'}});
    }
    final cr = ChatRequest(
      model: (body['model'] as String?) ?? 'auto',
      messages: List<Map<String, dynamic>>.from(body['messages'] ?? const []),
      temperature: (body['temperature'] as num?)?.toDouble(),
      topP: (body['top_p'] as num?)?.toDouble(),
      maxTokens: body['max_tokens'] as int?,
      tools: (body['tools'] as List?)?.cast<Map<String, dynamic>>(),
    );
    final wantsStream = body['stream'] == true;

    // Peek the first payload so we can still return a proper HTTP error
    // (instead of a 200 with a broken stream) when every provider fails.
    final it = StreamIterator(router.stream(cr));
    try {
      final hasFirst = await it.moveNext();
      if (!hasFirst) return _json(502, {'error': {'message': 'empty response'}});
      final first = it.current;

      if (wantsStream) {
        Stream<List<int>> sse() async* {
          try {
            yield utf8.encode('data: $first\n\n');
            while (await it.moveNext()) {
              yield utf8.encode('data: ${it.current}\n\n');
            }
          } catch (e) {
            yield utf8.encode(
                'data: ${jsonEncode({'error': {'message': '$e'}})}\n\n');
          } finally {
            await it.cancel();
          }
        }

        return Response.ok(sse(), headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
        });
      }

      // Non-stream: aggregate deltas into one chat.completion object.
      final text = StringBuffer();
      Map<String, dynamic>? usage;
      void eat(String payload) {
        if (payload == '[DONE]') return;
        final j = jsonDecode(payload) as Map<String, dynamic>;
        usage = (j['usage'] as Map?)?.cast<String, dynamic>() ?? usage;
        final ch = j['choices'] as List?;
        if (ch != null && ch.isNotEmpty) {
          final c = ((ch.first as Map)['delta'] as Map?)?['content'];
          if (c is String) text.write(c);
        }
      }

      eat(first);
      while (await it.moveNext()) {
        eat(it.current);
      }
      await it.cancel();
      return _json(200, {
        'object': 'chat.completion',
        'model': cr.model,
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': text.toString()},
            'finish_reason': 'stop',
          }
        ],
        if (usage != null) 'usage': usage,
      });
    } on AllProvidersFailed catch (e) {
      await it.cancel();
      return _json(502, {'error': {'message': '$e'}});
    } catch (e) {
      await it.cancel();
      return _json(500, {'error': {'message': '$e'}});
    }
  }

  Response _json(int code, Object body) => Response(code,
      body: jsonEncode(body), headers: {'content-type': 'application/json'});

  /// For the Proxy tab: show the user a reachable Wi-Fi address.
  static Future<List<String>> lanAddresses() async {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  }
}
