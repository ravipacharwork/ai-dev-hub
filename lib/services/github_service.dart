import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class GitHubException implements Exception {
  final int? status;
  final String message;
  GitHubException(this.message, [this.status]);
  @override
  String toString() => 'GitHub $status: $message';
}

class RepoRef {
  final String owner, repo;
  const RepoRef(this.owner, this.repo);
  String get path => '/repos/$owner/$repo';
}

class TreeEntry {
  final String path, type, sha; // type: blob | tree
  final int? size;
  TreeEntry(this.path, this.type, this.sha, this.size);
}

class FileToCommit {
  final String path;
  final String? text; // null + delete=true => remove file
  final List<int>? bytes; // binary content (images, jars, ...)
  final bool delete;
  const FileToCommit.write(this.path, String this.text)
      : bytes = null,
        delete = false;
  const FileToCommit.writeBytes(this.path, List<int> this.bytes)
      : text = null,
        delete = false;
  const FileToCommit.remove(this.path)
      : text = null,
        bytes = null,
        delete = true;
}

/// Auth: fine-grained PAT with Contents R/W, Actions R/W, Metadata R.
class GitHubService {
  final Dio _dio;
  GitHubService(String token, [Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.github.com',
              headers: {
                'Authorization': 'Bearer $token',
                'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28',
              },
              validateStatus: (_) => true,
            ));

  Dio get dio => _dio;

  T _ok<T>(Response r, {List<int> allow = const [200]}) {
    if (!allow.contains(r.statusCode)) {
      final m = r.data is Map ? (r.data['message'] ?? '') : '${r.data}';
      throw GitHubException('$m', r.statusCode);
    }
    return r.data as T;
  }

  // ---- Read ----------------------------------------------------------------

  /// Validates the token; returns the login name.
  Future<String> currentUser() async =>
      _ok<Map>(await _dio.get('/user'))['login'] as String;

  /// Blob sha if the file exists on [ref], else null (404).
  Future<String?> fileSha(RepoRef r, String path, String ref) async {
    final res = await _dio.get('${r.path}/contents/$path',
        queryParameters: {'ref': ref});
    if (res.statusCode == 404) return null;
    return _ok<Map>(res)['sha'] as String;
  }

  Future<List<Map<String, dynamic>>> listRepos({int perPage = 50}) async {
    final r = await _dio.get('/user/repos',
        queryParameters: {'per_page': perPage, 'sort': 'pushed'});
    return List<Map<String, dynamic>>.from(_ok<List>(r));
  }

  Future<String> defaultBranch(RepoRef r) async =>
      _ok<Map>(await _dio.get(r.path))['default_branch'] as String;

  /// Whole tree in one call (truncated=true for huge repos; page by directory then).
  Future<List<TreeEntry>> getTree(RepoRef r, String ref) async {
    final res = await _dio
        .get('${r.path}/git/trees/$ref', queryParameters: {'recursive': '1'});
    final j = _ok<Map>(res);
    return (j['tree'] as List)
        .map((e) => TreeEntry(e['path'], e['type'], e['sha'], e['size']))
        .toList();
  }

  /// Returns (content, blobSha). Contents API caps at 1 MB; use blobs for bigger.
  Future<(String, String)> readFile(RepoRef r, String path, String ref) async {
    final res = await _dio.get('${r.path}/contents/$path',
        queryParameters: {'ref': ref});
    final j = _ok<Map>(res);
    final text = utf8.decode(
        base64.decode((j['content'] as String).replaceAll('\n', '')));
    return (text, j['sha'] as String);
  }

  /// Fastest "clone": download the zipball; caller unzips into the workspace.
  Future<Uint8List> downloadZipball(RepoRef r, String ref) async {
    final res = await _dio.get<List<int>>('${r.path}/zipball/$ref',
        options: Options(responseType: ResponseType.bytes));
    if (res.statusCode != 200) {
      throw GitHubException('zipball failed', res.statusCode);
    }
    return Uint8List.fromList(res.data!);
  }

  // ---- Write ---------------------------------------------------------------

  /// Single-file commit (needs the current blob sha when updating).
  Future<void> putFile(RepoRef r,
      {required String path,
      required String content,
      required String message,
      required String branch,
      String? sha}) async {
    final res = await _dio.put('${r.path}/contents/$path', data: {
      'message': message,
      'content': base64.encode(utf8.encode(content)),
      'branch': branch,
      if (sha != null) 'sha': sha,
    });
    _ok<Map>(res, allow: [200, 201]);
  }

