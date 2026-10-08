import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A long-running command (npm install, gradle, a dev server...). Output goes
/// to a log file, so a job survives many tool calls and the model can poll it.
class TerminalJob {
  final String id, command, logPath;
  final DateTime startedAt = DateTime.now();
  Process? process;
  int? exitCode;
  DateTime? endedAt;
  int _polled = 0; // chars the model has already seen
  final StringBuffer _buf = StringBuffer();
  static const _memCap = 400000;

  TerminalJob(this.id, this.command, this.logPath);

  bool get running => exitCode == null;
  String get all => _buf.toString();

  void add(String s) {
    _buf.write(s);
    if (_buf.length > _memCap) {
      final keep = _buf.toString().substring(_buf.length - _memCap ~/ 2);
      _buf
        ..clear()
        ..write(keep);
      _polled = 0;
    }
  }

  /// Output the caller has not seen yet.
  String takeNew({int max = 8000}) {
    final s = all;
    final from = _polled > s.length ? 0 : _polled;
    var out = s.substring(from);
    _polled = s.length;
    if (out.length > max) {
      out = '[... ${out.length - max} earlier chars skipped ...]\n${out.substring(out.length - max)}';
    }
    return out;
  }

  String get elapsed {
    final d = (endedAt ?? DateTime.now()).difference(startedAt);
    return d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';
  }
}

class TerminalJobs {
  final _jobs = <String, TerminalJob>{};
  int _n = 0;

  Iterable<TerminalJob> get all => _jobs.values;
  int get runningCount => _jobs.values.where((j) => j.running).length;
  TerminalJob? get(String id) => _jobs[id];

  Future<TerminalJob> start({
    required String shell,
    required String script,
    required String display,
    required String cwd,
    required Map<String, String> env,
    required String logDir,
  }) async {
    if (runningCount >= 4) {
      throw StateError('Max 4 jobs at once. Kill one with terminal_job_kill.');
    }
    final id = 'job${++_n}';
    await Directory(logDir).create(recursive: true);
    final job = TerminalJob(id, display, '$logDir/$id.log');
    final log = File(job.logPath).openWrite();
    final proc = await Process.start(shell, ['-c', script],
        workingDirectory: cwd, environment: env, includeParentEnvironment: false);
    job.process = proc;
    unawaited(proc.stdin.close().catchError((_) {})); // never wait on a prompt
    void sink(List<int> d) {
      final s = utf8.decode(d, allowMalformed: true);
      job.add(s);
      log.write(s);
    }

    final done = Future.wait([
      proc.stdout.listen(sink).asFuture<void>(),
      proc.stderr.listen(sink).asFuture<void>(),
    ]);
    unawaited(proc.exitCode.then((code) async {
      try {
        await done.timeout(const Duration(seconds: 2));
      } catch (_) {}
      job.exitCode = code;
      job.endedAt = DateTime.now();
      await log.close();
    }));
    _jobs[id] = job;
    return job;
  }

  bool kill(String id) {
    final j = _jobs[id];
    if (j == null || !j.running) return false;
    j.process?.kill(ProcessSignal.sigterm);
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (j.running) j.process?.kill(ProcessSignal.sigkill);
    });
    return true;
  }

  void killAll() {
    for (final j in _jobs.values) {
      if (j.running) j.process?.kill(ProcessSignal.sigkill);
    }
  }
}
