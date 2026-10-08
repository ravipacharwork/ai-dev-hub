import 'dart:async';

import '../build_poller.dart';
import '../deliverables.dart';
import '../github_service.dart';
import 'plan.dart';

/// Shown to the user before an action that leaves the device.
class ApprovalRequest {
  final String title, detail;
  const ApprovalRequest(this.title, this.detail);
}

class ToolResult {
  final String content;
  final bool ok;
  final Stream<BuildStatus>? build; // set by trigger_build / commit_changes
  final List<Deliverable> deliverables; // files handed to the user in chat
  final PlanSnapshot? plan; // set by update_plan
  final String? checkpoint; // undo point taken before this step
  /// For slow tools: the runner shows [build]/[deliverables] first, then awaits
  /// this and uses ITS result as the tool output (e.g. wait for the CI result).
  final Future<ToolResult> Function()? settle;
  const ToolResult(this.content,
      {this.ok = true,
      this.build,
      this.deliverables = const [],
      this.plan,
      this.checkpoint,
      this.settle});

  ToolResult withCheckpoint(String id) => ToolResult(content,
      ok: ok,
      build: build,
      deliverables: deliverables,
      plan: plan,
      checkpoint: id,
      settle: settle);
}

/// A restore point: taken before every step that changes the repo.
class Checkpoint {
  final String id, label;
  final DateTime at;
  final Map<String, String?> staged; // copy of the staged changes
  final String? headSha; // branch head when taken
  Checkpoint(this.id, this.label, this.at, this.staged, this.headSha);
}

/// The repo the agent works on, plus changes staged on the device.
/// Staged changes live in memory: they are lost if the app is killed.
class AgentWorkspace {
  static const maxFixAttempts = 3;
  static const _memoryCap = 8000;

  final GitHubService gh;
  final RepoRef repo;
  final String branch, workflowFile;
  final BuildPoller poller;

  /// path -> new text, or null meaning "delete this file".
  final Map<String, String?> staged = {};
  List<TreeEntry>? tree; // cached; cleared after a commit

  /// Consecutive failed builds in the auto-fix loop (reset on success / new run).
  int failedBuilds = 0;

  // ---- undo -----------------------------------------------------------------
  final List<Checkpoint> checkpoints = [];
  String? headSha; // last head we know of (ours)
  int _cpSeq = 0;

  AgentWorkspace(this.gh, this.repo, this.branch, this.workflowFile)
      : poller = BuildPoller(gh);

  String get slug => '${repo.owner}/${repo.repo}@$branch';

  /// Current text of a file: staged version if any, else from GitHub.
  /// Null when the file is staged for deletion.
  Future<String?> currentText(String path) async {
    if (staged.containsKey(path)) return staged[path];
    return (await gh.readFile(repo, path, branch)).$1;
  }

  /// Called at the start of every agent run. Resets the fix-loop counter and
  /// returns the project-memory block for the system prompt (AGENTS.md).
  Future<String> beginRun() async {
    failedBuilds = 0;
    String? text;
    try {
      text = await currentText('AGENTS.md');
    } on GitHubException catch (e) {
      if (e.status != 404) return '';
    } catch (_) {
      return '';
    }
    if (text == null || text.trim().isEmpty) {
      return 'PROJECT MEMORY: this repo has no AGENTS.md yet. After your first meaningful piece of work, create it with write_file: a short file with Overview, Stack, Build & test commands, Conventions and Gotchas. Later sessions read it automatically.';
    }
    final body = text.length > _memoryCap ? '${text.substring(0, _memoryCap)}\n[truncated]' : text;
    return 'PROJECT MEMORY (AGENTS.md from the repo; follow it, it overrides your defaults; use the remember tool to add lasting lessons):\n$body';
  }

  Future<String> checkpoint(String label, {bool refreshHead = false}) async {
    if (headSha == null || refreshHead) {
      try {
        headSha = await gh.branchSha(repo, branch);
      } catch (_) {/* undo of commits is then unavailable for this point */}
    }
    final c = Checkpoint('cp${++_cpSeq}', label, DateTime.now(), Map.of(staged), headSha);
    checkpoints.add(c);
    if (checkpoints.length > 60) checkpoints.removeAt(0);
    return c.id;
  }

