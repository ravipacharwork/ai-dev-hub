import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'github_service.dart';
import 'skill_store.dart';

/// A skill file found in a GitHub repo (not yet imported).
class RemoteSkill {
  final String repo; // owner/name
  final String path;
  final String sha; // blob sha: changes whenever the file changes
  String name, description;
  RemoteSkill(this.repo, this.path, this.sha, this.name, this.description);

  String get key => '$repo/$path';
  RepoRef get ref {
    final p = repo.split('/');
    return RepoRef(p[0], p[1]);
  }
}

enum SkillStatus { notAdded, added, updateAvailable }

/// Finds skills in GitHub repos (SKILL.md files, or *.md directly in a top-level
/// skills/ folder), keeps the list in sync, and imports them into [SkillStore].
///
/// Sync = one tree request per repo; only files whose blob sha is new/changed
/// are downloaded to read their name/description (cached by sha). New skills
/// pushed to the repo later therefore show up on the next sync.
class SkillHub extends ChangeNotifier {
  static const _srcKey = 'skill_sources_v1';
  static const _cacheKey = 'skill_meta_cache_v1';
  static const maxInstructionChars = 16000;
  static const _perRepoCap = 200;

  final GitHubService? Function() gh;
  final ({RepoRef repo, String branch})? Function() connected;
  final SkillStore store;

  SkillHub({required this.gh, required this.connected, required this.store});

