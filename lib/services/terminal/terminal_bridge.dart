import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../github_service.dart';
import '../http_runner.dart';
import 'git_lite.dart';
import 'terminal_jobs.dart';
import 'terminal_legacy.dart';
import 'terminal_types.dart';

export 'terminal_jobs.dart' show TerminalJob, TerminalJobs;
export 'terminal_types.dart';

/// The agent's terminal.
///
/// * Real shell: commands run in the phone's own `/system/bin/sh` (toybox:
///   ls cat grep sed awk wc sort find tar ...), inside the app's private
///   workspace. Pipes, redirects, `&&`, loops and scripts all work.
/// * App built-ins that Android does not ship: `git` (GitHub API based),
///   `curl`/`wget` (with secret headers), `unzip`, `zip`, `tar`.
/// * Async jobs for anything slow (see [TerminalJobs]).
/// * `/workspace` is persistent app storage. `/storage` is a bridge to the
///   phone's shared storage (`/storage/emulated/0`) when the user allowed it.
class TerminalBridge {
  TerminalBridge();

  /// Wired by AppServices.
  SecretLookup? secrets;
  GitHubService? Function()? github;
  bool Function()? storageAllowed;

  final jobs = TerminalJobs();

  /// Called after a successful `git push` (owner, repo, branch, before, after).
  void Function(String owner, String repo, String branch, String before, String after)? onPush;
  late final HttpRunner http =
      HttpRunner((n) async => secrets == null ? null : await secrets!(n));
  final _legacy = LegacyTerminal();

  Directory? _root;
  String _cwd = '/workspace';
  bool? _hasShell;

  static const builtins = {
    'help', 'which', 'curl', 'wget', 'http', 'git', 'unzip', 'zip', 'tar', 'jobs', 'clear',
  };

  String get cwd => _cwd;
  String get shellPath => Platform.isAndroid ? '/system/bin/sh' : '/bin/sh';
  bool get _storageOn => storageAllowed?.call() ?? false;

  // ---- setup -------------------------------------------------------------

