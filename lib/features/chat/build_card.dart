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
    final active = s == null ||
        s.phase == BuildPhase.dispatching ||
        s.phase == BuildPhase.queued ||
        s.phase == BuildPhase.running;
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              s?.phase == BuildPhase.succeeded
                  ? Icons.check_circle_rounded
                  : s?.phase == BuildPhase.failed || s?.phase == BuildPhase.timedOut
                      ? Icons.error_rounded
                      : Icons.construction_rounded,
              color: s?.phase == BuildPhase.succeeded
                  ? Colors.green
                  : s?.phase == BuildPhase.failed
                      ? Colors.red
                      : Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(_title, style: Theme.of(context).textTheme.titleSmall)),
          if (s?.runUrl != null)
            IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                onPressed: () => launchUrl(Uri.parse(s!.runUrl!))),
        ]),
        if (active) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 3),
        ],
        if (s?.detail != null) Text(s!.detail!),
        for (final a in s?.artifacts ?? const <BuildArtifact>[])
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(a.looksLikeApk ? Icons.android_rounded : Icons.folder_zip_rounded),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('${a.name}  ·  ${(a.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                      overflow: TextOverflow.ellipsis)),
              FilledButton.tonal(
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
                child: Text(a.expired
                    ? 'Expired'
                    : _busy.contains(a.id)
                        ? '…'
                        : a.looksLikeApk
                            ? 'Install'
                            : 'Download'),
              ),
            ]),
          ),
      ]),
    );
  }
}
