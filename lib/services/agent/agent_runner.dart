import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/models.dart';
import '../build_poller.dart';
import '../deliverables.dart';
import '../router_service.dart';
import 'agent_tools.dart';
import 'plan.dart';

/// What the chat screen renders while the agent works.
sealed class AgentEvent {}

class AgentText extends AgentEvent {
  final String delta;
  AgentText(this.delta);
}

class AgentToolStart extends AgentEvent {
  final String id, name, label;
  AgentToolStart(this.id, this.name, this.label);
}

class AgentToolDone extends AgentEvent {
  final String id, summary;
  final bool ok;
  final String? checkpoint; // undo point taken before this step, if any
  AgentToolDone(this.id, this.ok, this.summary, {this.checkpoint});
}

/// The checklist card: a full snapshot that replaces the previous one.
class AgentPlan extends AgentEvent {
  final PlanSnapshot plan;
  AgentPlan(this.plan);
}

class AgentBuild extends AgentEvent {
  final Stream<BuildStatus> status;
  AgentBuild(this.status);
}

class AgentDeliver extends AgentEvent {
  final List<Deliverable> items;
  AgentDeliver(this.items);
}

class AgentNotice extends AgentEvent {
  final String text;
  AgentNotice(this.text);
}

typedef Approver = Future<bool> Function(ApprovalRequest request);

class _Partial {
  String id = '', name = '', args = '';
}

/// Tool-calling loop: stream a reply, run any tool calls, feed results back,
/// repeat until the model answers without calling a tool.
class AgentRunner {
  static const _resultCap = 16000;

  final RouterService router;
  final Toolkit toolkit;
  final int maxSteps;
  final Duration? maxDuration; // wall-clock budget for the whole run
  final String? modeNote; // extra system instructions for Build / Autonomous

  /// Runs once per user request, returns the project-memory block (AGENTS.md)
  /// that is added to the system prompt. May be null or throw: it is optional.
  final Future<String?> Function()? beginRun;

  /// Polled before a run and after each tool result: text to tell the model
  /// about things that happened on their own (e.g. late preview errors).
  final String? Function()? notices;
  AgentRunner({
    required this.router,
    required this.toolkit,
    this.maxSteps = 10,
    this.maxDuration,
    this.modeNote,
    this.beginRun,
    this.notices,
  });

