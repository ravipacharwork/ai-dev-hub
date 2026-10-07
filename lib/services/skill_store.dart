import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A reusable instruction block the user can switch on/off. Enabled skills are
/// appended to the system prompt of every chat.
class Skill {
  final String id;
  String name;
  String instructions;
  bool enabled;

  /// Set for skills imported from GitHub (used to detect updates).
  String? sourceRepo, sourcePath, sourceSha;

  Skill(this.id, this.name, this.instructions,
      {this.enabled = true, this.sourceRepo, this.sourcePath, this.sourceSha});

  bool get fromGitHub => sourceRepo != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'instructions': instructions,
        'enabled': enabled,
        if (sourceRepo != null) 'sourceRepo': sourceRepo,
        if (sourcePath != null) 'sourcePath': sourcePath,
        if (sourceSha != null) 'sourceSha': sourceSha,
      };

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
      j['id'].toString(), '${j['name']}', '${j['instructions']}',
      enabled: j['enabled'] != false,
      sourceRepo: j['sourceRepo'] as String?,
      sourcePath: j['sourcePath'] as String?,
      sourceSha: j['sourceSha'] as String?);
}

class SkillStore extends ChangeNotifier {
  static const _key = 'skills_v1';
  List<Skill> skills = [];
  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString(_key);
    if (raw == null) {
      skills = [
        Skill('code-review', 'Code reviewer',
            'When shown code, review it for bugs, security issues and clarity before suggesting changes.',
            enabled: false),
        Skill('concise', 'Concise answers',
            'Keep answers short and direct. Skip preambles and avoid repeating the question.',
            enabled: false),
      ];
      await _save();
      return;
    }
    try {
      skills = [
        for (final j in jsonDecode(raw) as List) Skill.fromJson(j as Map<String, dynamic>)
      ];
    } catch (_) {
      skills = [];
    }
  }

  Future<void> _save() async {
    await _p.setString(_key, jsonEncode([for (final s in skills) s.toJson()]));
    notifyListeners();
  }

  Future<void> add(String name, String instructions) {
    skills.add(Skill(DateTime.now().microsecondsSinceEpoch.toString(), name, instructions));
    return _save();
  }

  Future<void> update(Skill s, String name, String instructions) {
    s.name = name;
    s.instructions = instructions;
    return _save();
  }

  Future<void> setEnabled(Skill s, bool v) {
    s.enabled = v;
    return _save();
  }

  Skill? findBySource(String repo, String path) {
    for (final s in skills) {
      if (s.sourceRepo == repo && s.sourcePath == path) return s;
    }
    return null;
  }

  /// Add (or refresh) a skill imported from GitHub. A new import starts OFF:
  /// its text goes into every prompt, so the user turns it on deliberately.
  /// Re-importing keeps the user's on/off choice.
  Future<Skill> importRemote(
      {required String repo,
      required String path,
      required String sha,
      required String name,
      required String instructions}) {
    final existing = findBySource(repo, path);
    if (existing != null) {
      existing
        ..name = name
        ..instructions = instructions
        ..sourceSha = sha;
      return _save().then((_) => existing);
    }
    final sk = Skill('gh:$repo/$path', name, instructions,
        enabled: false, sourceRepo: repo, sourcePath: path, sourceSha: sha);
    skills.add(sk);
    return _save().then((_) => sk);
  }

  Future<void> remove(Skill s) {
    skills.remove(s);
    return _save();
  }

  /// Text to append to the system prompt (empty when no skill is on).
  String get promptAddendum {
    final on = skills.where((s) => s.enabled && s.instructions.trim().isNotEmpty);
    if (on.isEmpty) return '';
    return '\n\nActive skills:\n${[for (final s in on) '- ${s.name}: ${s.instructions.trim()}'].join('\n')}';
  }
}
