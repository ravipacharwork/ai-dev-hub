import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

enum DeliverableKind { code, html, zip, apk, image, file }

/// A file the assistant hands to the user inside the chat.
class Deliverable {
  final String name, path;
  final int size;
  final DeliverableKind kind;
  const Deliverable(this.name, this.path, this.size, this.kind);

  static const _langByExt = {
    'dart': 'dart', 'py': 'python', 'js': 'javascript', 'ts': 'typescript',
    'json': 'json', 'yaml': 'yaml', 'yml': 'yaml', 'md': 'markdown',
    'kt': 'kotlin', 'java': 'java', 'c': 'c', 'cpp': 'cpp', 'cs': 'cs',
    'go': 'go', 'rs': 'rust', 'sh': 'bash', 'css': 'css', 'xml': 'xml',
    'sql': 'sql', 'html': 'xml', 'txt': 'plaintext', 'csv': 'plaintext',
    'gradle': 'gradle', 'swift': 'swift', 'rb': 'ruby', 'php': 'php',
  };
  static const _images = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

  static String extOf(String name) {
    final e = p.extension(name).toLowerCase();
    return e.startsWith('.') ? e.substring(1) : e;
  }

  static DeliverableKind kindOf(String name) {
    final e = extOf(name);
    if (e == 'apk') return DeliverableKind.apk;
    if (e == 'zip') return DeliverableKind.zip;
    if (e == 'html' || e == 'htm') return DeliverableKind.html;
    if (_images.contains(e)) return DeliverableKind.image;
    if (_langByExt.containsKey(e)) return DeliverableKind.code;
    return DeliverableKind.file;
  }

  String get language => _langByExt[extOf(name)] ?? 'plaintext';

  static String extForLang(String lang) {
    final l = lang.toLowerCase();
    for (final e in _langByExt.entries) {
      if (e.value == l || e.key == l) return e.key;
    }
    return l == 'htm' ? 'html' : 'txt';
  }

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// What a live page reported while it ran.
typedef PreviewReport = ({bool loaded, List<String> errors});

/// The chat card of a live page reports its load state and JavaScript errors
/// here (keyed by the page file path), so the tool that showed the page can
/// hand them to the model instead of only showing them to the user.
class PreviewReports {
  PreviewReports._();
  static final instance = PreviewReports._();

  static const maxErrors = 20;
  final _errors = <String, List<String>>{};
  final _loaded = <String>{};

  final _seen = <String, int>{}; // errors already handed to the model, per page
  final _drivers = <String, Future<void> Function(String js)>{};

  void loaded(String key) => _loaded.add(key);

  /// The card registers a way to run JavaScript in its page (to click through it).
  void attach(String key, Future<void> Function(String js) run) => _drivers[key] = run;

