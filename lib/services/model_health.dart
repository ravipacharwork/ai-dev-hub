import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'openai_compatible_client.dart';

enum ModelState { unknown, checking, ok, failed }

class _Result {
  final bool ok;
  final int latencyMs;
  final String? error;
  final DateTime at;
  _Result(this.ok, this.latencyMs, this.error) : at = DateTime.now();
}

/// Proves a model can actually run: sends a tiny real request through the same
/// path chat uses (gateway included) and caches the outcome. The model picker
/// only offers models that passed.
class ModelHealth extends ChangeNotifier {
  final OpenAICompatibleClient client;
  ModelHealth(this.client);

  static const _okTtl = Duration(minutes: 10);
  static const _failTtl = Duration(minutes: 2);
  static const _concurrency = 3;

  final Map<String, _Result> _res = {};
  final Set<String> _inFlight = {};
  final List<Endpoint> _queue = [];
  int _workers = 0;

  _Result? _fresh(String id) {
    final r = _res[id];
    if (r == null) return null;
    final ttl = r.ok ? _okTtl : _failTtl;
    return DateTime.now().difference(r.at) < ttl ? r : null;
  }

  ModelState stateOf(Endpoint e) {
    if (_inFlight.contains(e.id)) return ModelState.checking;
    final r = _fresh(e.id);
    if (r == null) return ModelState.unknown;
    return r.ok ? ModelState.ok : ModelState.failed;
  }

  int? latencyOf(Endpoint e) => _fresh(e.id)?.latencyMs;
  String? errorOf(Endpoint e) => _fresh(e.id)?.error;

  /// Models still waiting for or undergoing a check.
  int get pending => _queue.length + _inFlight.length;

  /// Queue every endpoint that has no fresh result. [force] re-checks all.
  void check(Iterable<Endpoint> eps, {bool force = false}) {
    for (final e in eps) {
      if (_inFlight.contains(e.id) || _queue.any((q) => q.id == e.id)) continue;
      if (!force && _fresh(e.id) != null) continue;
      _queue.add(e);
    }
    while (_workers < _concurrency && _queue.isNotEmpty) {
      _workers++;
      unawaited(_work());
    }
    notifyListeners();
  }

  void clear() {
    _res.clear();
    notifyListeners();
  }

  Future<void> _work() async {
    while (_queue.isNotEmpty) {
      final e = _queue.removeAt(0);
      _inFlight.add(e.id);
      notifyListeners();
      _res[e.id] = await _probe(e);
      _inFlight.remove(e.id);
      notifyListeners();
    }
    _workers--;
  }

  Future<_Result> _probe(Endpoint e) async {
    final sw = Stopwatch()..start();
    final cancel = CancelToken();
    final req = ChatRequest(
      model: e.model,
      messages: const [
        {'role': 'user', 'content': 'Reply with: ok'}
      ],
      maxTokens: 8,
    );
    try {
      await client
          .streamRaw(e, req, cancel: cancel)
          .firstWhere((p) => p != '[DONE]')
          .timeout(const Duration(seconds: 20));
      return _Result(true, sw.elapsedMilliseconds, null);
    } on TimeoutException {
      return _Result(false, 0, 'timed out');
    } on StateError {
      return _Result(false, 0, 'empty response');
    } catch (err) {
      final m = err is LlmError ? err.message : '$err';
      return _Result(false, 0, m.length > 120 ? '${m.substring(0, 120)}...' : m);
    } finally {
      cancel.cancel(); // stop reading as soon as the first token arrived
    }
  }
}