  /// Multi-file atomic commit + push via the Git Data API:
  /// blobs -> tree -> commit -> move branch ref. One commit for N changes.
  Future<String> commitFiles(RepoRef r,
      {required String branch,
      required String message,
      required List<FileToCommit> files}) async {
    final ref = _ok<Map>(await _dio.get('${r.path}/git/ref/heads/$branch'));
    final headSha = ref['object']['sha'] as String;
    final headCommit =
        _ok<Map>(await _dio.get('${r.path}/git/commits/$headSha'));
    final baseTree = headCommit['tree']['sha'] as String;

    final treeItems = <Map<String, dynamic>>[];
    for (final f in files) {
      if (f.delete) {
        treeItems.add({'path': f.path, 'mode': '100644', 'type': 'blob', 'sha': null});
        continue;
      }
      final blob = _ok<Map>(
          await _dio.post('${r.path}/git/blobs', data: {
            'content': base64.encode(f.bytes ?? utf8.encode(f.text!)),
            'encoding': 'base64',
          }),
          allow: [201]);
      treeItems.add({
        'path': f.path,
        'mode': '100644',
        'type': 'blob',
        'sha': blob['sha'],
      });
    }

    final tree = _ok<Map>(
        await _dio.post('${r.path}/git/trees',
            data: {'base_tree': baseTree, 'tree': treeItems}),
        allow: [201]);
    final commit = _ok<Map>(
        await _dio.post('${r.path}/git/commits', data: {
          'message': message,
          'tree': tree['sha'],
          'parents': [headSha],
        }),
        allow: [201]);
    _ok<Map>(await _dio.patch('${r.path}/git/refs/heads/$branch',
        data: {'sha': commit['sha']})); // fails if not fast-forward: good
    return commit['sha'] as String;
  }

  // ---- Git-like helpers (used by the terminal's `git` command) -------------

  /// Head commit sha of [branch].
  Future<String> branchSha(RepoRef r, String branch) async =>
      _ok<Map>(await _dio.get('${r.path}/git/ref/heads/$branch'))['object']['sha']
          as String;

  /// Creates `refs/heads/[name]` pointing at [fromSha].
  Future<void> createBranch(RepoRef r, String name, String fromSha) async {
    _ok<Map>(
        await _dio.post('${r.path}/git/refs',
            data: {'ref': 'refs/heads/$name', 'sha': fromSha}),
        allow: [201]);
  }

  /// Newest-first commit list: (sha, message, author, date).
  Future<List<(String, String, String, String)>> listCommits(RepoRef r, String ref,
      {int perPage = 10}) async {
    final res = await _dio.get('${r.path}/commits',
        queryParameters: {'sha': ref, 'per_page': perPage});
    return [
      for (final c in _ok<List>(res))
        (
          c['sha'] as String,
          ((c['commit']['message'] as String).split('\n').first),
          '${c['commit']['author']['name']}',
          '${c['commit']['author']['date']}',
        )
    ];
  }

  /// Raw bytes of one file at [ref] (works for blobs > 1 MB too).
  Future<Uint8List> readBytes(RepoRef r, String path, String ref) async {
    final res = await _dio.get<List<int>>('${r.path}/contents/$path',
        queryParameters: {'ref': ref},
        options: Options(
            responseType: ResponseType.bytes,
            headers: {'Accept': 'application/vnd.github.raw+json'}));
    if (res.statusCode != 200) {
      throw GitHubException('read failed: $path', res.statusCode);
    }
    return Uint8List.fromList(res.data!);
  }

  /// Jobs of a workflow run (id, name, conclusion, steps[]).
  Future<List<Map<String, dynamic>>> runJobs(RepoRef r, int runId) async {
    final res = await _dio.get('${r.path}/actions/runs/$runId/jobs',
        queryParameters: {'per_page': 30});
    return List<Map<String, dynamic>>.from(_ok<Map>(res)['jobs'] as List);
  }

  /// Newest runs of a workflow on a branch (any event).
  Future<List<Map<String, dynamic>>> latestRuns(RepoRef r,
      {required String workflowFile, required String branch, int perPage = 5}) async {
    final res = await _dio.get('${r.path}/actions/workflows/$workflowFile/runs',
        queryParameters: {'branch': branch, 'per_page': perPage});
    return List<Map<String, dynamic>>.from(_ok<Map>(res)['workflow_runs'] as List);
  }

  /// Plain-text log of one job. The API answers 302 to a signed URL: follow it
  /// manually so the GitHub token is never sent to the blob host.
  Future<String> jobLog(RepoRef r, int jobId) async {
    final first = await _dio.get('${r.path}/actions/jobs/$jobId/logs',
        options: Options(
            followRedirects: false,
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s < 400));
    final location = first.headers.value('location');
    if (location == null) return '${first.data ?? ''}';
    final res = await Dio().get<String>(location,
        options: Options(responseType: ResponseType.plain));
    return res.data ?? '';
  }

  /// Force-moves [branch] to [sha] (used by Undo). Callers must verify first
  /// that nobody else has pushed in the meantime.
  Future<void> resetBranch(RepoRef r, String branch, String sha) async {
    _ok<Map>(await _dio.patch('${r.path}/git/refs/heads/$branch',
        data: {'sha': sha, 'force': true}));
  }

  // ---- Actions -------------------------------------------------------------

  /// Dispatch returns 204 with NO run id -> BuildPoller finds the run via a
  /// correlation id embedded in the workflow's run-name.
  Future<void> dispatchWorkflow(RepoRef r,
      {required String workflowFile, // e.g. android-build.yml
      required String ref,
      Map<String, String> inputs = const {}}) async {
    final res = await _dio.post(
        '${r.path}/actions/workflows/$workflowFile/dispatches',
        data: {'ref': ref, 'inputs': inputs});
    if (res.statusCode != 204) {
      final m = res.data is Map ? res.data['message'] : res.data;
      throw GitHubException('dispatch failed: $m', res.statusCode);
    }
  }
}
