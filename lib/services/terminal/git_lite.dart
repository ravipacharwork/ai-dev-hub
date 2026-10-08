import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:path/path.dart' as p;

import '../github_service.dart';
import 'terminal_types.dart';

/// `git` for the built-in terminal. No git binary exists on a phone, so this
/// talks to the GitHub REST API instead: clone = zipball, push = one atomic
/// commit through the Git Data API. Works with the token saved in Connectors;
/// the token is never shown to the model.
///
/// Supported: clone status add commit push pull log diff branch checkout
/// reset remote config rev-parse. Not supported: merge/rebase/stash/tags.
class GitLite {
  final GitHubService gh;

  /// Maps a virtual path (relative to the cwd) to a real, allowed path.
  final String Function(String virtualOrRelative) resolve;
  final Directory cwd;
  GitLite(this.gh, this.resolve, this.cwd);

  /// Called after a successful push: owner, repo, branch, head before, head after.
  void Function(String owner, String repo, String branch, String before, String after)? onPush;

  static const _ignoreDirs = {
    '.gitlite', '.git', 'node_modules', 'build', '.dart_tool', '.gradle', '.idea', '__pycache__',
  };
  static const _ignoreExt = ['.apk', '.aab', '.class', '.o'];

  // ---- state -------------------------------------------------------------

  Directory? _findRoot(Directory from) {
    var d = from.absolute;
    while (true) {
      if (File(p.join(d.path, '.gitlite', 'state.json')).existsSync()) return d;
      final parent = d.parent;
      if (parent.path == d.path) return null;
      d = parent;
    }
  }

  Map<String, dynamic> _load(Directory root) =>
      jsonDecode(File(p.join(root.path, '.gitlite', 'state.json')).readAsStringSync())
          as Map<String, dynamic>;

