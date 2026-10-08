import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'github_service.dart';

enum BuildPhase { dispatching, queued, running, succeeded, failed, timedOut }

class BuildArtifact {
  final int id;
  final String name;
  final int sizeBytes;
  final bool expired;
  final String downloadUrl; // archive_download_url (needs auth, 302 -> blob)
  BuildArtifact(this.id, this.name, this.sizeBytes, this.expired, this.downloadUrl);
  bool get looksLikeApk => name.toLowerCase().contains('apk');
}

class BuildStatus {
  final BuildPhase phase;
  final String? runUrl; // html_url for "View on GitHub"
  final List<BuildArtifact> artifacts;
  final String? detail;
  final String? failedStep; // "job > step" that broke the build
  final String? failureLog; // trimmed log the agent reads to fix the build
  const BuildStatus(this.phase,
      {this.runUrl,
      this.artifacts = const [],
      this.detail,
      this.failedStep,
      this.failureLog});

  bool get isFinal =>
      phase == BuildPhase.succeeded ||
      phase == BuildPhase.failed ||
      phase == BuildPhase.timedOut;

  /// What the model gets back from trigger_build / commit_changes.
  String get summaryForModel => switch (phase) {
        BuildPhase.succeeded =>
          'BUILD SUCCEEDED.${artifacts.isEmpty ? '' : ' Artifacts: ${artifacts.map((a) => a.name).join(', ')}.'}${runUrl == null ? '' : ' Run: $runUrl'}',
        BuildPhase.failed =>
          'BUILD FAILED at: ${failedStep ?? 'unknown step'}.${runUrl == null ? '' : ' Run: $runUrl'}\n--- build log (trimmed) ---\n${failureLog ?? detail ?? '(no log available)'}',
        BuildPhase.timedOut =>
          'The build did not finish in the wait window.${runUrl == null ? '' : ' Run: $runUrl'} Tell the user; do not retry blindly.',
        _ => 'Build still in progress.',
      };
}

/// Replayable view of a build: late listeners (the chat card) first receive
/// everything that already happened, then live updates. [finished] completes
/// with the final status so the agent can wait for the result.
class BuildTracker {
  final _events = <BuildStatus>[];
  final _ctrl = StreamController<BuildStatus>.broadcast(sync: true);
  final _done = Completer<BuildStatus>();

  Future<BuildStatus> get finished => _done.future;

  BuildTracker.follow(Stream<BuildStatus> source) {
    void emit(BuildStatus s) {
      _events.add(s);
      _ctrl.add(s);
      if (s.isFinal && !_done.isCompleted) _done.complete(s);
    }

    source.listen(
      emit,
      onError: (Object e) =>
          emit(BuildStatus(BuildPhase.failed, detail: 'Could not run the build: $e')),
      onDone: () {
        if (!_done.isCompleted) {
          emit(const BuildStatus(BuildPhase.failed, detail: 'Build stopped unexpectedly.'));
        }
        _ctrl.close();
      },
    );
  }

  Stream<BuildStatus> get stream => Stream<BuildStatus>.multi((c) {
        for (final e in _events) {
          c.add(e);
        }
        if (_ctrl.isClosed) {
          c.close();
          return;
        }
        final sub = _ctrl.stream.listen(c.add, onDone: c.close);
        c.onCancel = sub.cancel;
      });
}

/// Usage:
///   final id = BuildPoller.newCorrelationId();
///   poller.run(repo, workflowFile: 'android-build.yml', ref: 'main', correlationId: id)
///         .listen(updateChatCard);
///
/// The workflow must declare:
///   on: workflow_dispatch: inputs: { correlation_id: {required: true} }
///   run-name: build ${{ inputs.correlation_id }}
class BuildPoller {
  final GitHubService gh;
  BuildPoller(this.gh);

