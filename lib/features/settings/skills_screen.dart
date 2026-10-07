import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/skill_store.dart';

/// Create, toggle, edit and delete skills (instruction blocks added to the
/// system prompt while enabled).
class SkillsScreen extends StatelessWidget {
  final SkillStore store;
  final VoidCallback? onBrowseGitHub;
  const SkillsScreen({super.key, required this.store, this.onBrowseGitHub});

  Future<void> _edit(BuildContext context, [Skill? skill]) async {
    final name = TextEditingController(text: skill?.name ?? '');
    final ins = TextEditingController(text: skill?.instructions ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(skill == null ? 'New skill' : 'Edit skill'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(
              controller: ins,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                  labelText: 'Instructions',
                  hintText: 'How should the assistant behave when this skill is on?'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      skill == null
          ? await store.add(name.text.trim(), ins.text.trim())
          : await store.update(skill, name.text.trim(), ins.text.trim());
    }
    name.dispose();
    ins.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skills'), actions: [
        if (onBrowseGitHub != null)
          IconButton(
              tooltip: 'Import from GitHub',
              icon: const Icon(Icons.cloud_download_outlined),
              onPressed: onBrowseGitHub),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New skill'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (_, __) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                'Skills are reusable instructions. Switch one on and it applies to every new message.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            if (store.skills.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No skills yet'))),
            for (final s in store.skills)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Glass(
                  padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                  child: Row(children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _edit(context, s),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.fromGitHub ? '${s.name}  ·  ${s.sourceRepo}' : s.name,
                                  style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 2),
                              Text(s.instructions,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                            ]),
                      ),
                    ),
                    Switch(
                      value: s.enabled,
                      onChanged: (v) {
                        Haptics.toggle();
                        store.setEnabled(s, v);
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => store.remove(s),
                    ),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
