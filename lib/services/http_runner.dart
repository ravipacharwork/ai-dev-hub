import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Looks up a named secret ("github"). The value never goes through the chat:
/// the model writes `{{secret:github}}` and the app swaps it in at send time.
typedef SecretLookup = Future<String?> Function(String name);

class HttpOutcome {
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
  final int ms;
  final String finalUrl;
  const HttpOutcome(this.status, this.headers, this.bytes, this.ms, this.finalUrl);
  bool get ok => status >= 200 && status < 300;
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// One HTTP client for the terminal (`curl`, `wget`) and `http_request` /
/// `browser_http_test`. Features the old test tool lacked: any method, custom
/// headers, raw bodies, secret placeholders and file download.
class HttpRunner {
  final SecretLookup? secrets;
  HttpRunner([this.secrets]);

  static final _ph = RegExp(r'\{\{\s*secret:([a-zA-Z0-9_\-]+)\s*\}\}|\$\{?GITHUB_TOKEN\}?');

  /// Hosts that automatically get the GitHub token when the caller sent no
  /// Authorization header. The token is never sent to any other host.
  static const githubHosts = {'api.github.com', 'uploads.github.com'};

  Future<String> _fill(String v) async {
    final matches = _ph.allMatches(v).toList();
    if (matches.isEmpty) return v;
    var out = v;
    for (final m in matches) {
      final name = m.group(1) ?? 'github';
      final value = await secrets?.call(name);
      if (value == null || value.isEmpty) {
        throw HttpException('Secret "$name" is not set. Add it in Connectors (GitHub token).');
      }
      out = out.replaceAll(m.group(0)!, value);
    }
    return out;
  }

  /// Replaces known secret values in text with ***.
  Future<String> redact(String s) async {
    for (final n in const ['github']) {
      final v = await secrets?.call(n);
      if (v != null && v.length > 6) s = s.replaceAll(v, '***');
    }
    return s;
  }

  Future<HttpOutcome> send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    Object? body, // String | List<int> | Map | List
    bool follow = true,
    Duration timeout = const Duration(seconds: 30),
    int maxBytes = 50 * 1024 * 1024,
  }) async {
    final sw = Stopwatch()..start();
    var u = Uri.parse(await _fill(url));
    if (!(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      throw const HttpException('Only full http:// or https:// URLs are allowed.');
    }
    final hdr = <String, String>{};
    for (final e in headers.entries) {
      hdr[e.key] = await _fill(e.value);
    }
    List<int>? payload;
    if (body is Map || body is List) {
      payload = utf8.encode(jsonEncode(body));
      hdr.putIfAbsent('Content-Type', () => 'application/json');
    } else if (body is String) {
      payload = utf8.encode(await _fill(body));
    } else if (body is List<int>) {
      payload = body;
    }
    final startHost = u.host;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      var m = method.toUpperCase();
      for (var hop = 0; hop < 6; hop++) {
        final req = await client.openUrl(m, u).timeout(timeout);
        req.followRedirects = false;
        final sameHost = u.host == startHost;
        hdr.forEach((k, v) {
          // Never forward credentials to a different host after a redirect.
          if (!sameHost && const ['authorization', 'cookie'].contains(k.toLowerCase())) return;
          req.headers.set(k, v);
        });
        if (githubHosts.contains(u.host) &&
            !hdr.keys.any((k) => k.toLowerCase() == 'authorization')) {
          final t = await secrets?.call('github');
          if (t != null && t.isNotEmpty) {
            req.headers.set('Authorization', 'Bearer $t');
            req.headers.set('Accept', hdr['Accept'] ?? 'application/vnd.github+json');
            req.headers.set('X-GitHub-Api-Version', '2022-11-28');
          }
        }
        req.headers.set('User-Agent', hdr['User-Agent'] ?? 'AI-Dev-Hub/1.0');
        if (payload != null && hop == 0) {
          req.contentLength = payload.length;
          req.add(payload);
        }
        final res = await req.close().timeout(timeout);
        if (follow && const [301, 302, 303, 307, 308].contains(res.statusCode)) {
          final loc = res.headers.value('location');
          await res.drain<void>();
          if (loc != null) {
            u = u.resolve(loc);
            if (res.statusCode == 303 || ((res.statusCode == 301 || res.statusCode == 302) && m == 'POST')) {
              m = 'GET';
              payload = null;
            }
            continue;
          }
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in res.timeout(timeout)) {
          builder.add(chunk);
          if (builder.length > maxBytes) {
            throw HttpException('Response larger than ${maxBytes ~/ (1024 * 1024)} MB.');
          }
        }
        final h = <String, String>{};
        res.headers.forEach((k, v) => h[k] = v.join(', '));
        return HttpOutcome(res.statusCode, h, builder.takeBytes(), sw.elapsedMilliseconds, u.toString());
      }
      throw const HttpException('Too many redirects.');
    } finally {
      client.close(force: true);
    }
  }
}
