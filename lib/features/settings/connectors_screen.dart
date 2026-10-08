import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/local_file_service.dart';
import '../../services/secure_store.dart';
import '../../services/telegram_bridge.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where external services are connected: GitHub and a local workspace folder.
class ConnectorsScreen extends StatefulWidget {
  final AppSettings settings;
  final LocalFileService files;
  final bool githubConnected;
  final String? repoLabel;
  final VoidCallback onOpenGitHub;
  final TelegramBridge telegram;
  final SecureStore store;
  const ConnectorsScreen({
    super.key,
    required this.settings,
    required this.files,
    required this.githubConnected,
    required this.repoLabel,
    required this.onOpenGitHub,
    required this.telegram,
    required this.store,
  });

  @override
  State<ConnectorsScreen> createState() => _ConnectorsScreenState();
}

class _ConnectorsScreenState extends State<ConnectorsScreen> {
  AppSettings get s => widget.settings;
  final _tgToken = TextEditingController();
  String? _pendingChat; // chat that messaged the bot but is not approved yet

  @override
  void initState() {
    super.initState();
    widget.telegram.onUnknownChat = (id, name) {
      if (mounted) setState(() => _pendingChat = '$id|$name');
    };
    widget.telegram.onStatus = (_) {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _tgToken.dispose();
    super.dispose();
  }

  Future<void> _tgStart() async {
    final tok = _tgToken.text.trim();
    if (tok.isEmpty) return;
    await widget.store.setTelegramToken(tok);
    _tgToken.clear();
    await widget.telegram.start(tok, chatId: await widget.store.telegramChatId());
    if (mounted) setState(() {});
  }

  Future<void> _tgStop() async {
    await widget.telegram.stop();
    await widget.store.setTelegramToken(null);
    if (mounted) setState(() {});
  }

  Future<void> _pasteTelegramToken() async {
    final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (value == null || value.isEmpty) return;
    _tgToken.text = value;
    _tgToken.selection = TextSelection.collapsed(offset: value.length);
    Haptics.copy();
  }

  Future<void> _tgApprove() async {
    final id = int.parse(_pendingChat!.split('|').first);
    await widget.store.setTelegramChatId(id);
    widget.telegram.allowedChatId = id;
    setState(() => _pendingChat = null);
  }

  Future<void> _pickWorkspace() async {
    final dir = await widget.files.pickWorkspace();
    if (dir != null) {
      s.setWorkspace(dir.uri.toString());
      Haptics.toggle();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Connectors')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GitHub', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
                widget.githubConnected
                    ? (widget.repoLabel ?? 'Connected. Choose a repository.')
                    : 'Not connected',
                style: sub),
            const SizedBox(height: 10),
            FilledButton.tonal(
                onPressed: widget.onOpenGitHub,
                child: Text(widget.githubConnected ? 'Change repo' : 'Connect & choose repo')),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Workspace folder', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
                s.workspaceUri == null
                    ? 'No folder selected. Grant one folder; the app can only touch files inside it.'
                    : Uri.decodeFull(s.workspaceUri!),
                style: sub),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(
                  onPressed: _pickWorkspace,
                  child: Text(s.workspaceUri == null ? 'Choose folder' : 'Change folder')),
              if (s.workspaceUri != null)
                TextButton(
                    onPressed: () {
                      s.setWorkspace(null);
                      setState(() {});
                    },
                    child: const Text('Forget')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Telegram bot', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
                widget.telegram.running
                    ? 'Online. Replies run in the background service.'
                    : 'Create a bot with @BotFather and paste its token. Only the chat you approve gets answers.',
                style: sub),
            const SizedBox(height: 10),
            if (!widget.telegram.running)
              TextField(
                  controller: _tgToken,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Bot token',
                    suffixIcon: IconButton(
                      tooltip: 'Paste token',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: _pasteTelegramToken,
                    ),
                  )),
            if (_pendingChat != null) ...[
              const SizedBox(height: 8),
              Text('Message from ${_pendingChat!.split('|').last}. Approve this chat?', style: sub),
              TextButton(onPressed: _tgApprove, child: const Text('Approve')),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(
                  onPressed: widget.telegram.running ? _tgStop : _tgStart,
                  child: Text(widget.telegram.running ? 'Stop & forget token' : 'Start bot')),
              OutlinedButton(
                  onPressed: () => Permission.ignoreBatteryOptimizations.request(),
                  child: const Text('Allow background running')),
            ]),
          ]),
        ),
      ]),
    );
  }
}