  void dropCheckpoint(String id) => checkpoints.removeWhere((c) => c.id == id);

  Checkpoint? checkpointById(String id) {
    for (final c in checkpoints) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// True when going back to [id] also has to move the branch on GitHub.
  bool undoTouchesRemote(String id) {
    final c = checkpointById(id);
    return c != null && c.headSha != null && headSha != null && c.headSha != headSha;
  }

  /// Restores the repo state from before checkpoint [id] (and everything after).
  /// Returns a short message for the user.
  Future<String> restore(String id) async {
    final i = checkpoints.indexWhere((c) => c.id == id);
    if (i < 0) return 'That restore point is no longer available.';
    final c = checkpoints[i];
    var msg = 'Went back to before: ${c.label}.';
    if (c.headSha != null && headSha != null && c.headSha != headSha) {
      final remote = await gh.branchSha(repo, branch);
      if (remote != headSha) {
        return 'Cannot undo: $branch changed outside this chat (someone else pushed). Nothing was changed.';
      }
      await gh.resetBranch(repo, branch, c.headSha!);
      headSha = c.headSha;
      tree = null;
      msg = '$msg Branch moved back to ${c.headSha!.substring(0, 7)} on GitHub.';
    }
    staged
      ..clear()
      ..addAll(c.staged);
    checkpoints.removeRange(i, checkpoints.length);
    return msg;
  }
}

/// What the agent loop needs from a set of tools.
abstract class Toolkit {
  List<Map<String, dynamic>> get schemas;
  String get systemNote;
  String label(String name, Map<String, dynamic> args);
  ApprovalRequest? approval(String name, Map<String, dynamic> args);
  Future<ToolResult> run(String name, Map<String, dynamic> args);
}

/// Several toolkits behind one interface (GitHub repo tools + device files).
class ToolkitSet implements Toolkit {
  final List<Toolkit> kits;
  final Map<String, Toolkit> _owner = {};
  ToolkitSet(this.kits) {
    for (final k in kits) {
      for (final s in k.schemas) {
        _owner[(s['function'] as Map)['name'] as String] = k;
      }
    }
  }
  @override
  List<Map<String, dynamic>> get schemas => [for (final k in kits) ...k.schemas];
  @override
  String get systemNote => kits.map((k) => k.systemNote).join('\n\n');
  @override
  String label(String n, Map<String, dynamic> a) => _owner[n]?.label(n, a) ?? n;
  @override
  ApprovalRequest? approval(String n, Map<String, dynamic> a) => _owner[n]?.approval(n, a);
  @override
  Future<ToolResult> run(String n, Map<String, dynamic> a) async =>
      _owner[n]?.run(n, a) ?? ToolResult('Unknown tool "$n".', ok: false);
}

/// Tool schemas (OpenAI function-calling format) + their implementations.
class AgentToolkit implements Toolkit {
  static const maxFileChars = 200 * 1024;
  static const _readCap = 12000;

  final AgentWorkspace ws;
  final bool Function() autoVerify; // commit_changes also builds and waits
  AgentToolkit(this.ws, {this.autoVerify = _yes});
  static bool _yes() => true;

  // ---- schemas --------------------------------------------------------------

  static Map<String, dynamic> _p(String description, [String type = 'string']) =>
      {'type': type, 'description': description};

