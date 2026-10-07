import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/models.dart';
import 'keep_alive.dart';
import 'router_service.dart';

/// Telegram bot connector. Long-polls the Bot API (no public server needed),
/// answers each text message through the same router the chat uses, and keeps
/// the Android foreground service alive while running.
///
/// Only [allowedChatId] is answered, so a leaked bot username cannot spend
/// your provider keys. Leave it null to learn it from the first message
/// (shown via [onUnknownChat]) rather than answering strangers.
class TelegramBridge {
  final RouterService router;
  final String systemPrompt;
  TelegramBridge({required this.router, required this.systemPrompt});

  final _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45)));

  String? _token;
  int? allowedChatId;
  void Function(int chatId, String name)? onUnknownChat;
  void Function(String status)? onStatus;

  bool _running = false;
  bool get running => _running;
  int _offset = 0;
  final _history = <int, List<Map<String, dynamic>>>{};

  String get _base => 'https://api.telegram.org/bot$_token';

  Future<void> start(String token, {int? chatId}) async {
    if (_running) return;
    _token = token;
    allowedChatId = chatId;
    _running = true;
    await KeepAlive.acquire('Telegram bot online');
    onStatus?.call('Online');
    unawaited(_loop());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await KeepAlive.release();
    onStatus?.call('Stopped');
  }

  Future<void> _loop() async {
    var backoff = 2;
    while (_running) {
      try {
        final r = await _dio.get('$_base/getUpdates',
            queryParameters: {'offset': _offset, 'timeout': 30});
        backoff = 2;
        final updates = (r.data['result'] as List?) ?? const [];
        for (final u in updates) {
          _offset = (u['update_id'] as int) + 1;
          await _handle(u as Map);
        }
      } catch (e) {
        onStatus?.call('Reconnecting…');
        await Future<void>.delayed(Duration(seconds: backoff));
        backoff = (backoff * 2).clamp(2, 60);
      }
    }
  }

  Future<void> _handle(Map u) async {
    final m = u['message'] as Map?;
    final text = m?['text'] as String?;
    if (m == null || text == null) return;
    final chat = m['chat'] as Map;
    final id = chat['id'] as int;
    if (allowedChatId == null || id != allowedChatId) {
      onUnknownChat?.call(id, '${chat['first_name'] ?? chat['title'] ?? id}');
      return; // never answer chats the owner has not approved
    }
    final h = _history.putIfAbsent(id, () => []);
    h.add({'role': 'user', 'content': text});
    if (h.length > 20) h.removeRange(0, h.length - 20);

    final buf = StringBuffer();
    try {
      await for (final p in router.stream(ChatRequest(messages: [
        {'role': 'system', 'content': systemPrompt},
        ...h,
      ]))) {
        if (p == '[DONE]') continue;
        try {
          final ch = (jsonDecode(p) as Map)['choices'] as List?;
          final c = ((ch?.first as Map?)?['delta'] as Map?)?['content'];
          if (c is String) buf.write(c);
        } catch (_) {}
      }
    } catch (e) {
      buf.write('Sorry, no model could answer right now.');
    }
    final reply = buf.toString().trim();
    if (reply.isEmpty) return;
    h.add({'role': 'assistant', 'content': reply});
    // Telegram caps messages at 4096 characters.
    for (var i = 0; i < reply.length; i += 4000) {
      await _dio.post('$_base/sendMessage', data: {
        'chat_id': id,
        'text': reply.substring(i, (i + 4000).clamp(0, reply.length)),
      });
    }
  }
}
