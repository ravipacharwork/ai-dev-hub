import 'dart:async';

import '../build_poller.dart';
import '../deliverables.dart';
import '../github_service.dart';

/// Shown to the user before an action that leaves the device.
class ApprovalRequest {
  final String title, detail;
  const ApprovalRequest(this.title, this.detail);
}

class ToolResult {
  final String content;
  final bool ok;
  final Stream<BuildStatus>? build; // set by trigger_build
  final List<Deliverable> deliverables; // files handed to the user in chat
  const ToolResult(this.content,
      {this.ok = true, this.build, this.deliverables = const []});
}

/// The repo the agent works on, plus changes staged on the device.
/// Staged changes live in memory: they are lost if the app is killed.
class AgentWorkspace {
  final GitHubService gh;
  final RepoRef repo;
  final String branch, workflowFile;
  final BuildPoller poller;

  /// path -> new text, or null meaning "delete this file".
  final Map<String, String?> staged = {};
  List<TreeEntry>? tree; // cached; cleared after a commit

  AgentWorkspace(this.gh, this.repo, this.branch, this.workflowFile)
      : poller = BuildPoller(gh);

  String get slug => '${repo.owner}/${repo.repo}@$branch';
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
  AgentToolkit(this.ws);

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
            'Commit and push all staged changes in one commit. The user must approve.',
            {'message': _p('Commit message')},
            ['message']),
        _fn(
            'trigger_build',
            'Start the GitHub Actions build for the committed code. The user must approve.',
            {}),
      ];

  String get systemNote => '''You can work on the user's GitHub repository ${ws.slug} with tools.
- Explore with list_files and read_file before editing; read_file accepts start_line/end_line for large files.
- Prefer replace_in_file for small edits (old_str must match exactly once). Use write_file for new files or full rewrites.
- write_file, replace_in_file and delete_file only STAGE changes on the device. Nothing reaches GitHub until commit_changes, which the user must approve.
- trigger_build builds the committed code on GitHub Actions, so commit first. The user must approve it too.
- If the user denies an action, do not retry it; ask what they want instead.
- Be economical: do not re-read files you already have, and keep tool calls to what the task needs.''';

  String label(String name, Map<String, dynamic> a) {
    final path = a['path'];
    return path is String ? '$name  $path' : name;
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

  Future<ToolResult> run(String name, Map<String, dynamic> a) async {
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
  Future<String?> _current(String path) async {
    if (ws.staged.containsKey(path)) return ws.staged[path];
    return (await ws.gh.readFile(ws.repo, path, ws.branch)).$1;
  }

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
    return ToolResult('Committed $n file(s) to ${ws.slug} as ${sha.substring(0, 7)}.');
  }

  ToolResult _build() {
    final stream = ws.poller.run(ws.repo,
        workflowFile: ws.workflowFile,
        ref: ws.branch,
        correlationId: BuildPoller.newCorrelationId());
    final n = ws.staged.length;
    final warn = n > 0 ? ' Note: $n staged change(s) are NOT committed and are not in this build.' : '';
    return ToolResult(
        'Build dispatched for ${ws.slug} (workflow ${ws.workflowFile}). Progress and the install button appear in the chat; do not wait or poll.$warn',
        build: stream);
  }
}
