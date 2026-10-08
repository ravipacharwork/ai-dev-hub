import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/agent/plan.dart';

/// The task checklist the agent keeps up to date while it works. Tap the
/// header to collapse it. Re-built with every new [PlanSnapshot].
class PlanCard extends StatefulWidget {
  final PlanSnapshot plan;
  const PlanCard({super.key, required this.plan});

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  bool _open = true;

  static const _green = Color(0xFF30D158);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final plan = widget.plan;
    final total = plan.steps.length;
    final frac = total == 0 ? 0.0 : plan.done / total;
    final tint = plan.finished
        ? _green
        : plan.hasFailed
            ? cs.error
            : cs.primary;

    return SoftCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Haptics.toggle();
            setState(() => _open = !_open);
          },
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tint.withOpacity(0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                  plan.finished ? Icons.task_alt_rounded : Icons.checklist_rounded,
                  color: tint,
                  size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(plan.title ?? 'Plan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Text('${plan.done}/$total',
                style: tt.labelLarge
                    ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: frac),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 4,
              color: tint,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(children: [
                    for (final s in plan.steps) _StepRow(step: s),
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

class _StepRow extends StatelessWidget {
  final PlanStep step;
  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = step.state;
    final Widget icon = switch (s) {
      StepState.done =>
        const Icon(Icons.check_circle_rounded, size: 20, color: Color(0xFF30D158)),
      StepState.failed => Icon(Icons.cancel_rounded, size: 20, color: cs.error),
      StepState.active => SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: cs.primary)),
      StepState.pending =>
        Icon(Icons.radio_button_unchecked_rounded, size: 20, color: cs.outline),
    };
    final muted = s == StepState.pending || s == StepState.done;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Center(
              child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: KeyedSubtree(key: ValueKey(s), child: icon))),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(step.title,
                style: TextStyle(
                    fontSize: 14,
                    height: 1.3,
                    fontWeight: s == StepState.active ? FontWeight.w600 : FontWeight.w400,
                    color: muted ? cs.onSurfaceVariant : cs.onSurface)),
          ),
        ),
      ]),
    );
  }
}
