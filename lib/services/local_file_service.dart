import 'dart:convert';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

/// Android Storage Access Framework wrapper. No MANAGE_EXTERNAL_STORAGE needed:
/// the user grants a folder once; the grant is persisted across restarts.
///
/// NOTE: written against saf_util / saf_stream from memory. Verify method
/// names and signatures against the version you install; the surface is kept
/// small so you can swap in a MethodChannel (ACTION_OPEN_DOCUMENT_TREE +
/// DocumentFile) without touching callers.
class LocalFileService {
  final _util = SafUtil();
  final _stream = SafStream();

  /// Grant access to a project folder. Returns its tree URI (store it).
  Future<SafDocumentFile?> pickWorkspace() =>
      _util.pickDirectory(writePermission: true, persistablePermission: true);

  Future<List<SafDocumentFile>> list(String dirUri) => _util.list(dirUri);

  /// Resolve nested relative path (e.g. ['lib','main.dart']) under a tree URI.
  Future<SafDocumentFile?> resolve(String treeUri, List<String> segments) =>
      _util.child(treeUri, segments);

  Future<String> readText(String fileUri) async {
    final bytes = await _stream.readFileSync(fileUri);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Creates or overwrites `name` inside `dirUri`.
  Future<void> writeText(String dirUri, String name, String content,
      {String mime = 'text/plain'}) async {
    await _stream.writeFileSync(
      dirUri,
      name,
      mime,
      Uint8List.fromList(utf8.encode(content)),
      overwrite: true,
    );
  }

  Future<void> delete(String uri, {required bool isDir}) =>
      _util.delete(uri, isDir);

  /// Import a downloaded repo zip into the workspace (after unzip with package:archive):
  /// create directories with _util.mkdirp(treeUri, segments), then writeText/pasteLocalFile.
}
