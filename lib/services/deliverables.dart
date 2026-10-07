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
