import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'default_providers.dart';
import 'openai_compatible_client.dart';

/// Router: ordered fallback across the built-in gateways (OmniRoute) followed by any extra provider keys the user has added.
class RouterService {
  final OpenAICompatibleClient client;
  final List<Endpoint> Function() chain; // user's ordered targets (keys resolved)
  final Map<String, DateTime> _cooldownUntil = {};
  final Map<String, ProviderStats> stats;

  /// Optional routing policy hooks (used by the embedded OmniRoute
  /// gateways): reorder the healthy targets, and observe each attempt.
  final List<Endpoint> Function(List<Endpoint>)? order;
  final void Function(Endpoint)? onAttempt;

  RouterService({
    required this.client,
    required this.chain,
    Map<String, ProviderStats>? stats,
    this.order,
    this.onAttempt,
  }) : stats = stats ?? {};

  bool _cooling(Endpoint e) {
    final t = _cooldownUntil[e.id];
    return t != null && DateTime.now().isBefore(t);
  }

  final Map<String, String> _lastErr = {};
  final Set<String> _rateLimited = {};

  void _cool(Endpoint e, Duration d, [Object? err, bool rate = false]) {
    _cooldownUntil[e.id] = DateTime.now().add(d);
    if (err != null) _lastErr[e.id] = _short(err);
    rate ? _rateLimited.add(e.id) : _rateLimited.remove(e.id);
  }

  static String _short(Object err) {
    final t = err is LlmError ? err.message : '$err';
    final one = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 300 ? '${one.substring(0, 300)}...' : one;
  }

  /// Forget all cool-downs (call when keys / URLs change).
  void resetCooldowns() {
    _cooldownUntil.clear();
    _lastErr.clear();
    _rateLimited.clear();
  }

  String _details(Iterable<Endpoint> es) {
    final seen = <String>{};
    final lines = <String>[];
    for (final e in es) {
      final key = '${e.providerId}/${e.model}';
      final err = _lastErr[e.id];
      if (err == null || !seen.add(key)) continue;
      final t = _cooldownUntil[e.id];
      final left = t == null ? 0 : t.difference(DateTime.now()).inSeconds;
      lines.add('- ${DefaultProviders.label(e.providerId)}/${e.model}: $err'
          '${left > 0 ? ' (retry in ${left}s)' : ''}');
    }
    return lines.join('\n');
  }

  /// Targets that are configured AND not cooling down after an error — i.e.
  /// the models the user can actually use right now.
  List<Endpoint> available() => chain().where((e) => !_cooling(e)).toList();

  /// Streams raw SSE payloads from the first healthy target.
  /// Fails over ONLY before the first payload is emitted — after that, switching
  /// providers would duplicate/garble output, so the error is rethrown instead.
  Stream<String> stream(ChatRequest req, {CancelToken? cancel}) async* {
    Object? lastError;
    final candidates = chain().where((e) {
      // A specific model request pins to that model; "auto" uses the whole chain.
      if (req.model == 'auto') return !e.selectableOnly;
      return e.id == req.model || e.model == req.model;
    }).toList();

    if (candidates.isEmpty) {
      throw AllProvidersFailed(
          null,
          req.model == 'auto'
              ? 'No providers configured. Open Settings > Providers and add at least one API key (Groq, Gemini, OpenRouter, or a free Pollinations key).'
              : 'Model "${req.model}" is not available. Switch to Auto or pick another model.');
    }

    // Prefer healthy targets. If every target is cooling, try the ones that
    // are NOT rate-limited anyway (a cool-down must never lock the user out
    // after they fixed a URL or key). Rate-limited ones really are skipped.
    var targets = candidates.where((e) => !_cooling(e)).toList();
    if (targets.isEmpty) {
      targets = candidates.where((e) => !_rateLimited.contains(e.id)).toList();
    }
    final skipped = candidates.length - targets.length;
    final hasImages = req.messages.any((m) => m['content'] is List);
    if (order != null) targets = order!(targets);
    for (final e in targets) {
      onAttempt?.call(e);
      final s = stats.putIfAbsent(e.providerId, ProviderStats.new);
      final sw = Stopwatch()..start();
      final it = StreamIterator(client.streamRaw(e, req, cancel: cancel));
      var emitted = false;
      var prompt = 0, completion = 0;
      try {
        while (await it.moveNext()) {
          final p = it.current;
          if (!emitted) {
            emitted = true;
            s.lastLatencyMs = sw.elapsedMilliseconds;
          }
          final usage = _usageOf(p);
          if (usage != null) {
            prompt = usage.$1;
            completion = usage.$2;
          }
          yield p;
        }
        s.record(
            latencyMs: s.lastLatencyMs, prompt: prompt, completion: completion);
        return; // success
      } on RateLimitError catch (err) {
        s.errors++;
        _cool(e, err.retryAfter, err, true);
        lastError = err;
        if (emitted) rethrow;
      } on TransientError catch (err) {
        s.errors++;
        _cool(e, const Duration(seconds: 20), err);
        lastError = err;
        if (emitted) rethrow;
      } on FatalError catch (err) {
        s.errors++;
        // A text-only model rejecting a photo is not a bad key: skip the long cool-down.
        if (!hasImages) _cool(e, const Duration(minutes: 5), err); // bad key / model: stop hammering
        lastError = err;
        if (emitted) rethrow;
      } finally {
        await it.cancel();
      }
    }
    if (lastError == null && skipped > 0) {
      throw AllProvidersFailed(
          null,
          'All matching providers are rate-limited. Try again shortly.',
          _details(candidates));
    }
    throw AllProvidersFailed(lastError, null, _details(candidates));
  }