  /// Runs [js] in the page. False when the card is not showing it.
  Future<bool> run(String key, String js) async {
    final d = _drivers[key];
    if (d == null) return false;
    try {
      await d(js);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Errors from pages the model already checked that arrived since (for
  /// example after the user clicked something). Null when there are none.
  String? takeLateNote() {
    final fresh = <String>[];
    for (final key in _seen.keys.toList()) {
      final l = _errors[key] ?? const <String>[];
      final n = _seen[key]!;
      if (l.length > n) {
        fresh.addAll(l.sublist(n));
        _seen[key] = l.length;
      }
    }
    if (fresh.isEmpty) return null;
    return 'NOTE: the live preview reported new JavaScript errors after your last check '
        '(likely after the user interacted with it):\n${fresh.take(10).map((e) => '- $e').join('\n')}\n'
        'If it matters for the task, fix the cause and call preview_html again.';
  }

  void error(String key, String message) {
    final l = _errors.putIfAbsent(key, () => []);
    if (l.length < maxErrors && !l.contains(message)) l.add(message);
  }

  void reset(String key) {
    _errors.remove(key);
    _loaded.remove(key);
  }

  /// Waits until the page has loaded and [grace] more has passed (scripts run
  /// and fail soon after load), or until [timeout]. `loaded` is false when the
  /// card never showed the page (for example the user left the chat).
  Future<PreviewReport> wait(String key,
      {Duration timeout = const Duration(seconds: 12),
      Duration grace = const Duration(milliseconds: 2500)}) async {
    final end = DateTime.now().add(timeout);
    DateTime? loadedAt;
    while (DateTime.now().isBefore(end)) {
      if (_loaded.contains(key)) {
        loadedAt ??= DateTime.now();
        if (DateTime.now().difference(loadedAt) >= grace) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final errors = List<String>.of(_errors[key] ?? const []);
    _seen[key] = errors.length; // from now on only newer errors count as "late"
    return (loaded: _loaded.contains(key), errors: errors);
  }
}

/// Saves deliverables under <root>/<timestamp>/<name>, inside the app sandbox.
class DeliveryStore {
  final Future<Directory> Function() root;
  DeliveryStore(this.root);

  static const maxTextBytes = 5 * 1024 * 1024;
  static const maxZipBytes = 100 * 1024 * 1024;

  /// Keep only a plain file name: no folders, no "..", no odd characters.
  static String cleanName(String raw, [String fallback = 'file.txt']) {
    var n = p.basename(raw.replaceAll('\\', '/')).replaceAll(RegExp(r'[^\w.\- ]'), '_').trim();
    if (n.isEmpty || n == '.' || n == '..') n = fallback;
    return n;
  }

  /// Zip entry path: relative, forward slashes, no "..". Null if unusable.
  static String? cleanEntry(String raw) {
    final parts = raw
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (parts.isEmpty || parts.contains('..')) return null;
    return parts.join('/');
  }

  Future<File> _slot(String name) async {
    final dir = Directory(p.join((await root()).path, '${DateTime.now().microsecondsSinceEpoch}'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, name));
  }

  Future<Deliverable> _done(File f, String name) async =>
      Deliverable(name, f.path, await f.length(), Deliverable.kindOf(name));

  Future<Deliverable> saveText(String name, String content) async {
    final n = cleanName(name);
    final f = await _slot(n);
    await f.writeAsString(content);
    return _done(f, n);
  }

  Future<Deliverable> saveBytes(String name, List<int> bytes) async {
    final n = cleanName(name, 'file.bin');
    final f = await _slot(n);
    await f.writeAsBytes(bytes);
    return _done(f, n);
  }

  /// [files]: entry path -> text content.
  Future<Deliverable> zipText(String name, Map<String, String> files) async {
    final a = Archive();
    for (final e in files.entries) {
      final path = cleanEntry(e.key);
      if (path == null) throw ArgumentError('Bad path in zip: "${e.key}"');
      final bytes = utf8.encode(e.value);
      a.addFile(ArchiveFile(path, bytes.length, bytes));
    }
    return _writeZip(name, a);
  }

  /// Copy a file as-is, or zip a folder (max 2000 files / 100 MB).
  Future<Deliverable> adopt(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      final f = File(path);
      if (await f.length() > maxZipBytes) throw StateError('File is over 100 MB.');
      final n = cleanName(p.basename(path), 'file');
      final out = await _slot(n);
      await f.copy(out.path);
      return _done(out, n);
    }
    if (type == FileSystemEntityType.directory) {
      final a = Archive();
      var count = 0, total = 0;
      await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (++count > 2000) throw StateError('Folder has more than 2000 files.');
        final bytes = await e.readAsBytes();
        total += bytes.length;
        if (total > maxZipBytes) throw StateError('Folder is over 100 MB.');
        a.addFile(ArchiveFile(p.relative(e.path, from: path).replaceAll('\\', '/'), bytes.length, bytes));
      }
      return _writeZip('${cleanName(p.basename(path), 'folder')}.zip', a);
    }
    throw StateError('Not found: $path');
  }

  Future<Deliverable> _writeZip(String name, Archive a) async {
    var n = cleanName(name, 'archive.zip');
    if (!n.toLowerCase().endsWith('.zip')) n = '$n.zip';
    final data = ZipEncoder().encode(a);
    if (data == null) throw StateError('Could not create zip.');
    final f = await _slot(n);
    await f.writeAsBytes(data);
    return _done(f, n);
  }
}
