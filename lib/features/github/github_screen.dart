import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/github_service.dart';
import '../../services/secure_store.dart';

class RepoSelection {
  final RepoRef repo;
  final String branch;
  final String workflowFile;
  const RepoSelection(this.repo, this.branch, this.workflowFile);

  String encode() => '${repo.owner}/${repo.repo}|$branch|$workflowFile';
  static RepoSelection? decode(String? s) {
    if (s == null) return null;
    final parts = s.split('|');
    final or = parts[0].split('/');
    if (parts.length != 3 || or.length != 2) return null;
    return RepoSelection(RepoRef(or[0], or[1]), parts[1], parts[2]);
  }
}

/// Connect with a fine-grained PAT (Contents R/W, Actions R/W, Metadata R),
/// pick a repo, and make sure it has the build workflow.
class GitHubScreen extends StatefulWidget {
  final SecureStore store;
  /// Called whenever token validated and/or repo chosen, so the app can
  /// (re)create GitHubService + BuildPoller.
  final void Function(GitHubService gh, RepoSelection? selection) onChanged;
  const GitHubScreen({super.key, required this.store, required this.onChanged});

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  static const _workflowFile = 'android-build.yml';
  final _token = TextEditingController();
  final _filter = TextEditingController();
  bool _show = false, _busy = false;
  String? _login, _error, _info;
  GitHubService? _gh;
  List<Map<String, dynamic>> _repos = [];
  RepoSelection? _sel;

  @override
  void initState() {
    super.initState();
    () async {
      _sel = RepoSelection.decode(await widget.store.repoSelection());
      final t = await widget.store.githubToken();
      if (t != null && t.isNotEmpty) {
        _token.text = t;
        await _connect(silent: true);
      }
      if (mounted) setState(() {});
    }();
  }

  @override
  void dispose() {
    _token.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _connect({bool silent = false}) async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final gh = GitHubService(t);
      final login = await gh.currentUser();
      final repos = await gh.listRepos(perPage: 100);
      await widget.store.setGithubToken(t);
      _gh = gh;
      _login = login;
      _repos = repos;
      widget.onChanged(gh, _sel);
      if (!silent) Haptics.copy();
    } on GitHubException catch (e) {
      _error = e.status == 401 ? 'Token rejected (401). Check it and its expiry.' : '$e';
      if (!silent) Haptics.error();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    await widget.store.setGithubToken(null);
    setState(() {
      _gh = null;
      _login = null;
      _repos = [];
      _token.clear();
      _info = null;
    });
  }

  Future<void> _choose(Map<String, dynamic> r) async {
    final sel = RepoSelection(
        RepoRef(r['owner']['login'] as String, r['name'] as String),
        r['default_branch'] as String,
        _workflowFile);
    await widget.store.setRepoSelection(sel.encode());
    Haptics.toggle();
    setState(() {
      _sel = sel;
      _info = null;
    });
    widget.onChanged(_gh!, sel);
  }

  /// Commits assets/android-build.yml to .github/workflows/ if it's missing.
  Future<void> _installWorkflow() async {
    final sel = _sel, gh = _gh;
    if (sel == null || gh == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final path = '.github/workflows/$_workflowFile';
      final existing = await gh.fileSha(sel.repo, path, sel.branch);
      if (existing != null) {
        _info = 'Workflow already present.';
      } else {
        final yml = await rootBundle.loadString('assets/android-build.yml');
        await gh.putFile(sel.repo,
            path: path,
            content: yml,
            message: 'Add Android build workflow',
            branch: sel.branch);
        _info = 'Workflow added to ${sel.branch}. Builds can now be triggered from chat.';
        Haptics.buildDone();
      }
    } on GitHubException catch (e) {
      _error = e.status == 403 || e.status == 404
          ? 'No write access (${e.status}). The token needs Contents: Read & write on this repo. '
              'Workflow files may also need the "Workflows" permission.'
          : '$e';
      Haptics.error();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.toLowerCase();
    final repos = _repos
        .where((r) => (r['full_name'] as String).toLowerCase().contains(q))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('GitHub')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_login == null) ...[
              TextField(
                controller: _token,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Personal access token',
                  helperText: 'Fine-grained: Contents RW, Actions RW, Workflows RW, Metadata R',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Connect'),
              ),
            ] else
              Row(children: [
                const Icon(Icons.check_circle_rounded, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(child: Text('Connected as @$_login')),
                TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
              ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ),
          ]),
        ),
        if (_sel != null) ...[
          const SizedBox(height: 12),
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Active repo', style: Theme.of(context).textTheme.labelSmall),
              Text('${_sel!.repo.owner}/${_sel!.repo.repo}  ·  ${_sel!.branch}',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton.tonal(
                  onPressed: _busy || _gh == null ? null : _installWorkflow,
                  child: const Text('Add build workflow'),
                ),
              ]),
              if (_info != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_info!, style: const TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 4),
              Text(
                'The workflow builds a Flutter APK. Other project types need their own workflow file.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ],
        if (_login != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded), hintText: 'Filter repositories'),
          ),
          const SizedBox(height: 8),
          for (final r in repos)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Glass(
                padding: EdgeInsets.zero,
                radius: 14,
                child: ListTile(
                  dense: true,
                  title: Text(r['full_name'] as String, overflow: TextOverflow.ellipsis),
                  subtitle: Text(r['private'] == true ? 'Private' : 'Public'),
                  trailing: _sel?.repo.repo == r['name'] &&
                          _sel?.repo.owner == r['owner']['login']
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => _choose(r),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}