  late SharedPreferences _p;
  List<String> extraRepos = []; // "owner/name" or "owner/name@branch"
  List<RemoteSkill> items = [];
  List<RemoteSkill>? searchResults;
  bool syncing = false, searching = false;
  String? error;
  DateTime? lastSync;
  final Map<String, ({String name, String description})> _meta = {};

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    extraRepos = _p.getStringList(_srcKey) ?? [];
    try {
      final raw = _p.getString(_cacheKey);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) =>
            _meta[k as String] = (name: '${v['n']}', description: '${v['d']}'));
      }
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    if (_meta.length > 1000) {
      final keep = _meta.keys.toList().sublist(_meta.length - 800);
      _meta.removeWhere((k, _) => !keep.contains(k));
    }
    await _p.setString(_cacheKey,
        jsonEncode({for (final e in _meta.entries) e.key: {'n': e.value.name, 'd': e.value.description}}));
  }

  // ---- sources --------------------------------------------------------------

  static final _repoRe = RegExp(r'^[\w.-]+/[\w.-]+(@[\w./-]+)?$');
  static bool looksLikeRepo(String s) => _repoRe.hasMatch(s.trim());

  Future<void> addRepo(String input) async {
    final v = input.trim().replaceAll(RegExp(r'^https?://github\.com/'), '').replaceAll(RegExp(r'(\.git)?/?$'), '');
    if (!looksLikeRepo(v)) throw const FormatException('Use owner/repo');
    if (!extraRepos.contains(v)) extraRepos.add(v);
    await _p.setStringList(_srcKey, extraRepos);
    notifyListeners();
    unawaited(syncAll(force: true));
  }

  Future<void> removeRepo(String v) async {
    extraRepos.remove(v);
    items.removeWhere((i) => v.split('@').first == i.repo);
    await _p.setStringList(_srcKey, extraRepos);
    notifyListeners();
  }

  /// Every repo that is listed: the connected one first, then the added ones.
  List<({String repo, String? branch})> get sources {
    final out = <({String repo, String? branch})>[];
    final c = connected();
    if (c != null) out.add((repo: '${c.repo.owner}/${c.repo.repo}', branch: c.branch));
    for (final e in extraRepos) {
      final parts = e.split('@');
      if (out.any((o) => o.repo == parts[0])) continue;
      out.add((repo: parts[0], branch: parts.length > 1 ? parts.sublist(1).join('@') : null));
    }
    return out;
  }

  // ---- sync -----------------------------------------------------------------

  static bool isSkillPath(String path) {
    final parts = path.split('/');
    final base = parts.last.toLowerCase();
    if (parts.any((s) => s == 'node_modules' || s == '.git')) return false;
    if (base == 'skill.md') return true;
    return parts.length == 2 &&
        parts.first.toLowerCase() == 'skills' &&
        base.endsWith('.md') &&
        base != 'readme.md';
  }

  /// Lists skills in all sources. Safe to call often; [force] bypasses the 2-minute throttle.
  Future<void> syncAll({bool force = false}) async {
    final g = gh();
    if (g == null || syncing) return;
    final last = lastSync;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
    syncing = true;
    error = null;
    notifyListeners();

    final all = <RemoteSkill>[];
    final problems = <String>[];
    for (final s in sources) {
      try {
        final r = RepoRef(s.repo.split('/')[0], s.repo.split('/')[1]);
        final branch = s.branch ?? await g.defaultBranch(r);
        final tree = await g.getTree(r, branch);
        var n = 0;
        for (final e in tree) {
          if (e.type != 'blob' || !isSkillPath(e.path)) continue;
          if (n++ >= _perRepoCap) break;
          final m = _meta[e.sha];
          all.add(RemoteSkill(s.repo, e.path, e.sha, m?.name ?? _fallbackName(e.path), m?.description ?? ''));
        }
      } on GitHubException catch (e) {
        problems.add('${s.repo}: ${e.status == 404 ? 'not found or no access' : e.message}');
      } catch (e) {
        problems.add('${s.repo}: $e');
      }
    }
    items = all;
    lastSync = DateTime.now();
    syncing = false;
    error = problems.isEmpty ? null : problems.join('\n');
    notifyListeners();
    unawaited(_fillMeta(items)); // names/descriptions arrive progressively
  }

  static String _fallbackName(String path) {
    final parts = path.split('/');
    if (parts.last.toLowerCase() == 'skill.md') return parts.length > 1 ? parts[parts.length - 2] : 'skill';
    return parts.last.replaceAll(RegExp(r'\.md$', caseSensitive: false), '');
  }

  Future<void> _fillMeta(List<RemoteSkill> list) async {
    final g = gh();
    if (g == null) return;
    final todo = [for (final s in list) if (!_meta.containsKey(s.sha)) s];
    var i = 0;
    Future<void> worker() async {
      while (i < todo.length) {
        final s = todo[i++];
        try {
          final res = await g.dio.get('/repos/${s.repo}/contents/${Uri.encodeFull(s.path)}');
          if (res.statusCode != 200) continue;
          final text = utf8.decode(base64.decode(((res.data as Map)['content'] as String).replaceAll('\n', '')),
              allowMalformed: true);
          final p = parseSkillMd(text, _fallbackName(s.path));
          _meta[s.sha] = (name: p.name, description: p.description);
          s.name = p.name;
          s.description = p.description;
          notifyListeners();
        } catch (_) {}
      }
    }

    await Future.wait([for (var k = 0; k < 6; k++) worker()]);
    await _saveCache();
  }

  // ---- search ---------------------------------------------------------------

  /// GitHub code search for SKILL.md files. Requires the token; GitHub limits
  /// code search to about 10 requests per minute.
  Future<void> search(String query) async {
    final g = gh();
    final q = query.trim();
    if (g == null) return;
    if (q.isEmpty) {
      searchResults = null;
      notifyListeners();
      return;
    }
    searching = true;
    error = null;
    notifyListeners();
    try {
      final res = await g.dio.get('/search/code',
          queryParameters: {'q': 'filename:SKILL.md $q', 'per_page': 30});
      if (res.statusCode != 200) {
        final msg = res.data is Map ? '${res.data['message']}' : '${res.data}';
        throw GitHubException(
            res.statusCode == 403 || res.statusCode == 429
                ? 'GitHub search rate limit reached. Wait a minute and try again.'
                : msg,
            res.statusCode);
      }
      final out = <RemoteSkill>[];
      for (final it in (res.data['items'] as List)) {
        final repo = (it['repository'] as Map)['full_name'] as String;
        final path = it['path'] as String;
        final sha = it['sha'] as String;
        final m = _meta[sha];
        out.add(RemoteSkill(repo, path, sha, m?.name ?? _fallbackName(path), m?.description ?? ''));
      }
      searchResults = out;
      searching = false;
      notifyListeners();
      unawaited(_fillMeta(out));
    } on GitHubException catch (e) {
      searching = false;
      error = e.message;
      notifyListeners();
    } catch (e) {
      searching = false;
      error = 'Search failed: $e';
      notifyListeners();
    }
  }

  void clearSearch() {
    searchResults = null;
    notifyListeners();
  }

  // ---- import ---------------------------------------------------------------

  SkillStatus statusOf(RemoteSkill r) {
    final s = store.findBySource(r.repo, r.path);
    if (s == null) return SkillStatus.notAdded;
    return s.sourceSha == r.sha ? SkillStatus.added : SkillStatus.updateAvailable;
  }

  int get updatesAvailable => items.where((i) => statusOf(i) == SkillStatus.updateAvailable).length;

  /// Downloads the current file text (always fresh, not the cached copy).
  Future<({String name, String description, String body, String sha, bool truncated})> fetch(RemoteSkill r) async {
    final g = gh();
    if (g == null) throw GitHubException('GitHub is not connected.');
    final res = await g.dio.get('/repos/${r.repo}/contents/${Uri.encodeFull(r.path)}');
    if (res.statusCode != 200) {
      throw GitHubException(res.data is Map ? '${res.data['message']}' : 'download failed', res.statusCode);
    }
    final j = res.data as Map;
    final text = utf8.decode(base64.decode((j['content'] as String).replaceAll('\n', '')), allowMalformed: true);
    final p = parseSkillMd(text, _fallbackName(r.path));
    var body = p.body;
    final truncated = body.length > maxInstructionChars;
    if (truncated) body = body.substring(0, maxInstructionChars);
    return (name: p.name, description: p.description, body: body, sha: j['sha'] as String, truncated: truncated);
  }

  /// One-tap add (or update). Returns true if the text had to be shortened.
  Future<bool> add(RemoteSkill r) async {
    final f = await fetch(r);
    await store.importRemote(repo: r.repo, path: r.path, sha: f.sha, name: f.name, instructions: f.body);
    return f.truncated;
  }

  // ---- SKILL.md parsing -----------------------------------------------------

  static ({String name, String description, String body}) parseSkillMd(String text, String fallbackName) {
    var t = text.replaceAll('\r\n', '\n');
    var name = fallbackName, desc = '';
    if (t.startsWith('---\n')) {
      final end = t.indexOf('\n---', 4);
      if (end != -1) {
        final fm = t.substring(4, end).split('\n');
        t = t.substring(end + 4).replaceFirst(RegExp(r'^\s*\n'), '');
        String? key;
        final buf = <String, StringBuffer>{};
        for (final line in fm) {
          final m = RegExp(r'^([A-Za-z_-]+):\s*(.*)$').firstMatch(line);
          if (m != null && !line.startsWith(' ')) {
            key = m.group(1)!.toLowerCase();
            var v = m.group(2)!.trim();
            if (v == '>' || v == '|' || v == '>-' || v == '|-') v = '';
            buf[key] = StringBuffer(v);
          } else if (key != null && line.trim().isNotEmpty) {
            buf[key]!..write(' ')..write(line.trim());
          }
        }
        String clean(String? v) {
          var s = (v ?? '').trim();
          if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
            s = s.substring(1, s.length - 1);
          }
          return s.trim();
        }

        final n = clean(buf['name']?.toString());
        if (n.isNotEmpty) name = n;
        desc = clean(buf['description']?.toString());
      }
    }
    if (desc.isEmpty) {
      for (final l in t.split('\n')) {
        final s = l.trim();
        if (s.isNotEmpty && !s.startsWith('#')) {
          desc = s.length > 200 ? '${s.substring(0, 200)}…' : s;
          break;
        }
      }
    }
    if (desc.length > 300) desc = '${desc.substring(0, 300)}…';
    return (name: name, description: desc, body: t.trim());
  }
}
