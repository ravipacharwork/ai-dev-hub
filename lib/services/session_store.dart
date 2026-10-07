import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'chat_codec.dart';

/// Persists chat sessions as one JSON file in app-private storage.
class SessionStore {
  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/sessions.json');

  Future<List<ChatSession>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return ChatCodec.fromJson(await f.readAsString());
    } catch (_) {
      return []; // corrupt file: start fresh rather than crash on launch
    }
  }

  Future<void> save(List<ChatSession> sessions) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(ChatCodec.toJson(sessions));
    await tmp.rename(f.path); // atomic-ish: never leaves a half-written file
  }
}