  static (int, int)? _usageOf(String payload) {
    if (payload == '[DONE]' || !payload.contains('"usage"')) return null;
    try {
      final u = (jsonDecode(payload) as Map)['usage'] as Map?;
      if (u == null) return null;
      return ((u['prompt_tokens'] ?? 0) as int, (u['completion_tokens'] ?? 0) as int);
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Remote provider registry: new base URLs / model IDs without an app update.
// ---------------------------------------------------------------------------

class ProviderDef {
  final String id, name, baseUrl;
  final List<String> models;
  final bool requiresKey;
  ProviderDef.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        baseUrl = j['baseUrl'],
        models = List<String>.from(j['models'] ?? const []),
        requiresKey = j['requiresKey'] ?? true;
}

/// Point [registryUrl] at a raw JSON file you control, e.g.
/// https://raw.githubusercontent.com/<you>/<repo>/main/providers.json
/// Schema: { "version": 3, "providers": [ {id,name,baseUrl,models[],requiresKey} ] }
///
/// Strategy: ETag-cached fetch -> save to prefs -> fall back to last good copy
/// -> fall back to bundled asset. Add Ed25519 verification of the file before
/// trusting it if the URL is not under your control.
class ProviderRegistry {
  static const _cacheKey = 'provider_registry_json';
  static const _etagKey = 'provider_registry_etag';
  final String registryUrl;
  final Dio _dio;
  ProviderRegistry(this.registryUrl, [Dio? dio]) : _dio = dio ?? Dio();

  Future<List<ProviderDef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final etag = prefs.getString(_etagKey);
      final res = await _dio.get<String>(registryUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {if (etag != null) 'If-None-Match': etag},
            validateStatus: (s) => s == 200 || s == 304,
            receiveTimeout: const Duration(seconds: 8),
          ));
      if (res.statusCode == 200 && res.data != null) {
        _parse(res.data!); // throws if malformed -> keeps old cache
        await prefs.setString(_cacheKey, res.data!);
        final newEtag = res.headers.value('etag');
        if (newEtag != null) await prefs.setString(_etagKey, newEtag);
      }
    } catch (_) {/* offline or bad file: use cache/bundled */}

    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      try {
        return _parse(cached);
      } catch (_) {}
    }
    return _parse(await rootBundle.loadString('assets/providers.json'));
  }

  List<ProviderDef> _parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (j['providers'] as List)
        .map((p) => ProviderDef.fromJson(p as Map<String, dynamic>))
        .toList();
  }
}

/// Live model sync for gateway mode: ask OmniRoute what it serves now.
Future<List<String>> syncGatewayModels(
        OpenAICompatibleClient client, Endpoint gateway) =>
    client.listModels(gateway);
