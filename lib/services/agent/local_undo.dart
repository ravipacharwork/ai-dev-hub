import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:path/path.dart' as p;

import 'agent_tools.dart';

/// What to snapshot before a tool call that may change files outside the repo.
class UndoPlan {
  final String label; // shown in "Undo points": never put command text here
  final List<String> roots; // files or folders the call may touch
  final bool tree; // true = a whole folder (terminal workspace): skip .git etc.
  final bool onlyIfChanged; // drop the undo point when nothing changed afterwards
  final bool keepOnFail; // keep the undo point even if the tool reported failure
  const UndoPlan(this.label, this.roots,
      {this.tree = false, this.onlyIfChanged = false, this.keepOnFail = false});
}

class _Meta {
  final int size, mtimeMs;
  String? blob; // copy of the file as it was; null = too big / unreadable
  _Meta(this.size, this.mtimeMs, [this.blob]);
}

class _Scan {
  final files = <String, FileStat>{};
  final dirs = <String>{};
  bool truncated = false;
}

/// One undo point for files on the device.
class LocalEntry {
  final String id, label;
  final DateTime at;
  final List<String> roots;
  final bool tree;
  final files = <String, _Meta>{};
  final dirs = <String>{};
  bool complete = true; // false when the scan hit the file limit
  int skipped = 0; // files that could not be backed up
  LocalEntry(this.id, this.label, this.at, this.roots, this.tree);
}

/// A `git push` made by the shell: [branch] went from [before] to [after].
class PushRecord {
  final DateTime at;
  final String owner, repo, branch, before, after;
  PushRecord(this.at, this.owner, this.repo, this.branch, this.before, this.after);
}

/// Undo for files changed through the terminal and the device-file tools.
///
/// Before such a call the files it may touch are recorded (path, size, mtime)
/// and backed up. Files that did not change since an earlier snapshot are not
/// copied again, so a quiet workspace is cheap. Undo puts changed or deleted
/// files back and removes files created since.
///
/// Files created since a snapshot are not deleted outright: undo moves them to
/// `removed/` in the store, so nothing is lost for good (e.g. undoing fs_restore).
///
/// `git push` done by the shell is recorded as a [PushRecord]; undo moves the
/// branch back on GitHub, but only if nobody pushed after it.
///
/// Undo points survive an app restart: each entry is saved as JSON in
/// `index/` next to its backups and loaded again by [init].
///
/// Limits: a file over [_maxFile], or anything past [_maxTotal] in one
/// snapshot, is recorded but not backed up (undo reports it). Shell commands also
/// snapshot the /storage paths they name and the current folder (not the whole
/// phone), so a path built at run time inside a script can be missed.
class LocalUndoLog {
  // Generous limits: when the store gets too big the OLDEST undo points are
  // dropped first. A copy that fails (disk full) is reported, not hidden.
  static const _maxFile = 1024 * 1024 * 1024;
  static const _maxTotal = 2 * 1024 * 1024 * 1024;
  static const _maxStore = 4 * 1024 * 1024 * 1024;
  static const _maxFiles = 50000;
  static const maxEntries = 30;
  static const _skipDirs = {'.tmp'}; // scratch space of the shell, not user data

  final String storeDir;

  /// Set by the app: stops running background jobs before files are restored.
  Future<void> Function()? stopJobs;

  /// Set by the app: moves a branch back. Returns null on success, else why not.
  Future<String?> Function(PushRecord r)? undoPush;

  final List<LocalEntry> entries = [];
  final List<PushRecord> pushes = [];
  int _stashSeq = 0;
  final Map<String, _Meta> _latest = {}; // path -> newest backed-up version
  int _seq = 0, _blobSeq = 0;

  LocalUndoLog(this.storeDir);

  // ---- persistence ----------------------------------------------------------

  String get _indexDir => p.join(storeDir, 'index');

  Map<String, dynamic> _entryJson(LocalEntry e) => {
        'id': e.id,
        'label': e.label,
        'at': e.at.toIso8601String(),
        'roots': e.roots,
        'tree': e.tree,
        'complete': e.complete,
        'skipped': e.skipped,
        'dirs': e.dirs.toList(),
        'files': {
          for (final f in e.files.entries)
            f.key: [f.value.size, f.value.mtimeMs, if (f.value.blob != null) p.basename(f.value.blob!)],
        },
      };