  bool _cancelled = false;
  Completer<void> _cancelSignal = Completer<void>();
  CancelToken _cancelToken = CancelToken();
  void cancel() {
    _cancelled = true;
    if (!_cancelToken.isCancelled) _cancelToken.cancel('Agent task cancelled by user');
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  Stream<AgentEvent> run({
    required List<Map<String, dynamic>> messages,
    required String model,
    required Approver approve,
    double? temperature,
    double? topP,
    int? maxTokens,
  }) async* {
    _cancelled = false;
    _cancelSignal = Completer<void>();
    _cancelToken = CancelToken();
    final started = DateTime.now();
    String? memory;
    try {
      memory = await beginRun?.call();
    } catch (_) {/* project memory is optional */}
    final parts = [
      toolkit.systemNote,
      if (memory != null && memory.isNotEmpty) memory,
      if (modeNote != null) modeNote!,
      if (notices?.call() case final String n) n,
    ];
    final note = parts.join('\n\n');
    final convo = <Map<String, dynamic>>[
      for (final m in messages) Map<String, dynamic>.of(m),
    ];
    if (convo.isNotEmpty && convo.first['role'] == 'system') {
      convo.first['content'] = '${convo.first['content']}\n\n$note';
    } else {
      convo.insert(0, {'role': 'system', 'content': note});
    }

    for (var step = 0; step < maxSteps; step++) {
      if (_cancelled) return;
      final limit = maxDuration;
      if (limit != null && DateTime.now().difference(started) > limit) {
        yield AgentNotice('Time budget of ${limit.inMinutes} min reached. Say "continue" to keep going.');
        return;
      }
      final req = ChatRequest(
        messages: convo,
        model: model,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        tools: toolkit.schemas,
      );

      final text = StringBuffer();
      final calls = <_Partial>[];
      final slotOf = <int, int>{}; // provider's tool_call index -> our slot

      try {
        await for (final payload in router.stream(req, cancel: _cancelToken)) {
        if (_cancelled) return;
        if (payload == '[DONE]') continue;
        final Map j;
        try {
          j = jsonDecode(payload) as Map;
        } catch (_) {
          continue;
        }
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is! Map) continue;

        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          text.write(c);
          yield AgentText(c);
        }

        final tcs = delta['tool_calls'];
        if (tcs is List) {
          for (var k = 0; k < tcs.length; k++) {
            final tc = tcs[k];
            if (tc is! Map) continue;
            final idx = tc['index'] is int ? tc['index'] as int : k;
            final id = tc['id'] is String ? tc['id'] as String : '';
            var slot = slotOf[idx];
            // Some providers reuse index 0 for every parallel call: a new id
            // on an occupied slot means a new call.
            if (slot == null ||
                (id.isNotEmpty && calls[slot].id.isNotEmpty && calls[slot].id != id)) {
              slot = calls.length;
              calls.add(_Partial());
              slotOf[idx] = slot;
            }
            final p = calls[slot];
            if (id.isNotEmpty) p.id = id;
            final fn = tc['function'];
            if (fn is Map) {
              final n = fn['name'];
              if (n is String && n.isNotEmpty) p.name = n;
              final a = fn['arguments'];
              if (a is String) p.args += a;
            }
          }
        }
        }
      } on DioException catch (e) {
        if (_cancelled && CancelToken.isCancel(e)) return;
        rethrow;
      }

      final done = [for (final p in calls) if (p.name.isNotEmpty) p];
      if (done.isEmpty) return; // plain answer: finished

      final callIds = [
        for (var i = 0; i < done.length; i++)
          done[i].id.isEmpty ? 'call_${step}_$i' : done[i].id,
      ];
      convo.add({
        'role': 'assistant',
        'content': text.toString(),
        'tool_calls': [
          for (var i = 0; i < done.length; i++)
            {
              'id': callIds[i],
              'type': 'function',
              'function': {
                'name': done[i].name,
                'arguments': done[i].args.isEmpty ? '{}' : done[i].args,
              },
            },
        ],
      });

      for (var i = 0; i < done.length; i++) {
        if (_cancelled) return;
        final id = callIds[i];
        final name = done[i].name;

        Map<String, dynamic> args;
        String? argErr;
        try {
          final d = jsonDecode(done[i].args.isEmpty ? '{}' : done[i].args);
          if (d is Map) {
            args = Map<String, dynamic>.from(d);
          } else {
            args = {};
            argErr = 'Arguments must be a JSON object.';
          }
        } catch (_) {
          args = {};
          argErr = 'Arguments were not valid JSON.';
        }

        yield AgentToolStart(id, name, toolkit.label(name, args));

        ToolResult res;
        if (argErr != null) {
          res = ToolResult(argErr, ok: false);
        } else {
          final ask = toolkit.approval(name, args);
          if (ask != null && !(await approve(ask))) {
            res = const ToolResult(
                'The user denied this action. Do not retry it; ask what they want instead.',
                ok: false);
          } else if (_cancelled) {
            return;
          } else {
            res = await toolkit.run(name, args);
          }
        }

        final build = res.build;
        if (build != null) yield AgentBuild(build);
        if (res.deliverables.isNotEmpty) yield AgentDeliver(res.deliverables);
        final plan = res.plan;
        if (plan != null) yield AgentPlan(plan);
        final settle = res.settle;
        if (settle != null) {
          // e.g. wait for the CI result so the model can read the log and fix.
          final waited = await Future.any<ToolResult?>([settle(), _cancelSignal.future.then((_) => null)]);
          if (waited == null || _cancelled) return;
          res = ToolResult(waited.content,
              ok: waited.ok, checkpoint: res.checkpoint, deliverables: waited.deliverables);
        }
        yield AgentToolDone(id, res.ok, _summary(res.content), checkpoint: res.checkpoint);
        final extra = notices?.call();
        final body = extra == null ? res.content : '${res.content}\n\n$extra';
        convo.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': body.length > _resultCap ? '${body.substring(0, _resultCap)}\n[truncated]' : body,
        });
      }
    }
    yield AgentNotice(
        'Stopped after $maxSteps tool rounds. Say "continue" if there is more to do.');
  }

  static String _summary(String s) {
    final first = s.split('\n').first.trim();
    return first.length > 120 ? '${first.substring(0, 120)}...' : first;
  }
}
