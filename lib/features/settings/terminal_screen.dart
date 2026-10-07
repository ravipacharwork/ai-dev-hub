import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/terminal/terminal_bridge.dart';

class TerminalScreen extends StatefulWidget {
  final AppSettings settings;
  final TerminalBridge bridge;
  const TerminalScreen({super.key, required this.settings, required this.bridge});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _command = TextEditingController();
  final _scroll = ScrollController();
  final _lines = <String>[];
  bool _busy = false;
  String _cwd = '/workspace';

  @override
  void initState() {
    super.initState();
    _lines.add('AI Dev Hub built-in terminal');
    _lines.add('Workspace: /workspace (app-private)');
    _lines.add('Type "help" for supported commands.');
  }

  @override
  void dispose() {
    _command.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run([String? value]) async {
    final command = (value ?? _command.text).trim();
    if (command.isEmpty || _busy) return;
    _command.clear();
    setState(() {
      _busy = true;
      _lines.add('$_cwd \$ $command');
    });
    final r = await widget.bridge.run(command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cwd = widget.bridge.cwd;
      if (r.stdout.isNotEmpty) _lines.add(r.stdout.trimRight());
      if (r.stderr.isNotEmpty) _lines.add(r.stderr.trimRight());
      if (!r.ok && r.error != null) _lines.add('Error: ${r.error}');
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Built-in Terminal')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(child: Column(children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Let the model run commands'),
            subtitle: const Text('Uses the app-private /workspace only. No Termux, Shizuku or ADB.'),
            value: st.terminalEnabled,
            onChanged: (v) { Haptics.toggle(); st.setTerminalEnabled(v); setState(() {}); },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ask before every command'),
            subtitle: Text(st.terminalConfirm ? 'Recommended: approve each command first.' : 'Commands run immediately.'),
            value: st.terminalConfirm,
            onChanged: (v) { Haptics.toggle(); st.setTerminalConfirm(v); setState(() {}); },
          ),
        ])),
        const SizedBox(height: 12),
        Glass(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.verified_user_outlined, color: Colors.green),
            const SizedBox(width: 8),
            Expanded(child: Text('Sandboxed app workspace', style: Theme.of(context).textTheme.titleSmall)),
            const Text('READY', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          const Text('Commands are implemented inside the app and cannot access Android system folders or other apps.'),
          const SizedBox(height: 12),
          Container(
            height: 300,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
            child: ListView.builder(
              controller: _scroll,
              itemCount: _lines.length,
              itemBuilder: (_, i) => SelectableText(_lines[i], style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: TextField(
              controller: _command,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(prefixText: '\$ ', hintText: 'help'),
              onSubmitted: (_) => _run(),
            )),
            IconButton(onPressed: _busy ? null : _run, icon: const Icon(Icons.play_arrow_rounded)),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            for (final c in const ['help', 'pwd', 'ls'])
              ActionChip(label: Text(c), onPressed: _busy ? null : () => _run(c)),
          ]),
        ])),
      ]),
    );
  }
}