  Future<Directory> _workspace() async {
    if (_root != null) return _root!;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'terminal_workspace'));
    await d.create(recursive: true);
    await Directory(p.join(d.path, '.tmp')).create(recursive: true);
    final bin = Directory(p.join(d.path, 'bin'));
    await bin.create(recursive: true);
    for (final n in const ['git', 'curl', 'wget', 'unzip', 'zip', 'tar', 'http', 'jobs']) {
      final f = File(p.join(bin.path, n));
      if (!f.existsSync()) {
        f.writeAsStringSync(
            '#!/system/bin/sh\necho "$n is an app built-in. Run it as its own command, e.g. \\"$n ...\\", \\"$n ... && ls\\" or \\"$n ... | head\\". It cannot run inside scripts, loops or subshells." >&2\nexit 126\n');
        try {
          await Process.run('chmod', ['755', f.path]);
        } catch (_) {}
      }
    }
    _hasShell = File(shellPath).existsSync();
    _root = d;
    _legacy.cwd = _cwd;
    await _legacy.ensureRoot();
    return d;
  }

  /// Real phone-storage paths that [command] names (like /storage/Download/x),
  /// plus the current folder when it is on phone storage. Empty when /storage
  /// is off. The storage root itself is left out (the whole phone is too big).
  Future<List<String>> storagePathsIn(String command) async {
    await _workspace();
    if (!_storageOn) return const [];
    final found = <String>{};
    final re = RegExp(r"""(?<![\w.\-/])/storage(?:/[^\s"';|&<>()`*?]*)?""");
    for (final m in re.allMatches(command)) {
      final v = p.posix.normalize(m.group(0)!);
      if (v.startsWith('/storage/')) found.add(_real(v));
    }
    if (_cwd.startsWith('/storage/')) found.add(_real(_cwd));
    // A path inside another listed path is already covered by it.
    return [
      for (final a in found)
        if (!found.any((b) => b != a && p.isWithin(b, a))) a,
    ];
  }

  /// Real path of /workspace (created on first use).
  Future<String> workspaceRoot() async => (await _workspace()).path;

  Future<TerminalStatus> status() async {
    await _workspace();
    return TerminalStatus(
      realShell: _hasShell == true,
      storageBridge: _storageOn,
      githubConnected: github?.call() != null,
      runningJobs: jobs.runningCount,
    );
  }

  // ---- paths -------------------------------------------------------------

  String _vNorm(String value) {
    var v = value.trim().replaceAll('\\', '/');
    if (v.isEmpty || v == '.') return _cwd;
    if (v == '~') return '/workspace';
    if (v.startsWith('~/')) v = '/workspace/${v.substring(2)}';
    if (!v.startsWith('/')) v = p.posix.join(_cwd, v);
    v = p.posix.normalize(v);
    if (v == '/') return '/workspace';
    if (v == '/workspace' || v.startsWith('/workspace/')) return v;
    if (v == '/storage' || v.startsWith('/storage/')) {
      if (_storageOn) return v;
      throw StateError('/storage is off. Turn on "Phone storage in terminal" in Settings > Terminal.');
    }
    throw StateError('Path is outside /workspace and /storage: $v');
  }

  String _real(String virtual) {
    final root = _root!.path;
    if (virtual == '/workspace') return root;
    if (virtual.startsWith('/workspace/')) {
      return p.joinAll([root, ...virtual.substring('/workspace/'.length).split('/')]);
    }
    return '/storage/emulated/0${virtual.substring('/storage'.length)}';
  }

  String _virtual(String real) {
    final root = _root!.path;
    if (real == root) return '/workspace';
    if (real.startsWith('$root/')) return '/workspace/${real.substring(root.length + 1)}';
    if (real == '/storage/emulated/0') return '/storage';
    if (real.startsWith('/storage/emulated/0/')) {
      return '/storage${real.substring('/storage/emulated/0'.length)}';
    }
    return real;
  }

  String _resolve(String path) => _real(_vNorm(path));

  static final _wsRe = RegExp('(?<![\\w.\\-/])/workspace(?=/|\\s|\$|["\';)&|<>])');
  static final _stRe =
      RegExp('(?<![\\w.\\-])(?:/storage(?!/emulated)|/sdcard)(?=/|\\s|\$|["\';)&|<>])');

  String _virtToReal(String cmd) {
    if (_stRe.hasMatch(cmd) && !_storageOn) {
      throw StateError('/storage is off. Turn on "Phone storage in terminal" in Settings > Terminal.');
    }
    final root = _root!.path;
    return cmd
        .replaceAllMapped(_wsRe, (_) => root)
        .replaceAllMapped(_stRe, (_) => '/storage/emulated/0');
  }

  Future<String> _present(String s) async {
    final root = _root!.path;
    s = s.replaceAll(root, '/workspace').replaceAll('/storage/emulated/0', '/storage');
    return http.redact(s);
  }

  Map<String, String> _env() {
    final root = _root!.path;
    return {
      'HOME': root,
      'TMPDIR': p.join(root, '.tmp'),
      'PATH': '${p.join(root, 'bin')}:/system/bin:/system/xbin:/vendor/bin',
      'TERM': 'dumb',
      'LANG': 'C.UTF-8',
      'WORKSPACE': root,
      'PWD': _real(_cwd),
      'GIT_TERMINAL_PROMPT': '0', // never wait for a username/password
      'DEBIAN_FRONTEND': 'noninteractive',
      'CI': 'true',
    };
  }

  // ---- public API --------------------------------------------------------

  Future<CmdResult> run(String command, {String? workdir, int timeoutMs = 60000}) async {
    if (command.trim().isEmpty) return const CmdResult('', '', 0, false, null);
    final ms = timeoutMs.clamp(1000, 15 * 60 * 1000);
    try {
      await _workspace();
      if (workdir != null && workdir.trim().isNotEmpty) {
        final next = _vNorm(workdir);
        if (Directory(_real(next)).existsSync()) _cwd = next;
      }
      if (!Directory(_real(_cwd)).existsSync()) _cwd = '/workspace';
      return await _runChain(command, ms);
    } on StateError catch (e) {
      return CmdResult.err(e.message);
    } catch (e) {
      return CmdResult('', '', null, false, 'Terminal error: $e');
    }
  }

  /// Starts a long-running command in the background. Poll with [jobs].
  Future<TerminalJob> startJob(String command, {String? workdir}) async {
    await _workspace();
    if (_hasShell != true) throw StateError('Background jobs need a real shell (Android).');
    if (workdir != null && workdir.trim().isNotEmpty) {
      final next = _vNorm(workdir);
      if (Directory(_real(next)).existsSync()) _cwd = next;
    }
    final first = _tokens(command).firstOrNull ?? '';
    if (builtins.contains(first)) {
      throw StateError('"$first" is a built-in. Run it with terminal_run; jobs are for slow shell commands.');
    }
    return jobs.start(
      shell: shellPath,
      script: _virtToReal(command),
      display: command,
      cwd: _real(_cwd),
      env: _env(),
      logDir: p.join(_root!.path, '.jobs'),
    );
  }

  // ---- chaining ----------------------------------------------------------

  Future<CmdResult> _runChain(String command, int ms) async {
    final shellOnly = command.contains('\n') ||
        command.contains(r'$(') ||
        command.contains('`') ||
        command.contains('<<') ||
        RegExp(r'^\s*(if|for|while|case|until|function)\b|^\s*[{(]').hasMatch(command);
    final segs = shellOnly ? <(String, String)>[(command.trim(), '')] : _split(command);
    final groups = <_Group>[];
    for (var i = 0; i < segs.length; i++) {
      final before = i == 0 ? '' : segs[i - 1].$2;
      final name = _tokens(segs[i].$1).firstOrNull ?? '';
      if (!shellOnly && builtins.contains(name)) {
        groups.add(_Group(segs[i].$1, before, segs[i].$2, true));
      } else {
        final text = StringBuffer(segs[i].$1);
        var after = segs[i].$2;
        while (!shellOnly && i + 1 < segs.length) {
          final nn = _tokens(segs[i + 1].$1).firstOrNull ?? '';
          if (builtins.contains(nn)) break;
          text.write(' $after ${segs[i + 1].$1}');
          after = segs[i + 1].$2;
          i++;
        }
        groups.add(_Group(text.toString(), before, after, false));
      }
    }

    final so = StringBuffer(), se = StringBuffer();
    var lastOk = true;
    int? code = 0;
    var timedOut = false;
    String? error;
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      if (g.before == '&&' && !lastOk) continue;
      if (g.before == '||' && lastOk) continue;
      CmdResult r;
      if (g.builtin) {
        r = await _builtin(g.text);
        if (g.after == '|') {
          final next = gi + 1 < groups.length ? groups[gi + 1] : null;
          if (next == null || next.builtin) {
            r = CmdResult.err('A built-in can only pipe into a normal shell command.');
          } else {
            r = await _shell(next.text, ms, stdinText: r.stdout);
            gi++;
          }
        }
      } else if (g.before == '|') {
        r = CmdResult.err('Built-ins cannot receive piped input. Write to a file first, then read it.');
      } else {
        r = await _shell(g.text, ms);
      }
      so.write(r.stdout);
      se.write(r.stderr);
      code = r.exitCode;
      timedOut = timedOut || r.timedOut;
      lastOk = r.ok;
      if (r.error != null) {
        error = r.error;
        break;
      }
      if (r.timedOut) break;
    }
    return CmdResult(so.toString(), se.toString(), code, timedOut, error);
  }

  List<(String, String)> _split(String s) {
    final out = <(String, String)>[];
    final cur = StringBuffer();
    String? q;
    void push(String conn) {
      out.add((cur.toString().trim(), conn));
      cur.clear();
    }

    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (q != null) {
        cur.write(c);
        if (c == r'\' && q == '"' && i + 1 < s.length) {
          cur.write(s[++i]);
        } else if (c == q) {
          q = null;
        }
        continue;
      }
      if (c == r'\' && i + 1 < s.length) {
        cur.write(c);
        cur.write(s[++i]);
        continue;
      }
      if (c == '"' || c == "'") {
        q = c;
        cur.write(c);
        continue;
      }
      final two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      if (two == '&&' || two == '||') {
        push(two);
        i++;
        continue;
      }
      if (c == '|') {
        push('|');
        continue;
      }
      if (c == ';') {
        push(';');
        continue;
      }
      cur.write(c);
    }
    push('');
    return out.where((e) => e.$1.isNotEmpty).toList();
  }

  List<String> _tokens(String input) {
    final out = <String>[];
    final re = RegExp('("(?:\\\\.|[^"\\\\])*"|\'[^\']*\'|[^\\s]+)');
    for (final m in re.allMatches(input)) {
      var v = m.group(0)!;
      if (v.length >= 2 &&
          ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
        final dq = v.startsWith('"');
        v = v.substring(1, v.length - 1);
        if (dq) v = v.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      }
      out.add(v);
    }
    return out;
  }

  // ---- real shell --------------------------------------------------------

  static const _hint127 =
      '\n(hint) Not on this phone: python, node, java, gradle, apt. Available: git/curl/unzip (built in), '
      'toybox tools (ls grep sed awk find sort wc ...). To build, push the code to GitHub and run the workflow.';

  Future<CmdResult> _shell(String cmd, int ms, {String? stdinText}) async {
    if (_hasShell != true) return _fallback(cmd);
    final String script;
    try {
      script = _virtToReal(cmd);
    } on StateError catch (e) {
      return CmdResult.err(e.message);
    }
    final wrapped = '$script\n__rc=\$?\nprintf "\\n__AIDH_CWD__%s" "\$(pwd)"\nexit \$__rc';
    final Process proc;
    try {
      proc = await Process.start(shellPath, ['-c', wrapped],
          workingDirectory: _real(_cwd), environment: _env(), includeParentEnvironment: false);
    } on ProcessException {
      _hasShell = false;
      return _fallback(cmd);
    }
    if (stdinText != null) proc.stdin.add(utf8.encode(stdinText));
    unawaited(proc.stdin.close().catchError((_) {})); // no interactive prompts, ever
    const cap = 2 * 1024 * 1024;
    final outB = BytesBuilder(copy: false), errB = BytesBuilder(copy: false);
    final done = Future.wait([
      proc.stdout.listen((d) {
        if (outB.length < cap) outB.add(d);
      }).asFuture<void>(),
      proc.stderr.listen((d) {
        if (errB.length < cap) errB.add(d);
      }).asFuture<void>(),
    ]);
    int? code;
    var timedOut = false;
    try {
      code = await proc.exitCode.timeout(Duration(milliseconds: ms));
    } on TimeoutException {
      timedOut = true;
      proc.kill();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      proc.kill(ProcessSignal.sigkill);
    }
    try {
      await done.timeout(const Duration(seconds: 2));
    } catch (_) {}

    var out = utf8.decode(outB.takeBytes(), allowMalformed: true);
    var err = utf8.decode(errB.takeBytes(), allowMalformed: true);
    final m = RegExp(r'\n?__AIDH_CWD__(.*)$', dotAll: true).firstMatch(out);
    if (m != null) {
      final v = _virtual(m.group(1)!.trim());
      out = out.substring(0, m.start);
      if (v.startsWith('/workspace') || v.startsWith('/storage')) _cwd = v;
    }
    out = await _present(out);
    err = await _present(err);
    if (code == 127) err = '$err$_hint127';
    if (timedOut) {
      err = '$err\nTimed out after ${ms ~/ 1000}s. For slow commands use terminal_job_start.'.trim();
    }
    return CmdResult(out, err, code, timedOut, null);
  }

  Future<CmdResult> _fallback(String cmd) async {
    _legacy.cwd = _cwd;
    final r = await _legacy.run(cmd);
    _cwd = _legacy.cwd;
    return r;
  }

  // ---- built-ins ---------------------------------------------------------

  Future<CmdResult> _builtin(String text) async {
    String? redirect;
    var append = false;
    var body = text;
    final rm = RegExp(r'^(.*?)\s*(>>?)\s*([^\s>]+)\s*$', dotAll: true).firstMatch(text);
    if (rm != null) {
      body = rm.group(1)!;
      append = rm.group(2) == '>>';
      redirect = rm.group(3);
    }
    final a = _tokens(body);
    if (a.isEmpty) return CmdResult.out('');
    final name = a.first;
    final args = a.sublist(1);
    CmdResult r;
    try {
      switch (name) {
        case 'help':
          r = CmdResult.out(_help);
        case 'clear':
          r = CmdResult.out('');
        case 'which':
          r = await _which(args);
        case 'curl' || 'http':
          r = await _curl(args);
        case 'wget':
          r = await _wget(args);
        case 'git':
          r = await _git(args);
        case 'unzip':
          r = await _unzip(args);
        case 'zip':
          r = await _zip(args);
        case 'tar':
          r = await _tar(args);
        case 'jobs':
          r = _jobsCmd(args);
        default:
          r = CmdResult.err('$name: not a built-in', 127);
      }
    } on StateError catch (e) {
      r = CmdResult.err(e.message);
    } on HttpException catch (e) {
      r = CmdResult.err('$name: ${e.message}', 6);
    } on SocketException catch (e) {
      r = CmdResult.err('$name: network error: ${e.message}', 7);
    } on TimeoutException {
      r = CmdResult.err('$name: timed out', 28);
    } on FileSystemException catch (e) {
      r = CmdResult.err('$name: ${e.message} ${e.path ?? ''}');
    } on FormatException catch (e) {
      r = CmdResult.err('$name: ${e.message}');
    }
    if (redirect != null && r.ok) {
      final f = File(_resolve(redirect));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(r.stdout, mode: append ? FileMode.append : FileMode.write);
      return CmdResult('', r.stderr, 0, false, null);
    }
    return CmdResult(await _present(r.stdout), await _present(r.stderr), r.exitCode, r.timedOut, r.error);
  }

  static const _help = '''AI Dev Hub terminal: real shell + built-ins
Shell: sh with toybox (ls cat grep sed awk find sort wc head tail tr cut diff chmod ...), pipes, redirects, && ; loops.
Built-ins:
  git     clone/status/diff/commit/push/pull/log/branch/checkout (via GitHub API)
  curl    -X -H -d --json -o -i -u  (use {{secret:github}} in headers; api.github.com is auto-authenticated)
  wget    -O file url
  unzip   [-l] [-d dir] file.zip    zip [-r] out.zip paths    tar -czf / -xzf / -tf
  jobs    list | log ID | kill ID   (start jobs with terminal_job_start)
  which   name
Paths: /workspace (persistent app storage), /storage (phone storage, when allowed in Settings).
Not on the phone: python node java gradle apt. Build on GitHub Actions instead.''';

  Future<CmdResult> _which(List<String> a) async {
    if (a.isEmpty) return CmdResult.err('which: name required');
    final b = StringBuffer();
    var ok = true;
    for (final n in a) {
      if (builtins.contains(n)) {
        b.writeln('$n: app built-in');
        continue;
      }
      final safe = n.replaceAll(RegExp(r'[^\w.+\-]'), '');
      final r = await _shell('command -v $safe', 5000);
      if (r.stdout.trim().isEmpty) {
        b.writeln('$n not found');
        ok = false;
      } else {
        b.writeln(r.stdout.trim());
      }
    }
    return CmdResult(b.toString().trimRight(), '', ok ? 0 : 1, false, null);
  }

  CmdResult _jobsCmd(List<String> a) {
    if (a.isEmpty || a.first == 'list') {
      if (jobs.all.isEmpty) return CmdResult.out('No jobs.');
      return CmdResult.out(jobs.all
          .map((j) => '${j.id}  ${j.running ? 'running' : 'exit ${j.exitCode}'}  ${j.elapsed}  ${j.command}')
          .join('\n'));
    }
    final j = a.length > 1 ? jobs.get(a[1]) : null;
    if (j == null) return CmdResult.err('jobs: unknown job id');
    if (a.first == 'kill') {
      return CmdResult.out(jobs.kill(j.id) ? 'Stopping ${j.id}...' : '${j.id} is not running.');
    }
    if (a.first == 'log') {
      return CmdResult.out(j.all.length > 20000 ? j.all.substring(j.all.length - 20000) : j.all);
    }
    return CmdResult.err('usage: jobs [list | log ID | kill ID]');
  }

  // ---- curl / wget -------------------------------------------------------

  Future<CmdResult> _curl(List<String> a) async {
    String? url, method, out, user;
    final headers = <String, String>{};
    final data = <String>[];
    var include = false, head = false, fail = false, silent = false, json = false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      String next() => i + 1 < a.length ? a[++i] : '';
      switch (x) {
        case '-X' || '--request':
          method = next();
        case '-H' || '--header':
          final h = next();
          final k = h.indexOf(':');
          if (k > 0) headers[h.substring(0, k).trim()] = h.substring(k + 1).trim();
        case '-d' || '--data' || '--data-raw' || '--data-binary':
          data.add(next());
        case '--json':
          data.add(next());
          json = true;
        case '-o' || '--output':
          out = next();
        case '-u' || '--user':
          user = next();
        case '-A' || '--user-agent':
          headers['User-Agent'] = next();
        case '-i' || '--include':
          include = true;
        case '-I' || '--head':
          head = true;
          include = true;
        case '-f' || '--fail':
          fail = true;
        case '--silent':
          silent = true;
        case '--max-time' || '-m':
          next();
        default:
          if (x.startsWith('-') && !x.startsWith('--')) {
            if (x.contains('s')) silent = true; // -s, -sS, -fsSL ...
            if (x.contains('f')) fail = true;
            continue; // -L -k -v -S are accepted and ignored
          }
          if (x.startsWith('--')) continue;
          url ??= x;
      }
    }
    if (url == null) return CmdResult.err('curl: no URL given', 2);
    var payload = data.isEmpty ? null : data.join('&');
    if (payload != null && payload.startsWith('@')) {
      payload = File(_resolve(payload.substring(1))).readAsStringSync();
    }
    if (payload != null && !headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
      final t = payload.trimLeft();
      headers['Content-Type'] = json || t.startsWith('{') || t.startsWith('[')
          ? 'application/json'
          : 'application/x-www-form-urlencoded';
    }
    if (user != null) headers['Authorization'] = 'Basic ${base64.encode(utf8.encode(user))}';
    final m = (method ?? (head ? 'HEAD' : (payload != null ? 'POST' : 'GET'))).toUpperCase();
    final res = await http.send(m, url, headers: headers, body: payload, timeout: const Duration(seconds: 60));
    final err = StringBuffer();
    if (res.status >= 400 || !silent) err.write('HTTP ${res.status} · ${res.ms} ms');
    if (fail && res.status >= 400) return CmdResult('', err.toString(), 22, false, null);
    final so = StringBuffer();
    if (include) {
      so.writeln('HTTP ${res.status}');
      res.headers.forEach((k, v) => so.writeln('$k: $v'));
      so.writeln();
    }
    if (out != null) {
      final f = File(_resolve(out));
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(res.bytes);
      err.write('${err.isEmpty ? '' : '\n'}Saved ${res.bytes.length} bytes to ${_virtual(f.path)}');
    } else if (!head) {
      const cap = 200000;
      final t = res.text;
      so.write(t.contains('\uFFFD') && res.bytes.length > 2000
          ? '(binary ${res.bytes.length} bytes. Use: curl -o file URL)'
          : (t.length > cap ? '${t.substring(0, cap)}\n[... truncated, use -o file ...]' : t));
    }
    return CmdResult(so.toString(), err.toString(), 0, false, null);
  }

  Future<CmdResult> _wget(List<String> a) async {
    String? url, out, dir;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-O' && i + 1 < a.length) {
        out = a[++i];
      } else if (a[i] == '-P' && i + 1 < a.length) {
        dir = a[++i];
      } else if (!a[i].startsWith('-')) {
        url ??= a[i];
      }
    }
    if (url == null) return CmdResult.err('wget: missing URL', 1);
    final res = await http.send('GET', url, timeout: const Duration(minutes: 5));
    if (!res.ok) return CmdResult.err('wget: server returned ${res.status}', 8);
    var name = out ?? Uri.parse(res.finalUrl).pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'index.html';
    if (dir != null && out == null) name = p.posix.join(dir, name);
    final f = File(_resolve(name));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(res.bytes);
    return CmdResult.out('Saved ${res.bytes.length} bytes to ${_virtual(f.path)}');
  }

  // ---- git ---------------------------------------------------------------

  Future<CmdResult> _git(List<String> a) async {
    final gh = github?.call();
    if (gh == null) {
      return CmdResult.err('git: GitHub is not connected. Add a token in Connectors, then try again.', 128);
    }
    return (GitLite(gh, _resolve, Directory(_real(_cwd)))..onPush = onPush).run(a);
  }

  // ---- archives ----------------------------------------------------------

  bool _safe(String name) => !(name.startsWith('/') || name.split('/').contains('..'));

  Future<CmdResult> _unzip(List<String> a) async {
    String? file, dest;
    var list = false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-d' && i + 1 < a.length) {
        dest = a[++i];
      } else if (a[i] == '-l') {
        list = true;
      } else if (!a[i].startsWith('-')) {
        file ??= a[i];
      }
    }
    if (file == null) return CmdResult.err('usage: unzip [-l] [-d dir] file.zip', 1);
    final arc = ZipDecoder().decodeBytes(File(_resolve(file)).readAsBytesSync());
    if (list) return CmdResult.out(arc.map((f) => '${f.size.toString().padLeft(9)}  ${f.name}').join('\n'));
    final base = Directory(_resolve(dest ?? '.'));
    var n = 0;
    for (final f in arc) {
      if (!_safe(f.name)) continue;
      final target = p.joinAll([base.path, ...f.name.split('/')]);
      if (f.isFile) {
        File(target)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(List<int>.from(f.content as List));
        n++;
      } else {
        Directory(target).createSync(recursive: true);
      }
    }
    return CmdResult.out('Extracted $n file(s) to ${_virtual(base.path)}');
  }

  Archive _collect(List<String> paths) {
    final arc = Archive();
    final cwd = Directory(_real(_cwd));
    void add(FileSystemEntity e) {
      final rel = p.posix.joinAll(p.split(p.relative(e.path, from: cwd.path)));
      if (e is File) {
        final bytes = e.readAsBytesSync();
        arc.addFile(ArchiveFile(rel, bytes.length, bytes));
      } else if (e is Directory) {
        for (final c in e.listSync(recursive: true, followLinks: false)) {
          if (c is File) add(c);
        }
      }
    }

    for (final x in paths) {
      final real = _resolve(x);
      final t = FileSystemEntity.typeSync(real);
      if (t == FileSystemEntityType.notFound) throw StateError('$x: no such file or directory');
      add(t == FileSystemEntityType.directory ? Directory(real) : File(real));
    }
    return arc;
  }

  Future<CmdResult> _zip(List<String> a) async {
    final v = a.where((x) => !x.startsWith('-')).toList();
    if (v.length < 2) return CmdResult.err('usage: zip [-r] out.zip file-or-dir ...', 1);
    final arc = _collect(v.sublist(1));
    final bytes = ZipEncoder().encode(arc);
    if (bytes == null) return CmdResult.err('zip: failed to encode', 1);
    final f = File(_resolve(v.first.endsWith('.zip') ? v.first : '${v.first}.zip'));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return CmdResult.out('Created ${_virtual(f.path)}: ${arc.length} file(s), ${bytes.length} bytes');
  }

  Future<CmdResult> _tar(List<String> a) async {
    if (a.isEmpty) {
      return CmdResult.err('usage: tar -czf out.tgz paths | tar -xzf in.tgz [-C dir] | tar -tf in.tar', 1);
    }
    final flags = a.first.replaceAll('-', '');
    final rest = a.sublist(1);
    final gz = flags.contains('z');
    String? dest;
    final plain = <String>[];
    for (var i = 0; i < rest.length; i++) {
      if (rest[i] == '-C' && i + 1 < rest.length) {
        dest = rest[++i];
      } else {
        plain.add(rest[i]);
      }
    }
    if (plain.isEmpty) return CmdResult.err('tar: archive name required', 1);
    final file = File(_resolve(plain.first));
    if (flags.contains('c')) {
      final arc = _collect(plain.sublist(1));
      var bytes = TarEncoder().encode(arc);
      if (gz) bytes = GZipEncoder().encode(bytes) ?? bytes;
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      return CmdResult.out('Created ${_virtual(file.path)}: ${arc.length} file(s)');
    }
    var raw = file.readAsBytesSync();
    if (gz || (raw.length > 2 && raw[0] == 0x1f && raw[1] == 0x8b)) {
      raw = Uint8List.fromList(GZipDecoder().decodeBytes(raw));
    }
    final arc = TarDecoder().decodeBytes(raw);
    if (flags.contains('t')) return CmdResult.out(arc.map((f) => f.name).join('\n'));
    final base = Directory(_resolve(dest ?? '.'));
    var n = 0;
    for (final f in arc) {
      if (!f.isFile || !_safe(f.name)) continue;
      File(p.joinAll([base.path, ...f.name.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List<int>.from(f.content as List));
      n++;
    }
    return CmdResult.out('Extracted $n file(s) to ${_virtual(base.path)}');
  }
}

class _Group {
  final String text, before, after;
  final bool builtin;
  _Group(this.text, this.before, this.after, this.builtin);
}