  static Map<String, dynamic> _fn(
          String name, String description, Map<String, dynamic> props,
          [List<String> required = const []]) =>
      {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': {
            'type': 'object',
            'properties': props,
            if (required.isNotEmpty) 'required': required,
          },
        },
      };

  List<Map<String, dynamic>> get schemas => [
        _fn(
            'list_files',
            'List files in the repo, including staged changes. Optionally only paths starting with a prefix.',
            {'prefix': _p('Path prefix, e.g. "lib/"')}),
        _fn(
            'read_file',
            'Read a text file (the staged version if it was changed). Large files are truncated; use start_line/end_line.',
            {
              'path': _p('Repo-relative path'),
              'start_line': _p('1-based first line', 'integer'),
              'end_line': _p('1-based last line', 'integer'),
            },
            ['path']),
        _fn(
            'write_file',
            'Stage a new file or a full rewrite of a file. Does not commit.',
            {'path': _p('Repo-relative path'), 'content': _p('Complete file text')},
            ['path', 'content']),
        _fn(
            'replace_in_file',
            'Stage a small edit: replace old_str with new_str. old_str must match exactly once. Does not commit.',
            {
              'path': _p('Repo-relative path'),
              'old_str': _p('Exact text to replace (include enough context to be unique)'),
              'new_str': _p('Replacement text'),
            },
            ['path', 'old_str', 'new_str']),
        _fn('delete_file', 'Stage the deletion of a file. Does not commit.',
            {'path': _p('Repo-relative path')}, ['path']),
        _fn('list_changes', 'Show the changes staged so far.', {}),
        _fn('discard_changes', 'Drop all staged changes.', {}),
        _fn(
            'commit_changes',
            'Commit and push all staged changes in one commit. The user must approve. By default it then builds on GitHub Actions and returns the build result (with the error log if it failed), so you can fix and commit again.',
            {
              'message': _p('Commit message'),
              'verify': _p('Set false to skip the automatic build check', 'boolean'),
            },
            ['message']),
        _fn(
            'trigger_build',
            'Start the GitHub Actions build for the committed code and WAIT for the result (up to ~15 min). Returns success, or the failed step with the build log. The user must approve.',
            {}),
        _fn(
            'get_build_logs',
            'Read the result and error log of the most recent finished build on this branch (for example after a push made from the terminal).',
            {}),
        _fn(
            'remember',
            'Stage a lasting note in AGENTS.md (project memory read at the start of every session): build commands, conventions, gotchas, decisions. One short line per call. Gets committed with the next commit.',
            {'note': _p('One concise fact worth remembering')},
            ['note']),
      ];

  String get systemNote => '''You can work on the user's GitHub repository ${ws.slug} with tools.
- Explore with list_files and read_file before editing; read_file accepts start_line/end_line for large files.
- Prefer replace_in_file for small edits (old_str must match exactly once). Use write_file for new files or full rewrites.
- write_file, replace_in_file and delete_file only STAGE changes on the device. Nothing reaches GitHub until commit_changes, which the user must approve.
- VERIFY LOOP: commit_changes (unless verify=false) builds on GitHub Actions and waits. If the result is BUILD FAILED, read the log, find the root cause, fix it with replace_in_file/write_file and call commit_changes again. Give up after ${AgentWorkspace.maxFixAttempts} failed attempts and explain the error to the user instead of guessing. After a push made from the terminal, use trigger_build or get_build_logs to check the result.
- Every file change is saved as an undo point the user can restore with one tap.
- If the user denies an action, do not retry it; ask what they want instead.
- Be economical: do not re-read files you already have, and keep tool calls to what the task needs.''';

  String label(String name, Map<String, dynamic> a) {
    final path = a['path'];
    if (path is String) return '$name  $path';
    final extra = name == 'commit_changes' ? a['message'] : (name == 'remember' ? a['note'] : null);
    if (extra is String && extra.trim().isNotEmpty) {
      final one = extra.replaceAll('\n', ' ').trim();
      return '$name  ${one.length > 60 ? '${one.substring(0, 60)}...' : one}';
    }
    return name;
  }

  // ---- approval -------------------------------------------------------------

  /// Non-null for actions that must be confirmed. Returns null when there is
  /// nothing to confirm (read-only tools, or a no-op the tool will reject).
  ApprovalRequest? approval(String name, Map<String, dynamic> a) {
    switch (name) {
      case 'commit_changes':
        if (ws.staged.isEmpty) return null;
        final msg = (_s(a, 'message') ?? '').trim();
        final b = StringBuffer('Message: ${msg.isEmpty ? 'Update via AI Dev Hub' : msg}\n\n');
        var budget = 60; // preview lines across all files
        for (final e in ws.staged.entries) {
          final text = e.value;
          if (text == null) {
            b.writeln('DELETE ${e.key}');
            continue;
          }
          final lines = text.split('\n');
          b.writeln('WRITE ${e.key} (${lines.length} lines)');
          for (final l in lines.take(6)) {
            if (budget-- <= 0) break;
            b.writeln('  $l');
          }
          if (lines.length > 6) b.writeln('  ...');
        }
        if (autoVerify() && a['verify'] != false) {
          b.writeln('\nThen the app builds on GitHub Actions and the agent fixes errors itself.');
        }
        return ApprovalRequest(
            'Commit ${ws.staged.length} file(s) to ${ws.slug}?', b.toString());
      case 'trigger_build':
        final n = ws.staged.length;
        return ApprovalRequest(
            'Start a build?',
            '${ws.slug}\nworkflow: ${ws.workflowFile}'
            '${n > 0 ? '\n\nWarning: $n staged change(s) are not committed and will not be in this build.' : ''}');
      default:
        return null;
    }
  }

  // ---- execution ------------------------------------------------------------

  static const _mutating = {
    'write_file',
    'replace_in_file',
    'delete_file',
    'discard_changes',
    'commit_changes',
    'remember',
  };

  Future<ToolResult> run(String name, Map<String, dynamic> a) async {
    String? cp;
    if (_mutating.contains(name)) {
      try {
        cp = await ws.checkpoint(label(name, a), refreshHead: name == 'commit_changes');
      } catch (_) {}
    }
    final r = await _dispatch(name, a);
    if (cp == null) return r;
    if (!r.ok) {
      ws.dropCheckpoint(cp);
      return r;
    }
    return r.withCheckpoint(cp);
  }

  Future<ToolResult> _dispatch(String name, Map<String, dynamic> a) async {
    try {
      switch (name) {
        case 'list_files':
          return await _list(_s(a, 'prefix') ?? '');
        case 'read_file':
          return await _read(a);
        case 'write_file':
          return _write(a);
        case 'replace_in_file':
          return await _replace(a);
        case 'delete_file':
          return await _delete(a);
        case 'list_changes':
          return _changes();
        case 'discard_changes':
          ws.staged.clear();
          return const ToolResult('Discarded all staged changes.');
        case 'commit_changes':
          return await _commit(a);
        case 'trigger_build':
          return _build();
        case 'get_build_logs':
          return await _logs();
        case 'remember':
          return await _remember(a);
        default:
          return ToolResult('Unknown tool "$name".', ok: false);
      }
    } on GitHubException catch (e) {
      return ToolResult(
          e.status == 404 ? 'Not found (404): ${e.message}' : 'GitHub error: $e',
          ok: false);
    } catch (e) {
      return ToolResult('Tool failed: $e', ok: false);
    }
  }

  static const _badPath =
      ToolResult('Invalid "path": use a repo-relative file path like lib/main.dart.',
          ok: false);

  static String? _s(Map<String, dynamic> a, String k) {
    final v = a[k];
    return v is String ? v : null;
  }

  static int? _i(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  static int _lines(String s) => s.isEmpty ? 0 : s.split('\n').length;

  static String? _cleanPath(Object? raw) {
    if (raw is! String) return null;
    var p = raw.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    if (p.startsWith('/')) p = p.substring(1);
    if (p.isEmpty || p.endsWith('/')) return null;
    final parts = p.split('/');
    if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) return null;
    if (parts.first == '.git') return null;
    return p;
  }

  /// Current text of a file: staged version if any, else from GitHub.
  /// Returns null when the file is staged for deletion.
  Future<String?> _current(String path) => ws.currentText(path);

  Future<ToolResult> _list(String prefix) async {
    ws.tree ??= await ws.gh.getTree(ws.repo, ws.branch);
    final files = <String, int?>{
      for (final e in ws.tree!)
        if (e.type == 'blob') e.path: e.size,
    };
    for (final e in ws.staged.entries) {
      final text = e.value;
      if (text == null) {
        files.remove(e.key);
      } else {
        files[e.key] = text.length;
      }
    }
    final paths = files.keys.where((p) => p.startsWith(prefix)).toList()..sort();
    if (paths.isEmpty) return ToolResult('No files under "$prefix".');
    const cap = 300;
    final shown = paths.take(cap).map((p) {
      final tag = ws.staged.containsKey(p) ? '  [staged]' : '';
      return '$p$tag';
    });
    final more = paths.length > cap ? ' (showing the first $cap; use a longer prefix)' : '';
    return ToolResult('${paths.length} files$more:\n${shown.join('\n')}');
  }

  Future<ToolResult> _read(Map<String, dynamic> a) async {
    final path = _cleanPath(a['path']);
    if (path == null) return _badPath;
    final text = await _current(path);
    if (text == null) {
      return ToolResult('$path is staged for deletion.', ok: false);
    }
    final lines = text.split('\n');
    final start = (_i(a['start_line']) ?? 1).clamp(1, lines.length).toInt();
    final end = (_i(a['end_line']) ?? lines.length).clamp(start, lines.length).toInt();
    var body = lines.sublist(start - 1, end).join('\n');
    var note = '';
    if (body.length > _readCap) {
      body = body.substring(0, _readCap);
      note = '\n[truncated: request a narrower line range to see the rest]';
    }
    return ToolResult('$path (lines $start-$end of ${lines.length})\n$body$note');
  }

  ToolResult _write(Map<String, dynamic> a) {
    final path = _cleanPath(a['path']);
    if (path == null) return _badPath;
    final content = a['content'];
    if (content is! String) return const ToolResult('Missing "content".', ok: false);
    if (content.length > maxFileChars) {
      return ToolResult('File too large (limit ${maxFileChars ~/ 1024} KB).', ok: false);
    }
    ws.staged[path] = content;
    return ToolResult(
        'Staged $path (${_lines(content)} lines). Nothing is committed yet.');
  }

  Future<ToolResult> _replace(Map<String, dynamic> a) async {
    final path = _cleanPath(a['path']);
    if (path == null) return _badPath;
    final oldS = _s(a, 'old_str'), newS = _s(a, 'new_str');
    if (oldS == null || oldS.isEmpty || newS == null) {
      return const ToolResult('Need non-empty "old_str" and a "new_str".', ok: false);
    }
    final text = await _current(path);
    if (text == null) return ToolResult('$path is staged for deletion.', ok: false);
    final count = oldS.allMatches(text).length;
    if (count == 0) {
      return ToolResult('old_str not found in $path. Re-read the file and match it exactly.',
          ok: false);
    }
    if (count > 1) {
      return ToolResult(
          'old_str matches $count places in $path. Add surrounding context to make it unique.',
          ok: false);
    }
    final updated = text.replaceFirst(oldS, newS);
    if (updated.length > maxFileChars) {
      return ToolResult('Result too large (limit ${maxFileChars ~/ 1024} KB).', ok: false);
    }
    ws.staged[path] = updated;
    return ToolResult('Staged edit to $path. Nothing is committed yet.');
  }

  Future<ToolResult> _delete(Map<String, dynamic> a) async {
    final path = _cleanPath(a['path']);
    if (path == null) return _badPath;
    ws.tree ??= await ws.gh.getTree(ws.repo, ws.branch);
    final inRepo = ws.tree!.any((e) => e.type == 'blob' && e.path == path);
    if (!inRepo) {
      if (ws.staged.remove(path) != null) {
        return ToolResult('Removed staged new file $path.');
      }
      return ToolResult('$path does not exist.', ok: false);
    }
    ws.staged[path] = null;
    return ToolResult('Staged deletion of $path. Nothing is committed yet.');
  }

  ToolResult _changes() {
    if (ws.staged.isEmpty) return const ToolResult('No staged changes.');
    final lines = [
      for (final e in ws.staged.entries)
        e.value == null ? 'delete  ${e.key}' : 'write   ${e.key} (${_lines(e.value!)} lines)',
    ];
    return ToolResult('${ws.staged.length} staged:\n${lines.join('\n')}');
  }

  Future<ToolResult> _commit(Map<String, dynamic> a) async {
    if (ws.staged.isEmpty) return const ToolResult('Nothing staged.', ok: false);
    final msg = (_s(a, 'message') ?? '').trim();
    final files = [
      for (final e in ws.staged.entries)
        e.value == null
            ? FileToCommit.remove(e.key)
            : FileToCommit.write(e.key, e.value!),
    ];
    final sha = await ws.gh.commitFiles(ws.repo,
        branch: ws.branch,
        message: msg.isEmpty ? 'Update via AI Dev Hub' : msg,
        files: files);
    final n = ws.staged.length;
    ws.staged.clear();
    ws.tree = null;
    ws.headSha = sha;
    final done = 'Committed $n file(s) to ${ws.slug} as ${sha.substring(0, 7)}.';
    if (!autoVerify() || a['verify'] == false) return ToolResult(done);
    return _startBuild(prefix: '$done\n');
  }

  ToolResult _build() {
    final n = ws.staged.length;
    final warn = n > 0
        ? 'Note: $n staged change(s) are NOT committed and are not in this build.\n'
        : '';
    return _startBuild(prefix: warn);
  }

  /// Dispatches the workflow, shows the live card, then waits for the result so
  /// the model can read the log and fix the code (the auto-verify loop).
  ToolResult _startBuild({String prefix = ''}) {
    final tracker = BuildTracker.follow(ws.poller.run(ws.repo,
        workflowFile: ws.workflowFile,
        ref: ws.branch,
        correlationId: BuildPoller.newCorrelationId(),
        timeout: const Duration(minutes: 15)));
    return ToolResult(
        '${prefix}Build dispatched for ${ws.slug} (workflow ${ws.workflowFile}).',
        build: tracker.stream,
        settle: () async => _afterBuild(await tracker.finished, prefix));
  }

  ToolResult _afterBuild(BuildStatus fin, String prefix) {
    final b = StringBuffer(prefix)..writeln(fin.summaryForModel);
    final ok = fin.phase == BuildPhase.succeeded;
    if (ok) {
      ws.failedBuilds = 0;
    } else if (fin.phase == BuildPhase.failed) {
      ws.failedBuilds++;
      final left = AgentWorkspace.maxFixAttempts - ws.failedBuilds;
      b.writeln(left > 0
          ? '\nFix the root cause (read the files involved first), then commit_changes again. Attempt ${ws.failedBuilds} of ${AgentWorkspace.maxFixAttempts}.'
          : '\nThis was failed build #${ws.failedBuilds}. STOP retrying: tell the user what fails and what you think the cause is.');
    }
    return ToolResult(b.toString().trimRight(), ok: ok);
  }

  Future<ToolResult> _logs() async {
    final runs = await ws.gh.latestRuns(ws.repo, workflowFile: ws.workflowFile, branch: ws.branch);
    Map<String, dynamic>? run;
    for (final r in runs) {
      if (r['status'] == 'completed') {
        run = r;
        break;
      }
    }
    if (run == null) {
      return const ToolResult('No finished build found for this branch yet. Use trigger_build.', ok: false);
    }
    final url = run['html_url'] as String?;
    if (run['conclusion'] == 'success') {
      return ToolResult('The latest build SUCCEEDED.${url == null ? '' : ' Run: $url'}');
    }
    final d = await ws.poller.failureDigest(ws.repo, run['id'] as int);
    return ToolResult(
        BuildStatus(BuildPhase.failed, runUrl: url, failedStep: d.step, failureLog: d.log)
            .summaryForModel,
        ok: false);
  }

  Future<ToolResult> _remember(Map<String, dynamic> a) async {
    final note = (_s(a, 'note') ?? '').replaceAll('\n', ' ').trim();
    if (note.isEmpty) return const ToolResult('Need a non-empty "note".', ok: false);
    String? cur;
    try {
      cur = await ws.currentText('AGENTS.md');
    } on GitHubException catch (e) {
      if (e.status != 404) rethrow;
    }
    const head = '## Notes from the agent';
    var text = cur ?? '# AGENTS.md\n\nProject memory for AI coding agents. Read at the start of every session.\n';
    if (!text.contains(head)) text = '${text.trimRight()}\n\n$head\n';
    text = '${text.trimRight()}\n- $note\n';
    ws.staged['AGENTS.md'] = text;
    return const ToolResult('Noted in AGENTS.md (staged; it is saved with the next commit).');
  }
}
