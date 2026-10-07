import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class TerminalStatus {
  final bool ready;
  final String workspace;
  const TerminalStatus({this.ready = true, this.workspace = '/workspace'});
}

class CmdResult {
  final String stdout, stderr;
  final int? exitCode;
  final bool timedOut;
  final String? error;
  const CmdResult(this.stdout, this.stderr, this.exitCode, this.timedOut, this.error);
  bool get ok => error == null && !timedOut && exitCode == 0;
  factory CmdResult.failure(String msg) => CmdResult('', '', null, false, msg);
}

/// Safe, built-in terminal for the app workspace.
///
/// Flutter mobile apps cannot spawn an unrestricted OS shell. Instead this
/// terminal provides common shell/file commands against an app-private
/// workspace, so no Termux, Shizuku, ADB or external permissions are needed.
class TerminalBridge {
  Directory? _root;
  String _cwd = '/workspace';

  Future<Directory> _workspace() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'terminal_workspace'));
    await d.create(recursive: true);
    _root ??= d;
    return d;
  }

  Future<TerminalStatus> status() async {
    await _workspace();
    return const TerminalStatus();
  }

  String get cwd => _cwd;

  Future<CmdResult> run(String command, {String? workdir, int timeoutMs = 60000}) async {
    if (command.trim().isEmpty) return const CmdResult('', '', 0, false, null);
    try {
      await _workspace();
      if (workdir != null && workdir.trim().isNotEmpty) {
        final next = _normaliseVirtual(workdir);
        if (await Directory(_resolve(next).path).exists()) _cwd = next;
      }
      final args = _tokenise(command);
      if (args.isEmpty) return const CmdResult('', '', 0, false, null);
      final name = args.first;
      final rest = args.sublist(1);
      switch (name) {
        case 'help':
          return _ok('Built-in commands:\n  pwd, ls, cd, cat, head, tail, echo, touch\n  mkdir, rm, cp, mv, find, grep, date, whoami, uname, clear\n\nWorkspace: /workspace (app-private; external apps cannot access it)');
        case 'pwd': return _ok(_cwd);
        case 'clear': return _ok('');
        case 'whoami': return _ok('ai-dev-hub');
        case 'uname': return _ok('AI Dev Hub built-in terminal');
        case 'date': return _ok(DateTime.now().toIso8601String());
        case 'echo': return _ok(rest.join(' '));
        case 'cd': return _cd(rest);
        case 'ls': return _ls(rest);
        case 'cat': return _cat(rest);
        case 'head': return _lines(rest, 10);
        case 'tail': return _tail(rest, 10);
        case 'touch': return _touch(rest);
        case 'mkdir': return _mkdir(rest);
        case 'rm': return _rm(rest);
        case 'cp': return _copy(rest);
        case 'mv': return _move(rest);
        case 'find': return _find(rest);
        case 'grep': return _grep(rest);
        default:
          return CmdResult('', 'Command not available in built-in terminal: $name\nRun "help" for supported commands.', 127, false, null);
      }
    } catch (e) {
      return CmdResult('', '', null, false, 'Terminal error: $e');
    }
  }

  CmdResult _ok(String text) => CmdResult(text, '', 0, false, null);

  String _normaliseVirtual(String value) {
    var v = value.trim().replaceAll('\\', '/');
    if (v.isEmpty || v == '.') return _cwd;
    if (!v.startsWith('/')) v = p.posix.join(_cwd, v);
    v = p.posix.normalize(v);
    if (v == '/' || v == '/workspace') return '/workspace';
    if (!v.startsWith('/workspace/')) return '/workspace';
    return v;
  }

  FileSystemEntity _resolve(String value) {
    final root = _root!;
    final v = _normaliseVirtual(value);
    final relative = v == '/workspace' ? '' : v.substring('/workspace/'.length);
    return FileSystemEntity.typeSync(p.join(root.path, relative)) == FileSystemEntityType.directory
        ? Directory(p.join(root.path, relative))
        : File(p.join(root.path, relative));
  }

  List<String> _tokenise(String input) {
    final out = <String>[];
    final re = RegExp(r'''("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s]+)''');
    for (final m in re.allMatches(input)) {
      var v = m.group(0)!;
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.substring(1, v.length - 1);
      out.add(v.replaceAll(r'\"', '"').replaceAll(r'\n', '\n'));
    }
    return out;
  }

  Future<CmdResult> _cd(List<String> a) async {
    final target = _normaliseVirtual(a.isEmpty ? '/workspace' : a.first);
    if (!await Directory(_resolve(target).path).exists()) return CmdResult('', 'cd: no such directory: $target', 1, false, null);
    _cwd = target;
    return _ok('');
  }

  Future<CmdResult> _ls(List<String> a) async {
    final target = a.isEmpty ? _cwd : _normaliseVirtual(a.last);
    final d = Directory(_resolve(target).path);
    if (!await d.exists()) return CmdResult('', 'ls: no such directory: $target', 1, false, null);
    final entries = await d.list().toList();
    entries.sort((x, y) => p.basename(x.path).compareTo(p.basename(y.path)));
    return _ok(entries.map((e) => '${e is Directory ? 'd' : 'f'}  ${p.basename(e.path)}').join('\n'));
  }

  Future<CmdResult> _cat(List<String> a) async {
    if (a.isEmpty) return CmdResult('', 'cat: missing file', 1, false, null);
    final f = File(_resolve(a.first).path);
    if (!await f.exists()) return CmdResult('', 'cat: no such file: ${a.first}', 1, false, null);
    return _ok(await f.readAsString());
  }

  Future<CmdResult> _lines(List<String> a, int count) async {
    if (a.isEmpty) return CmdResult('', 'head: missing file', 1, false, null);
    final f = File(_resolve(a.last).path);
    if (!await f.exists()) return CmdResult('', 'file not found: ${a.last}', 1, false, null);
    final lines = const LineSplitter().convert(await f.readAsString());
    return _ok(lines.take(count).join('\n'));
  }

  Future<CmdResult> _tail(List<String> a, int count) async {
    if (a.isEmpty) return CmdResult('', 'tail: missing file', 1, false, null);
    final f = File(_resolve(a.last).path);
    if (!await f.exists()) return CmdResult('', 'file not found: ${a.last}', 1, false, null);
    final lines = const LineSplitter().convert(await f.readAsString());
    return _ok(lines.skip(lines.length > count ? lines.length - count : 0).join('\n'));
  }

  Future<CmdResult> _touch(List<String> a) async {
    if (a.isEmpty) return CmdResult('', 'touch: missing file', 1, false, null);
    for (final x in a) { final f = File(_resolve(x).path); await f.parent.create(recursive: true); if (!await f.exists()) await f.create(); }
    return _ok('');
  }

  Future<CmdResult> _mkdir(List<String> a) async {
    final values = a.where((x) => x != '-p').toList();
    if (values.isEmpty) return CmdResult('', 'mkdir: missing directory', 1, false, null);
    for (final x in values) await Directory(_resolve(x).path).create(recursive: true);
    return _ok('');
  }

  Future<CmdResult> _rm(List<String> a) async {
    final values = a.where((x) => !x.startsWith('-')).toList();
    if (values.isEmpty) return CmdResult('', 'rm: missing operand', 1, false, null);
    for (final x in values) {
      if (_normaliseVirtual(x) == '/workspace') return CmdResult('', 'rm: refusing to remove workspace root', 1, false, null);
      final entity = _resolve(x);
      if (await entity.exists()) await entity.delete(recursive: a.contains('-r') || a.contains('-rf'));
    }
    return _ok('');
  }

  Future<void> _copyEntity(FileSystemEntity from, FileSystemEntity to) async {
    if (from is Directory) {
      final out = Directory(to.path); await out.create(recursive: true);
      await for (final child in from.list()) await _copyEntity(child, FileSystemEntity.isDirectorySync(child.path) ? Directory(p.join(out.path, p.basename(child.path))) : File(p.join(out.path, p.basename(child.path))));
    } else { await File(to.path).parent.create(recursive: true); await File(from.path).copy(to.path); }
  }

  Future<CmdResult> _copy(List<String> a) async {
    if (a.length < 2) return CmdResult('', 'cp: source and destination required', 1, false, null);
    await _copyEntity(_resolve(a.first), _resolve(a.last)); return _ok('');
  }

  Future<CmdResult> _move(List<String> a) async {
    if (a.length < 2) return CmdResult('', 'mv: source and destination required', 1, false, null);
    final from = _resolve(a.first); final to = _resolve(a.last); await _copyEntity(from, to); await from.delete(recursive: from is Directory); return _ok('');
  }

  Future<CmdResult> _find(List<String> a) async {
    final base = a.isEmpty || a.first == '.' ? _cwd : _normaliseVirtual(a.first);
    final pattern = a.length > 2 && a[a.length - 2] == '-name' ? a.last : null;
    final out = <String>[];
    await for (final e in Directory(_resolve(base).path).list(recursive: true, followLinks: false)) {
      final virtual = '/workspace/${p.relative(e.path, from: _root!.path)}';
      if (pattern == null || _glob(p.basename(e.path), pattern)) out.add(virtual);
    }
    return _ok(out.join('\n'));
  }

  bool _glob(String value, String pattern) => RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$').hasMatch(value);

  Future<CmdResult> _grep(List<String> a) async {
    if (a.length < 2) return CmdResult('', 'grep: pattern and file required', 1, false, null);
    final f = File(_resolve(a.last).path); if (!await f.exists()) return CmdResult('', 'grep: file not found', 2, false, null);
    final needle = a.sublist(0, a.length - 1).join(' '); final lines = const LineSplitter().convert(await f.readAsString());
    return _ok(lines.where((x) => x.contains(needle)).join('\n'));
  }
}