  LocalEntry _entryFrom(Map<String, dynamic> j) {
    final e = LocalEntry(j['id'] as String, j['label'] as String, DateTime.parse(j['at'] as String),
        List<String>.from(j['roots'] as List), j['tree'] as bool);
    e.complete = j['complete'] as bool;
    e.skipped = j['skipped'] as int;
    e.dirs.addAll(List<String>.from(j['dirs'] as List));
    (j['files'] as Map).forEach((k, v) {
      final l = v as List;
      final blob = l.length > 2 ? p.join(storeDir, l[2] as String) : null;
      e.files[k as String] = _Meta(l[0] as int, l[1] as int, blob != null && File(blob).existsSync() ? blob : null);
    });
    return e;
  }

  Future<void> _save(LocalEntry e) async {
    try {
      await Directory(_indexDir).create(recursive: true);
      await File(p.join(_indexDir, '${e.id}.json')).writeAsString(jsonEncode(_entryJson(e)));
    } catch (_) {}
  }

  void _unsave(String id) {
    try {
      final f = File(p.join(_indexDir, '$id.json'));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _savePushes() async {
    try {
      await Directory(_indexDir).create(recursive: true);
      await File(p.join(_indexDir, 'pushes.json')).writeAsString(jsonEncode([
        for (final r in pushes)
          [r.at.toIso8601String(), r.owner, r.repo, r.branch, r.before, r.after],
      ]));
    } catch (_) {}
  }

  /// Call once at startup: loads the undo points saved by earlier runs.
  Future<void> init() async {
    try {
      await Directory(_indexDir).create(recursive: true);
      await for (final f in Directory(storeDir).list(followLinks: false)) {
        final m = f is File ? RegExp(r'^b(\d+)$').firstMatch(p.basename(f.path)) : null;
        if (m != null) _blobSeq = max(_blobSeq, int.parse(m.group(1)!));
      }
      final loaded = <LocalEntry>[];
      await for (final f in Directory(_indexDir).list(followLinks: false)) {
        if (f is! File || p.basename(f.path) == 'pushes.json' || !f.path.endsWith('.json')) continue;
        try {
          loaded.add(_entryFrom(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {
          await f.delete(); // unreadable: drop it
        }
      }
      loaded.sort((a, b) => a.at.compareTo(b.at));
      entries.addAll(loaded);
      for (final e in loaded) {
        _seq = max(_seq, int.tryParse(e.id.substring(2)) ?? 0);
        for (final f in e.files.entries) {
          if (f.value.blob != null) _latest[f.key] = f.value; // newest entry wins
        }
      }
      final pf = File(p.join(_indexDir, 'pushes.json'));
      if (await pf.exists()) {
        for (final r in jsonDecode(await pf.readAsString()) as List) {
          final l = r as List;
          pushes.add(PushRecord(DateTime.parse(l[0] as String), l[1] as String, l[2] as String,
              l[3] as String, l[4] as String, l[5] as String));
        }
      }
      _gc();
    } catch (_) {}
  }

  void recordPush(String owner, String repo, String branch, String before, String after) {
    pushes.add(PushRecord(DateTime.now(), owner, repo, branch, before, after));
    if (pushes.length > 30) pushes.removeAt(0);
    _savePushes();
  }

  /// The entries as plain checkpoints, so the existing undo UI shows them.
  List<Checkpoint> get checkpoints =>
      [for (final e in entries) Checkpoint(e.id, e.label, e.at, <String, String?>{}, null)];

  Future<_Scan> _scan(List<String> roots, bool tree) async {
    final s = _Scan();
    Future<void> visit(String path) async {
      if (s.files.length >= _maxFiles) {
        s.truncated = true;
        return;
      }
      final t = await FileSystemEntity.type(path, followLinks: false);
      if (t == FileSystemEntityType.file) {
        s.files[path] = await File(path).stat();
      } else if (t == FileSystemEntityType.directory) {
        s.dirs.add(path);
        try {
          await for (final e in Directory(path).list(followLinks: false)) {
            if (tree && _skipDirs.contains(p.basename(e.path))) continue;
            if (tree && p.dirname(e.path) == roots.first && p.basename(e.path) == 'bin') continue; // shell shims
            await visit(e.path);
          }
        } on FileSystemException {
          s.truncated = true; // could not read this folder: do not trust "created since"
        }
      }
    }

    for (final r in roots) {
      await visit(r);
    }
    return s;
  }

  /// Records and backs up [roots] before a change. Returns the new entry.
  Future<LocalEntry> capture(UndoPlan plan) async {
    final e = LocalEntry('lc${++_seq}', plan.label, DateTime.now(), plan.roots, plan.tree);
    final scan = await _scan(plan.roots, plan.tree);
    e.complete = !scan.truncated;
    var copied = 0;
    for (final f in scan.files.entries) {
      final st = f.value;
      final m = _Meta(st.size, st.modified.millisecondsSinceEpoch);
      final prev = _latest[f.key];
      if (prev != null &&
          prev.size == m.size &&
          prev.mtimeMs == m.mtimeMs &&
          prev.blob != null &&
          File(prev.blob!).existsSync()) {
        m.blob = prev.blob; // unchanged since the last snapshot
      } else if (st.size <= _maxFile && copied + st.size <= _maxTotal) {
        try {
          await Directory(storeDir).create(recursive: true);
          final b = p.join(storeDir, 'b${++_blobSeq}');
          await File(f.key).copy(b);
          m.blob = b;
          copied += st.size;
          _latest[f.key] = m;
        } catch (_) {
          e.skipped++;
        }
      } else {
        e.skipped++;
      }
      e.files[f.key] = m;
    }
    e.dirs.addAll(scan.dirs);
    entries.add(e);
    await _save(e);
    await _trim();
    return e;
  }

  bool _same(FileStat? cur, _Meta m) =>
      cur != null && cur.size == m.size && cur.modified.millisecondsSinceEpoch == m.mtimeMs;

  /// True when something under the entry's roots differs from the snapshot.
  Future<bool> changed(LocalEntry e) async {
    final now = await _scan(e.roots, e.tree);
    for (final path in now.files.keys) {
      if (!e.files.containsKey(path)) return true;
    }
    for (final en in e.files.entries) {
      if (!_same(now.files[en.key], en.value)) return true;
    }
    return now.dirs.length != e.dirs.length || !now.dirs.containsAll(e.dirs);
  }

  void drop(String id) {
    entries.removeWhere((e) => e.id == id);
    _unsave(id);
    _gc();
  }

  Future<void> _trim() async {
    var bytes = _storeBytes();
    while (entries.length > maxEntries || (bytes > _maxStore && entries.length > 1)) {
      _unsave(entries.removeAt(0).id);
      _gc();
      bytes = _storeBytes();
    }
  }

  Set<String> _referenced() => {
        for (final e in entries)
          for (final m in e.files.values)
            if (m.blob != null) m.blob!,
      };

  int _storeBytes() {
    final seen = <String>{};
    var total = 0;
    for (final e in entries) {
      for (final m in e.files.values) {
        if (m.blob != null && seen.add(m.blob!)) total += m.size;
      }
    }
    return total;
  }

  /// Deletes backup files no remaining entry points to.
  void _gc() {
    final keep = _referenced();
    _latest.removeWhere((_, m) => m.blob == null || !keep.contains(m.blob));
    try {
      final d = Directory(storeDir);
      if (!d.existsSync()) return;
      for (final f in d.listSync()) {
        if (f is File && !keep.contains(f.path)) f.deleteSync();
      }
    } catch (_) {}
  }

  /// Reverts every entry and push made at or after [at], newest first. Returns
  /// a short message for the user ('' when there was nothing to revert).
  Future<String> restoreFrom(DateTime at) async {
    final todo = [for (final e in entries.reversed) if (!e.at.isBefore(at)) e];
    final pushTodo = [for (final r in pushes.reversed) if (!r.at.isBefore(at)) r];
    if (todo.isEmpty && pushTodo.isEmpty) return '';
    try {
      await stopJobs?.call();
    } catch (_) {}
    final msgs = <String>[];
    for (final r in pushTodo) {
      String? why;
      try {
        why = await undoPush?.call(r) ?? (undoPush == null ? 'GitHub is not connected' : null);
      } catch (e) {
        why = '$e';
      }
      msgs.add(why == null
          ? 'Branch ${r.branch} moved back on GitHub.'
          : 'Could not move ${r.branch} back on GitHub: $why.');
    }
    pushes.removeWhere((r) => !r.at.isBefore(at));
    await _savePushes();
    var problems = 0;
    for (final e in todo) {
      problems += await _revert(e);
    }
    for (final e in todo) {
      _unsave(e.id);
    }
    entries.removeWhere((e) => !e.at.isBefore(at));
    _gc();
    if (todo.isNotEmpty) {
      msgs.add(problems == 0
          ? 'File changes on the device were put back.'
          : 'File changes were put back, except $problems file(s) that could not be backed up or read.');
    }
    return msgs.join(' ');
  }

  /// Moves [path] out of the way into the store (instead of deleting it).
  Future<void> _stash(String path) async {
    final dest = p.join(storeDir, 'removed', 'r${++_stashSeq}_${p.basename(path)}');
    await Directory(p.dirname(dest)).create(recursive: true);
    try {
      await File(path).rename(dest);
    } on FileSystemException {
      await File(path).copy(dest); // rename fails across file systems
      await File(path).delete();
    }
  }

  /// Puts one entry's files back. Returns how many files could not be restored.
  Future<int> _revert(LocalEntry e) async {
    var problems = e.skipped;
    final now = await _scan(e.roots, e.tree);
    final safeToDelete = e.complete && !now.truncated;

    // Files created since the snapshot.
    if (safeToDelete) {
      for (final path in now.files.keys) {
        if (e.files.containsKey(path)) continue;
        try {
          await _stash(path);
        } catch (_) {
          problems++;
        }
      }
    }

    // Files changed or deleted since the snapshot.
    for (final en in e.files.entries) {
      final path = en.key, m = en.value;
      if (_same(now.files[path], m) && now.files.containsKey(path)) continue;
      final b = m.blob;
      if (b == null || !File(b).existsSync()) continue; // already counted in e.skipped
      try {
        final t = await FileSystemEntity.type(path, followLinks: false);
        if (t == FileSystemEntityType.directory) {
          if (!safeToDelete) {
            problems++;
            continue;
          }
          await Directory(path).delete(recursive: true);
        }
        await Directory(p.dirname(path)).create(recursive: true);
        await File(b).copy(path);
        await File(path).setLastModified(DateTime.fromMillisecondsSinceEpoch(m.mtimeMs));
      } catch (_) {
        problems++;
      }
    }

    // Folders: bring back missing ones, remove empty ones created since.
    for (final d in e.dirs) {
      try {
        if (!now.dirs.contains(d)) await Directory(d).create(recursive: true);
      } catch (_) {}
    }
    if (safeToDelete) {
      final extra = now.dirs.where((d) => !e.dirs.contains(d)).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final d in extra) {
        try {
          final dir = Directory(d);
          if (dir.existsSync() && dir.listSync().isEmpty) await dir.delete();
        } catch (_) {}
      }
    }
    return problems;
  }
}

/// Wraps a toolkit so calls that change files on the device get an undo point.
class UndoToolkit implements Toolkit {
  final Toolkit inner;
  final LocalUndoLog log;
  final Future<UndoPlan?> Function(String name, Map<String, dynamic> args) plan;
  UndoToolkit(this.inner, this.log, this.plan);

  @override
  List<Map<String, dynamic>> get schemas => inner.schemas;
  @override
  String get systemNote => inner.systemNote;
  @override
  String label(String name, Map<String, dynamic> args) => inner.label(name, args);
  @override
  ApprovalRequest? approval(String name, Map<String, dynamic> args) => inner.approval(name, args);

  @override
  Future<ToolResult> run(String name, Map<String, dynamic> args) async {
    UndoPlan? pl;
    LocalEntry? e;
    try {
      pl = await plan(name, args);
      if (pl != null) e = await log.capture(pl);
    } catch (_) {/* no undo point for this call; the call itself still runs */}
    final r = await inner.run(name, args);
    if (e == null || pl == null) return r;
    try {
      if (pl.onlyIfChanged && !await log.changed(e)) {
        log.drop(e.id);
        return r;
      }
    } catch (_) {}
    if (!r.ok && !pl.keepOnFail) {
      log.drop(e.id);
      return r;
    }
    return r.withCheckpoint(e.id);
  }
}
