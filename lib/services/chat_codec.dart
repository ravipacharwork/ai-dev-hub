import 'dart:convert';

class ChatMsg {
  final String role, text;
  const ChatMsg(this.role, this.text);
}

class ChatSession {
  final String title;
  final DateTime created;
  final List<ChatMsg> messages;
  const ChatSession(this.title, this.created, this.messages);
}

/// Export/import of chat sessions. JSON round-trips; Markdown is export-only.
class ChatCodec {
  static const _version = 1;

  static String toJson(List<ChatSession> sessions) =>
      const JsonEncoder.withIndent('  ').convert({
        'version': _version,
        'sessions': [
          for (final s in sessions)
            {
              'title': s.title,
              'created': s.created.toIso8601String(),
              'messages': [
                for (final m in s.messages) {'role': m.role, 'content': m.text}
              ],
            }
        ],
      });

  /// Throws FormatException on bad input; skips unknown roles.
  static List<ChatSession> fromJson(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map || j['sessions'] is! List) {
      throw const FormatException('Not an AI Dev Hub export');
    }
    return [
      for (final s in j['sessions'] as List)
        ChatSession(
          (s['title'] ?? 'Imported chat').toString(),
          DateTime.tryParse('${s['created']}') ?? DateTime.now(),
          [
            for (final m in (s['messages'] as List? ?? const []))
              if (m is Map && (m['role'] == 'user' || m['role'] == 'assistant'))
                ChatMsg(m['role'], '${m['content'] ?? ''}'),
          ],
        ),
    ];
  }

  static String toMarkdown(List<ChatSession> sessions) {
    final b = StringBuffer();
    for (final s in sessions) {
      b.writeln('# ${s.title}');
      b.writeln('_${s.created.toIso8601String()}_\n');
      for (final m in s.messages) {
        b.writeln('**${m.role == 'user' ? 'You' : 'Assistant'}**\n');
        b.writeln('${m.text}\n');
        b.writeln('---\n');
      }
    }
    return b.toString();
  }
}