  void _save(Directory root, Map<String, dynamic> s) {
    final f = File(p.join(root.path, '.gitlite', 'state.json'));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(s));
  }

  static String blobSha(List<int> bytes) =>
      sha1.convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes]).toString();

  RepoRef _ref(Map<String, dynamic> s) => RepoRef(s['owner'] as String, s['repo'] as String);

  Map<String, String> _baseline(Map<String, dynamic> s) =>
      Map<String, String>.from(s['files'] as Map);

  Map<String, String> _scan(Directory root, Set<String> tracked) {
    final out = <String, String>{};
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.posix.joinAll(p.split(p.relative(e.path, from: root.path)));
      final inTracked = tracked.contains(rel);
      if (!inTracked) {
        final parts = rel.split('/');
        if (parts.take(parts.length - 1).any(_ignoreDirs.contains)) continue;
        if (_ignoreExt.any(rel.endsWith)) continue;
      }
      out[rel] = blobSha(e.readAsBytesSync());
    }
    return out;
  }

  ({List<String> modified, List<String> added, List<String> deleted}) _changes(
      Directory root, Map<String, dynamic> s) {
    final base = _baseline(s);
    final now = _scan(root, base.keys.toSet());
    final modified = <String>[], added = <String>[], deleted = <String>[];
    now.forEach((path, sha) {
      final b = base[path];
      if (b == null) {
        added.add(path);
      } else if (b != sha) {
        modified.add(path);
      }
    });
    for (final path in base.keys) {
      if (!now.containsKey(path)) deleted.add(path);
    }
    modified.sort();
    added.sort();
    deleted.sort();
    return (modified: modified, added: added, deleted: deleted);
  }

  // ---- zip helpers -------------------------------------------------------

  Map<String, Uint8List> _unzip(Uint8List zip) {
    final arc = ZipDecoder().decodeBytes(zip);
    final out = <String, Uint8List>{};
    for (final f in arc) {
      if (!f.isFile) continue;
      final parts = f.name.split('/');
      if (parts.length < 2) continue; // top-level folder GitHub adds
      final rel = parts.sublist(1).join('/');
      if (rel.isEmpty || rel.split('/').contains('..') || rel.startsWith('/')) continue;
      out[rel] = Uint8List.fromList(List<int>.from(f.content as List));
    }
    return out;
  }

  void _write(Directory root, String rel, Uint8List data) {
    final f = File(p.join(root.path, p.joinAll(rel.split('/'))));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(data, flush: false);
  }

  // ---- entry point -------------------------------------------------------

  Future<CmdResult> run(List<String> a) async {
    if (a.isEmpty || a.first == 'help' || a.first == '--help') return CmdResult.out(_help);
    final cmd = a.first;
    final rest = a.sublist(1);
    try {
      switch (cmd) {
        case '--version':
        case 'version':
          return CmdResult.out('git-lite 1.0 (GitHub API based, no git binary)');
        case 'clone':
          return await _clone(rest);
        case 'config':
        case 'remote':
          return _remote(rest, cmd);
        case 'init':
          return CmdResult.err(
              'git init is not supported. Create the repo first:\n  curl -X POST https://api.github.com/user/repos -d \'{"name":"my-app","private":true,"auto_init":true}\'\nthen: git clone <you>/my-app');
      }
      final root = _findRoot(cwd);
      if (root == null) {
        return CmdResult.err('fatal: not a git-lite repository. Use: git clone owner/repo', 128);
      }
      final s = _load(root);
      switch (cmd) {
        case 'status':
          return _status(root, s);
        case 'add':
          return CmdResult.out('All changes are included automatically. Use: git commit -m "msg"');
        case 'commit':
          return _commit(root, s, rest);
        case 'push':
          return await _push(root, s);
        case 'pull':
          return await _pull(root, s);
        case 'log':
          return await _log(s, rest);
        case 'diff':
          return await _diff(root, s, rest);
        case 'branch':
          return await _branch(root, s, rest);
        case 'checkout':
        case 'switch':
          return await _checkout(root, s, rest);
        case 'reset':
          return await _reset(root, s, rest);
        case 'rev-parse':
          return CmdResult.out(rest.contains('--abbrev-ref') ? '${s['branch']}' : '${s['head']}');
        default:
          return CmdResult.err("git: '$cmd' is not supported in git-lite. Run: git help", 1);
      }
    } on GitHubException catch (e) {
      return CmdResult.err(
          'git: GitHub said ${e.status}: ${e.message}${e.status == 401 || e.status == 403 ? '\nCheck the token in Connectors (needs Contents: read/write).' : ''}',
          128);
    } on DioException catch (e) {
      return CmdResult.err('git: network error: ${e.message ?? e.type.name}', 128);
    }
  }

  static const _help = '''git-lite (works through the GitHub API)
  git clone owner/repo [dir] [-b branch]
  git status | diff [file] | log [-n N]
  git commit -m "msg"      (all changes are included, add is optional)
  git push | pull
  git branch [name] | checkout [-b] name | reset --hard
Not available: merge, rebase, stash, tags.''';

  // ---- commands ----------------------------------------------------------

  (String, String)? _parseRepo(String raw) {
    var v = raw.trim().replaceAll(RegExp(r'\.git$'), '');
    final m = RegExp(r'github\.com[/:]([^/\s]+)/([^/\s]+)').firstMatch(v);
    if (m != null) return (m.group(1)!, m.group(2)!);
    final m2 = RegExp(r'^([\w.\-]+)/([\w.\-]+)$').firstMatch(v);
    return m2 == null ? null : (m2.group(1)!, m2.group(2)!);
  }

  Future<CmdResult> _clone(List<String> a) async {
    String? target, dest, branch;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-b' || a[i] == '--branch') {
        if (i + 1 < a.length) branch = a[++i];
      } else if (a[i].startsWith('-')) {
        continue; // --depth etc. are meaningless here
      } else if (target == null) {
        target = a[i];
      } else {
        dest ??= a[i];
      }
    }
    if (target == null) return CmdResult.err('usage: git clone owner/repo [dir] [-b branch]', 129);
    final parsed = _parseRepo(target);
    if (parsed == null) return CmdResult.err('git: cannot read repo "$target". Use owner/repo.', 128);
    final r = RepoRef(parsed.$1, parsed.$2);
    branch ??= await gh.defaultBranch(r);
    final destDir = Directory(resolve(dest ?? r.repo));
    if (destDir.existsSync() && destDir.listSync().isNotEmpty) {
      return CmdResult.err('git: destination "${dest ?? r.repo}" already exists and is not empty', 128);
    }
    final head = await gh.branchSha(r, branch);
    final files = _unzip(await gh.downloadZipball(r, head));
    destDir.createSync(recursive: true);
    final shas = <String, String>{};
    files.forEach((rel, data) {
      _write(destDir, rel, data);
      shas[rel] = blobSha(data);
    });
    _save(destDir, {
      'owner': r.owner,
      'repo': r.repo,
      'branch': branch,
      'head': head,
      'files': shas,
      'pending': <String>[],
    });
    return CmdResult.out('Cloned ${r.owner}/${r.repo} ($branch @ ${head.substring(0, 7)}) · ${files.length} files\n→ ${p.basename(destDir.path)}/');
  }

  CmdResult _remote(List<String> a, String cmd) {
    if (cmd == 'config') return CmdResult.out('');
    final root = _findRoot(cwd);
    if (root == null) return CmdResult.err('fatal: not a git-lite repository', 128);
    final s = _load(root);
    final url = 'https://github.com/${s['owner']}/${s['repo']}.git';
    return CmdResult.out('origin\t$url (fetch)\norigin\t$url (push)');
  }

  CmdResult _status(Directory root, Map<String, dynamic> s) {
    final c = _changes(root, s);
    final pending = List<String>.from(s['pending'] as List);
    final b = StringBuffer('On branch ${s['branch']} (${s['owner']}/${s['repo']} @ ${(s['head'] as String).substring(0, 7)})\n');
    if (pending.isNotEmpty) b.writeln('${pending.length} commit(s) ready to push.');
    if (c.modified.isEmpty && c.added.isEmpty && c.deleted.isEmpty) {
      b.write(pending.isEmpty ? 'Nothing to commit, working tree clean.' : 'Run: git push');
      return CmdResult.out(b.toString());
    }
    for (final f in c.modified) {
      b.writeln('  modified:  $f');
    }
    for (final f in c.added) {
      b.writeln('  new file:  $f');
    }
    for (final f in c.deleted) {
      b.writeln('  deleted:   $f');
    }
    return CmdResult.out(b.toString().trimRight());
  }

  CmdResult _commit(Directory root, Map<String, dynamic> s, List<String> a) {
    String? msg;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] == '-m' || a[i] == '-am' || a[i] == '-a') && i + 1 < a.length) {
        msg = a[i + 1];
        break;
      }
      if (a[i].startsWith('-m') && a[i].length > 2) msg = a[i].substring(2);
    }
    if (msg == null || msg.trim().isEmpty) return CmdResult.err('git: commit message required: git commit -m "msg"', 1);
    final c = _changes(root, s);
    final n = c.modified.length + c.added.length + c.deleted.length;
    if (n == 0) return CmdResult.err('nothing to commit, working tree clean', 1);
    final pending = List<String>.from(s['pending'] as List)..add(msg.trim());
    s['pending'] = pending;
    _save(root, s);
    return CmdResult.out('[${s['branch']}] $msg\n $n file(s) changed. Run: git push');
  }

  Future<CmdResult> _push(Directory root, Map<String, dynamic> s) async {
    final r = _ref(s);
    final branch = s['branch'] as String;
    final c = _changes(root, s);
    final n = c.modified.length + c.added.length + c.deleted.length;
    final pending = List<String>.from(s['pending'] as List);
    if (n == 0) return CmdResult.out('Everything up-to-date');
    if (pending.isEmpty) {
      return CmdResult.err('You have $n uncommitted change(s). Run: git commit -m "msg" first.', 1);
    }
    final remote = await gh.branchSha(r, branch);
    if (remote != s['head']) {
      return CmdResult.err('rejected: remote $branch has new commits. Run: git pull first.', 1);
    }
    final files = <FileToCommit>[
      for (final f in [...c.modified, ...c.added])
        FileToCommit.writeBytes(f, File(p.join(root.path, p.joinAll(f.split('/')))).readAsBytesSync()),
      for (final f in c.deleted) FileToCommit.remove(f),
    ];
    final message = pending.length == 1 ? pending.first : '${pending.first}\n\n${pending.skip(1).join('\n')}';
    final sha = await gh.commitFiles(r, branch: branch, message: message, files: files);
    final base = _baseline(s);
    for (final f in c.deleted) {
      base.remove(f);
    }
    for (final f in [...c.modified, ...c.added]) {
      base[f] = blobSha(File(p.join(root.path, p.joinAll(f.split('/')))).readAsBytesSync());
    }
    s['files'] = base;
    s['head'] = sha;
    s['pending'] = <String>[];
    _save(root, s);
    onPush?.call(r.owner, r.repo, branch, remote, sha);
    return CmdResult.out('To github.com/${r.owner}/${r.repo}\n   ${(remote).substring(0, 7)}..${sha.substring(0, 7)}  $branch -> $branch · $n file(s)');
  }

  Future<CmdResult> _pull(Directory root, Map<String, dynamic> s) async {
    final r = _ref(s);
    final branch = s['branch'] as String;
    final remote = await gh.branchSha(r, branch);
    if (remote == s['head']) return CmdResult.out('Already up to date.');
    final theirs = _unzip(await gh.downloadZipball(r, remote));
    final base = _baseline(s);
    final local = _scan(root, base.keys.toSet());
    final newBase = <String, String>{};
    final conflicts = <String>[];
    var updated = 0;
    theirs.forEach((rel, data) {
      final rSha = blobSha(data), b = base[rel], l = local[rel];
      if (rSha == b) {
        newBase[rel] = rSha;
      } else if (l == b || l == rSha) {
        if (l != rSha) {
          _write(root, rel, data);
          updated++;
        }
        newBase[rel] = rSha;
      } else {
        conflicts.add(rel);
        if (b != null) newBase[rel] = b;
      }
    });
    for (final rel in base.keys) {
      if (theirs.containsKey(rel)) continue;
      if (local[rel] == base[rel]) {
        final f = File(p.join(root.path, p.joinAll(rel.split('/'))));
        if (f.existsSync()) f.deleteSync();
        updated++;
      } else if (local[rel] != null) {
        conflicts.add(rel);
        newBase[rel] = base[rel]!;
      }
    }
    s['files'] = newBase;
    s['head'] = remote;
    _save(root, s);
    final b = StringBuffer('Updated to ${remote.substring(0, 7)} · $updated file(s) changed');
    if (conflicts.isNotEmpty) {
      b.write('\nKept your version of ${conflicts.length} file(s) changed on both sides (fix, commit, push to overwrite remote):\n  ${conflicts.join('\n  ')}');
    }
    return CmdResult.out(b.toString());
  }

  Future<CmdResult> _log(Map<String, dynamic> s, List<String> a) async {
    var n = 10;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-n' && i + 1 < a.length) n = int.tryParse(a[i + 1]) ?? 10;
      final m = RegExp(r'^-(\d+)$').firstMatch(a[i]);
      if (m != null) n = int.parse(m.group(1)!);
    }
    final list = await gh.listCommits(_ref(s), s['branch'] as String, perPage: n.clamp(1, 50));
    return CmdResult.out(list
        .map((c) => '${c.$1.substring(0, 7)}  ${c.$4.split('T').first}  ${c.$3}  ${c.$2}')
        .join('\n'));
  }

  Future<CmdResult> _diff(Directory root, Map<String, dynamic> s, List<String> a) async {
    final c = _changes(root, s);
    final want = a.where((x) => !x.startsWith('-')).map((x) => p.posix.normalize(x)).toSet();
    final out = StringBuffer();
    final r = _ref(s);
    for (final f in [...c.modified, ...c.added, ...c.deleted]) {
      if (want.isNotEmpty && !want.any((w) => f == w || f.endsWith('/$w'))) continue;
      final isNew = c.added.contains(f), isDel = c.deleted.contains(f);
      out.writeln('--- ${isNew ? '/dev/null' : 'a/$f'}\n+++ ${isDel ? '/dev/null' : 'b/$f'}');
      final file = File(p.join(root.path, p.joinAll(f.split('/'))));
      List<String> oldL = [], newL = [];
      try {
        if (!isNew) {
          oldL = const LineSplitter().convert(utf8.decode(await gh.readBytes(r, f, s['head'] as String)));
        }
        if (!isDel) newL = const LineSplitter().convert(utf8.decode(file.readAsBytesSync()));
      } on FormatException {
        out.writeln('(binary file differs)');
        continue;
      }
      out.writeln(_unified(oldL, newL));
      if (out.length > 30000) {
        out.writeln('[... diff truncated ...]');
        break;
      }
    }
    final t = out.toString().trimRight();
    return CmdResult.out(t.isEmpty ? '(no changes)' : t);
  }

  /// Small LCS line diff with 2 lines of context.
  String _unified(List<String> a, List<String> b) {
    if (a.length * b.length > 2500000) {
      return '(file too large to diff line by line: ${a.length} -> ${b.length} lines)';
    }
    final n = a.length, m = b.length;
    final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    final ops = <(String, String)>[];
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        ops.add((' ', a[i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        ops.add(('-', a[i++]));
      } else {
        ops.add(('+', b[j++]));
      }
    }
    while (i < n) {
      ops.add(('-', a[i++]));
    }
    while (j < m) {
      ops.add(('+', b[j++]));
    }
    final keep = List<bool>.filled(ops.length, false);
    for (var k = 0; k < ops.length; k++) {
      if (ops[k].$1 == ' ') continue;
      for (var d = -2; d <= 2; d++) {
        if (k + d >= 0 && k + d < ops.length) keep[k + d] = true;
      }
    }
    final b2 = StringBuffer();
    var skipped = false;
    for (var k = 0; k < ops.length; k++) {
      if (!keep[k]) {
        skipped = true;
        continue;
      }
      if (skipped && b2.isNotEmpty) b2.writeln('@@ ...');
      skipped = false;
      b2.writeln('${ops[k].$1}${ops[k].$2}');
    }
    return b2.toString().trimRight();
  }

  Future<CmdResult> _branch(Directory root, Map<String, dynamic> s, List<String> a) async {
    final names = a.where((x) => !x.startsWith('-')).toList();
    if (names.isEmpty) return CmdResult.out('* ${s['branch']}');
    await gh.createBranch(_ref(s), names.first, s['head'] as String);
    return CmdResult.out('Created branch ${names.first} on GitHub (from ${(s['head'] as String).substring(0, 7)})');
  }

  Future<CmdResult> _checkout(Directory root, Map<String, dynamic> s, List<String> a) async {
    final create = a.contains('-b') || a.contains('-c');
    final names = a.where((x) => !x.startsWith('-')).toList();
    if (names.isEmpty) return CmdResult.err('usage: git checkout [-b] <branch>', 129);
    final name = names.first;
    final r = _ref(s);
    if (create) {
      await gh.createBranch(r, name, s['head'] as String);
      s['branch'] = name;
      _save(root, s);
      return CmdResult.out("Switched to a new branch '$name'");
    }
    final c = _changes(root, s);
    if (c.modified.isNotEmpty || c.added.isNotEmpty || c.deleted.isNotEmpty) {
      return CmdResult.err('error: you have local changes. Commit+push them or run: git reset --hard', 1);
    }
    final head = await gh.branchSha(r, name);
    final theirs = _unzip(await gh.downloadZipball(r, head));
    final base = _baseline(s);
    for (final rel in base.keys) {
      if (!theirs.containsKey(rel)) {
        final f = File(p.join(root.path, p.joinAll(rel.split('/'))));
        if (f.existsSync()) f.deleteSync();
      }
    }
    final shas = <String, String>{};
    theirs.forEach((rel, data) {
      _write(root, rel, data);
      shas[rel] = blobSha(data);
    });
    s['branch'] = name;
    s['head'] = head;
    s['files'] = shas;
    s['pending'] = <String>[];
    _save(root, s);
    return CmdResult.out("Switched to branch '$name' @ ${head.substring(0, 7)}");
  }

  Future<CmdResult> _reset(Directory root, Map<String, dynamic> s, List<String> a) async {
    if (!a.contains('--hard')) return CmdResult.err('only "git reset --hard" is supported', 1);
    final r = _ref(s);
    final theirs = _unzip(await gh.downloadZipball(r, s['head'] as String));
    var n = 0;
    final base = _baseline(s);
    final local = _scan(root, base.keys.toSet());
    theirs.forEach((rel, data) {
      if (local[rel] != blobSha(data)) {
        _write(root, rel, data);
        n++;
      }
    });
    for (final rel in local.keys) {
      if (!base.containsKey(rel)) {
        File(p.join(root.path, p.joinAll(rel.split('/')))).deleteSync();
        n++;
      }
    }
    s['pending'] = <String>[];
    _save(root, s);
    return CmdResult.out('HEAD is now at ${(s['head'] as String).substring(0, 7)} · $n file(s) restored');
  }
}
