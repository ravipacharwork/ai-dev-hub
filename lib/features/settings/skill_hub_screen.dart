import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/skill_hub.dart';
import '../../services/skill_store.dart';

/// Browse, search and one-tap import skills from GitHub repos.
class SkillHubScreen extends StatefulWidget {
  final SkillHub hub;
  final SkillStore store;
  final bool connected;
  final VoidCallback onConnect;
  const SkillHubScreen({
    super.key,
    required this.hub,
    required this.store,
    required this.connected,
    required this.onConnect,
  });

  @override
  State<SkillHubScreen> createState() => _SkillHubScreenState();
}

class _SkillHubScreenState extends State<SkillHubScreen> {
  final _q = TextEditingController();
  final Set<String> _busy = {};
  SkillHub get hub => widget.hub;

  @override
  void initState() {
    super.initState();
    if (widget.connected) hub.syncAll(force: true);
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _snack(String m, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), action: action));
  }

  Future<void> _add(RemoteSkill r) async {
    setState(() => _busy.add(r.key));
    try {
      final wasNew = hub.statusOf(r) == SkillStatus.notAdded;
      final cut = await hub.add(r);
      Haptics.toggle();
      final sk = widget.store.findBySource(r.repo, r.path);
      _snack(
        '${wasNew ? 'Added' : 'Updated'} "${r.name}"${wasNew ? ' (off)' : ''}${cut ? ' - shortened to ${SkillHub.maxInstructionChars} chars' : ''}',
        action: wasNew && sk != null
            ? SnackBarAction(label: 'Turn on', onPressed: () => widget.store.setEnabled(sk, true))
            : null,
      );
    } catch (e) {
      Haptics.error();
      _snack('Could not add: $e');
    }
    if (mounted) setState(() => _busy.remove(r.key));
  }

  Future<void> _preview(RemoteSkill r) async {
    try {
      final f = await hub.fetch(r);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(f.name),
          content: SingleChildScrollView(
              child: SelectableText(f.body.length > 6000 ? '${f.body.substring(0, 6000)}\n…' : f.body,
                  style: const TextStyle(fontSize: 13))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _add(r);
                },
                child: const Text('Add')),
          ],
        ),
      );
    } catch (e) {
      _snack('Could not load: $e');
    }
  }

  Future<void> _addRepoDialog([String? initial]) async {
    final c = TextEditingController(text: initial ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add repository'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'owner/repo or owner/repo@branch'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    final v = c.text;
    c.dispose();
    if (ok != true) return;
    try {
      await hub.addRepo(v);
    } on FormatException {
      _snack('Use the form owner/repo');
    }
  }

  Widget _row(RemoteSkill r) {
    final st = hub.statusOf(r);
    final cs = Theme.of(context).colorScheme;
    final busy = _busy.contains(r.key);
    Widget action;
    if (busy) {
      action = const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (st == SkillStatus.added) {
      action = const Padding(
          padding: EdgeInsets.all(8), child: Icon(Icons.check_circle_rounded, color: Colors.green));
    } else {
      action = FilledButton.tonal(
          onPressed: () => _add(r), child: Text(st == SkillStatus.updateAvailable ? 'Update' : 'Add'));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => _preview(r),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: Theme.of(context).textTheme.titleSmall),
                if (r.description.isNotEmpty)
                  Text(r.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text('${r.repo} · ${r.path}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline)),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          action,
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skills from GitHub'), actions: [
        IconButton(
            tooltip: 'Sync',
            icon: const Icon(Icons.sync_rounded),
            onPressed: widget.connected ? () => hub.syncAll(force: true) : null),
      ]),
      body: !widget.connected
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Connect GitHub (token) to list and search skills.', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: widget.onConnect, child: const Text('Connect GitHub')),
                ]),
              ),
            )
          : ListenableBuilder(
              listenable: Listenable.merge([hub, widget.store]),
              builder: (_, __) {
                final results = hub.searchResults;
                final list = results ?? hub.items;
                final q = _q.text.trim();
                return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
                  TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search GitHub for skills, or paste owner/repo',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: results != null || q.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _q.clear();
                                hub.clearSearch();
                                setState(() {});
                              })
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (v) {
                      if (SkillHub.looksLikeRepo(v)) {
                        _addRepoDialog(v);
                      } else {
                        hub.search(v);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final s in hub.sources)
                      InputChip(
                        avatar: Icon(s == hub.sources.first && hub.connected() != null
                            ? Icons.link_rounded
                            : Icons.folder_outlined, size: 16),
                        label: Text(s.branch != null && s != hub.sources.first ? '${s.repo}@${s.branch}' : s.repo),
                        onDeleted: s == hub.sources.first && hub.connected() != null
                            ? null
                            : () => hub.removeRepo(hub.extraRepos.firstWhere((e) => e.split('@').first == s.repo)),
                      ),
                    ActionChip(
                        avatar: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('Add repo'),
                        onPressed: _addRepoDialog),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Skill text is added to your prompts when switched on. New skills start off; preview before turning on, and only use repos you trust.',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  if (hub.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(hub.error!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                    ),
                  if (hub.syncing || hub.searching)
                    const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              results != null
                                  ? 'Search results (${list.length})'
                                  : 'In your repos (${list.length})${hub.updatesAvailable > 0 ? ' · ${hub.updatesAvailable} update(s)' : ''}',
                              style: Theme.of(context).textTheme.titleSmall)),
                    ]),
                  ),
                  if (list.isEmpty && !hub.syncing && !hub.searching)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                            child: Text(
                                'No skills found. A skill is a SKILL.md file (or a .md file in a top-level skills/ folder).',
                                textAlign: TextAlign.center))),
                  for (final r in list) _row(r),
                ]);
              },
            ),
    );
  }
}
