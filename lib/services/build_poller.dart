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
  const BuildStatus(this.phase,
      {this.runUrl, this.artifacts = const [], this.detail});
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
          yield BuildStatus(BuildPhase.failed,
              runUrl: runUrl, detail: 'Conclusion: ${run['conclusion']}');
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
