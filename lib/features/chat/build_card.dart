import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/build_poller.dart';

/// In-chat card driven by BuildPoller's status stream. Shows progress, then
/// one-tap download cards for the APK / source ZIP.
class BuildCard extends StatefulWidget {
  final Stream<BuildStatus> status;
  final Future<void> Function(BuildArtifact) onDownload; // download + unzip + install/open
  const BuildCard({super.key, required this.status, required this.onDownload});

  @override
  State<BuildCard> createState() => _BuildCardState();
}

class _BuildCardState extends State<BuildCard> {
  BuildStatus? _last;
  bool _buzzed = false;
  final _busy = <int>{};
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    widget.status.listen((s) {
      if (!mounted) return;
      setState(() => _last = s);
      final done = s.phase == BuildPhase.succeeded;
      if ((done || s.phase == BuildPhase.failed) && !_buzzed) {
        _buzzed = true;
        done ? Haptics.buildDone() : Haptics.error();
      }
    });
  }

  String get _title => switch (_last?.phase) {
        null || BuildPhase.dispatching => 'Starting build…',
        BuildPhase.queued => 'Queued on GitHub Actions',
        BuildPhase.running => 'Building…',
        BuildPhase.succeeded => 'Build complete',
        BuildPhase.failed => 'Build failed',
        BuildPhase.timedOut => 'Build timed out',
      };

  @override
  Widget build(BuildContext context) {
    final s = _last;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final phase = s?.phase;
    final active = s == null ||
        phase == BuildPhase.dispatching ||
        phase == BuildPhase.queued ||
        phase == BuildPhase.running;
    final good = phase == BuildPhase.succeeded;
    final bad = phase == BuildPhase.failed || phase == BuildPhase.timedOut;
    final tint = good
        ? const Color(0xFF30D158)
        : bad
            ? cs.error
            : cs.primary;
    return SoftCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Icon(
                good
                    ? Icons.check_rounded
                    : bad
                        ? Icons.error_outline_rounded
                        : Icons.construction_rounded,
                key: ValueKey(phase),
                color: tint,
                size: 21,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              if (s?.detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(s!.detail!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
            ]),
          ),
          if (s?.runUrl != null)
            IconButton(
                tooltip: 'Open on GitHub',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new_rounded, size: 19),
                onPressed: () => launchUrl(Uri.parse(s!.runUrl!))),
        ]),
        if (phase == BuildPhase.failed && s?.failureLog != null) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () {
              Haptics.toggle();
              setState(() => _showLog = !_showLog);
            },
            child: Row(children: [
              Icon(_showLog ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(_showLog ? 'Hide error log' : 'Show error log',
                  style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showLog
                ? Container(
                    margin: const EdgeInsets.only(top: 8),
                    constraints: const BoxConstraints(maxHeight: 220),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(s!.failureLog!,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11.5, height: 1.4)),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
        if (active) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: const LinearProgressIndicator(minHeight: 4),
          ),
        ],
        for (final a in s?.artifacts ?? const <BuildArtifact>[])
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Icon(a.looksLikeApk ? Icons.android_rounded : Icons.folder_zip_rounded,
                    color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text('${(a.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                        style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: a.expired || _busy.contains(a.id)
                      ? null
                      : () async {
                          Haptics.toggle();
                          setState(() => _busy.add(a.id));
                          try {
                            await widget.onDownload(a);
                          } finally {
                            if (mounted) setState(() => _busy.remove(a.id));
                          }
                        },
                  child: _busy.contains(a.id)
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(a.expired
                          ? 'Expired'
                          : a.looksLikeApk
                              ? 'Install'
                              : 'Download'),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