  static String newCorrelationId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Stream<BuildStatus> run(
    RepoRef repo, {
    required String workflowFile,
    required String ref,
    required String correlationId,
    Map<String, String> extraInputs = const {},
    Duration interval = const Duration(seconds: 5),
    Duration timeout = const Duration(minutes: 30),
  }) async* {
    yield const BuildStatus(BuildPhase.dispatching);
    final startedAt = DateTime.now().toUtc().subtract(const Duration(seconds: 30));
    await gh.dispatchWorkflow(repo,
        workflowFile: workflowFile,
        ref: ref,
        inputs: {'correlation_id': correlationId, ...extraInputs});

    final deadline = DateTime.now().add(timeout);
    int? runId;
    String? runUrl;
    var last = '';

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      try {
        if (runId == null) {
          final found = await _findRun(repo, workflowFile, correlationId, startedAt);
          if (found == null) {
            if (last != 'queued') {
              last = 'queued';
              yield const BuildStatus(BuildPhase.queued);
            }
            continue;
          }
          runId = found['id'] as int;
          runUrl = found['html_url'] as String?;
        }

        final run = (await gh.dio.get('${repo.path}/actions/runs/$runId')).data
            as Map<String, dynamic>;
        final status = run['status'] as String; // queued|in_progress|completed
        if (status != 'completed') {
          final phase = status == 'queued' ? BuildPhase.queued : BuildPhase.running;
          if (last != status) {
            last = status;
            yield BuildStatus(phase, runUrl: runUrl);
          }
          continue;
        }

        final ok = run['conclusion'] == 'success';
        if (!ok) {
          final d = await failureDigest(repo, runId);
          yield BuildStatus(BuildPhase.failed,
              runUrl: runUrl,
              detail: d.step ?? 'Conclusion: ${run['conclusion']}',
              failedStep: d.step,
              failureLog: d.log);
          return;
        }
        yield BuildStatus(BuildPhase.succeeded,
            runUrl: runUrl, artifacts: await listArtifacts(repo, runId));
        return;
      } on DioException {
        continue; // transient network blip: keep polling until deadline
      }
    }
    yield BuildStatus(BuildPhase.timedOut, runUrl: runUrl);
  }

  /// Finds the failed job/step of a run and returns the useful end of its log.
  Future<({String? step, String? log})> failureDigest(RepoRef repo, int runId) async {
    try {
      final jobs = await gh.runJobs(repo, runId);
      Map<String, dynamic>? bad;
      for (final j in jobs) {
        if (j['conclusion'] == 'failure') {
          bad = j;
          break;
        }
      }
      bad ??= jobs.isNotEmpty ? jobs.first : null;
      if (bad == null) return (step: null, log: null);
      var step = '${bad['name']}';
      for (final s in (bad['steps'] as List? ?? const [])) {
        if (s is Map && s['conclusion'] == 'failure') {
          step = '${bad['name']} > ${s['name']}';
          break;
        }
      }
      final raw = await gh.jobLog(repo, bad['id'] as int);
      return (step: step, log: trimLog(raw));
    } catch (e) {
      return (step: null, log: 'Could not fetch the log: $e');
    }
  }

  /// Strips ANSI codes and timestamps; keeps early error lines plus the tail,
  /// where build tools print their summary.
  static String trimLog(String raw, {int maxChars = 6000}) {
    final ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
    final ts = RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ');
    final lines = [
      for (final l in raw.split('\n')) l.replaceAll(ansi, '').replaceFirst(ts, '').trimRight()
    ];
    final hit = RegExp(
        r'error|failed|exception|FAILURE|could not|cannot find|not found|undefined|unexpected',
        caseSensitive: false);
    const tailN = 70;
    final cut = lines.length > tailN ? lines.length - tailN : 0;
    final early = <String>[];
    for (var i = 0; i < cut && early.length < 25; i++) {
      if (hit.hasMatch(lines[i])) early.add(lines[i]);
    }
    final out = [
      if (early.isNotEmpty) ...['--- earlier error lines ---', ...early, '--- last lines ---'],
      ...lines.sublist(cut),
    ].join('\n');
    return out.length > maxChars ? '...${out.substring(out.length - maxChars)}' : out;
  }

  Future<Map<String, dynamic>?> _findRun(
      RepoRef repo, String wf, String cid, DateTime since) async {
    final res = await gh.dio.get('${repo.path}/actions/workflows/$wf/runs',
        queryParameters: {'event': 'workflow_dispatch', 'per_page': 20});
    final runs = (res.data['workflow_runs'] as List).cast<Map<String, dynamic>>();
    for (final r in runs) {
      final created = DateTime.parse(r['created_at'] as String);
      final title = '${r['display_title']} ${r['name']}';
      if (created.isAfter(since) && title.contains(cid)) return r;
    }
    return null;
  }

  Future<List<BuildArtifact>> listArtifacts(RepoRef repo, int runId) async {
    final res = await gh.dio.get('${repo.path}/actions/runs/$runId/artifacts');
    return (res.data['artifacts'] as List)
        .map((a) => BuildArtifact(a['id'], a['name'], a['size_in_bytes'],
            a['expired'] == true, a['archive_download_url']))
        .toList();
  }

  /// Artifacts arrive as a ZIP (APK inside). The URL 302s to blob storage;
  /// follow it manually so the GitHub token is NOT forwarded to the CDN.
  Future<Uint8List> downloadArtifactZip(BuildArtifact a,
      {void Function(int received, int total)? onProgress}) async {
    final first = await gh.dio.get(a.downloadUrl,
        options: Options(
            followRedirects: false,
            validateStatus: (s) => s != null && s < 400));
    final location = first.headers.value('location');
    if (location == null) throw GitHubException('no redirect for artifact');
    final res = await Dio().get<List<int>>(location,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress);
    return Uint8List.fromList(res.data!);
  }
  // Then: unzip with package:archive, write the .apk to app-private storage,
  // and open with open_filex (needs REQUEST_INSTALL_PACKAGES + FileProvider).
}
