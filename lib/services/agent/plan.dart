import 'agent_tools.dart';

enum StepState { pending, active, done, failed }

class PlanStep {
  final String title;
  final StepState state;
  const PlanStep(this.title, this.state);
}

/// What the plan card in the chat shows. A new snapshot replaces the old one.
class PlanSnapshot {
  final String? title;
  final List<PlanStep> steps;
  const PlanSnapshot(this.title, this.steps);

  int get done => steps.where((s) => s.state == StepState.done).length;
  bool get hasFailed => steps.any((s) => s.state == StepState.failed);
  bool get finished => steps.isNotEmpty && done == steps.length;
}

/// `update_plan`: the model keeps a visible checklist (Devin / Manus style).
/// It is a pure UI tool: nothing leaves the device and no approval is needed.
class PlanToolkit implements Toolkit {
  static const maxSteps = 15;

  @override
  List<Map<String, dynamic>> get schemas => [
        {
          'type': 'function',
          'function': {
            'name': 'update_plan',
            'description':
                'Show or update the task checklist the user sees in the chat. Send the COMPLETE list every time (not a diff). Call it first for any task with 3 or more steps, then again whenever a step starts, finishes or fails.',
            'parameters': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string', 'description': 'Short plan title, e.g. "Add dark mode"'},
                'steps': {
                  'type': 'array',
                  'description': 'Ordered steps, at most $maxSteps',
                  'items': {
                    'type': 'object',
                    'properties': {
                      'title': {'type': 'string', 'description': 'Short step, imperative, under 60 chars'},
                      'status': {
                        'type': 'string',
                        'description': 'pending, active, done or failed',
                      },
                    },
                    'required': ['title', 'status'],
                  },
                },
              },
              'required': ['steps'],
            },
          },
        },
      ];

  @override
  String get systemNote =>
      '''Planning: for any task with 3 or more steps, call update_plan FIRST with the full checklist (all steps "pending", the first one "active"). Call it again every time a step starts or finishes: exactly one step "active", finished steps "done", a step that could not be completed "failed". Keep steps short and concrete. Do not repeat the checklist in your messages; the user already sees it as a card. Skip the plan for one-step requests.''';

  @override
  String label(String name, Map<String, dynamic> args) => 'Updating plan';

  @override
  ApprovalRequest? approval(String name, Map<String, dynamic> args) => null;

  @override
  Future<ToolResult> run(String name, Map<String, dynamic> args) async {
    final raw = args['steps'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult('"steps" must be a non-empty array.', ok: false);
    }
    final steps = <PlanStep>[];
    for (final s in raw.take(maxSteps)) {
      if (s is! Map) continue;
      final t = '${s['title'] ?? ''}'.trim();
      if (t.isEmpty) continue;
      final st = switch ('${s['status'] ?? 'pending'}'.toLowerCase().trim()) {
        'done' || 'completed' || 'complete' => StepState.done,
        'active' || 'in_progress' || 'running' || 'current' => StepState.active,
        'failed' || 'error' || 'blocked' => StepState.failed,
        _ => StepState.pending,
      };
      steps.add(PlanStep(t.length > 90 ? '${t.substring(0, 90)}...' : t, st));
    }
    if (steps.isEmpty) return const ToolResult('No valid steps.', ok: false);
    final title = '${args['title'] ?? ''}'.trim();
    final snap = PlanSnapshot(title.isEmpty ? null : title, steps);
    final next = steps.where((s) => s.state == StepState.pending).length;
    return ToolResult(
        'Plan updated: ${snap.done}/${steps.length} done${next > 0 ? ', $next pending' : ''}. Carry on with the work.',
        plan: snap);
  }
}
