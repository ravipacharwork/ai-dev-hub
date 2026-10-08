import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/haptics.dart';
import '../../core/ios_widgets.dart';
import '../../services/app_settings.dart';
import '../../services/chat_codec.dart';
import '../../services/local_gateway.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<List<ChatSession>> Function() loadSessions;
  final Future<void> Function(List<ChatSession>) importSessions;
  final VoidCallback? onOpenProviders;
  final VoidCallback? onOpenProxy;
  final LocalGateways? gateways;
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.loadSessions,
    required this.importSessions,
    this.onOpenProviders,
    this.onOpenProxy,
    this.gateways,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get s => widget.settings;
  late final _prompt = TextEditingController(text: s.systemPrompt);

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _export(bool markdown) async {
    try {
      final sessions = await widget.loadSessions();
      if (sessions.isEmpty) return _toast('No chats to export');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/chats.${markdown ? 'md' : 'json'}');
      await f.writeAsString(markdown ? ChatCodec.toMarkdown(sessions) : ChatCodec.toJson(sessions));
      Haptics.toggle();
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _import() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      final path = r?.files.single.path;
      if (path == null) return;
      final sessions = ChatCodec.fromJson(await File(path).readAsString());
      await widget.importSessions(sessions);
      Haptics.copy();
      _toast('Imported ${sessions.length} chat(s)');
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  Future<void> _toggleDeviceFiles(bool v) async {
    if (v) {
      var st = await Permission.manageExternalStorage.status;
      if (!st.isGranted) st = await Permission.manageExternalStorage.request();
      if (!st.isGranted) {
        _toast('Allow "All files access" for AI Dev Hub, then switch this on again.');
        await openAppSettings();
        return;
      }
    }
    s.setDeviceFilesEnabled(v);
    setState(() {});
  }

  Widget _gateway(LocalGateways g) => ListenableBuilder(
        listenable: g,
        builder: (ctx, _) => IosSection(
          header: 'Routing',
          footer: g.error ?? g.kind.blurb,
          children: [
            IosTile(
              icon: Icons.router_rounded,
              iconColor: IosColors.blue,
              title: g.kind.label,
              subtitle: g.busy
                  ? 'Switching…'
                  : g.running
                      ? 'Running on 127.0.0.1:${g.port}'
                      : 'Stopped',
              trailing: g.busy
                  ? const CupertinoActivityIndicator()
                  : IosPill(g.running ? 'Online' : 'Offline', g.running ? IosColors.green : IosColors.red),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return IosPage(
      title: 'Settings',
      onClose: () => Navigator.of(context).maybePop(),
      children: [
        if (widget.gateways != null) _gateway(widget.gateways!),
        IosSection(header: 'Appearance', children: [
          IosSegmented<ThemeMode>(
            options: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
            value: s.themeMode,
            onChanged: (v) {
              s.setTheme(v);
              setState(() {});
            },
          ),
          _FontSize(value: s.fontScale, onEnd: s.setFontScale),
        ]),
        IosSection(
          header: 'Coding agent',
          footer:
              'Commits, builds and pushes always ask first. Tool calling needs a model that supports it.',
          children: [
            IosSwitchTile(
              icon: Icons.account_tree_rounded,
              iconColor: IosColors.indigo,
              title: 'Work on my GitHub repo',
              subtitle: 'Read, edit and stage files on the selected repo',
              value: s.toolsEnabled,
              onChanged: (v) {
                s.setToolsEnabled(v);
                setState(() {});
              },
            ),
            if (s.toolsEnabled)
              IosSwitchTile(
                icon: Icons.verified_user_rounded,
                iconColor: IosColors.green,
                title: 'Auto-verify builds',
                subtitle: 'After a commit, build on GitHub, read errors and fix them (max 3 tries)',
                value: s.autoVerify,
                onChanged: (v) {
                  s.setAutoVerify(v);
                  setState(() {});
                },
              ),
            IosSwitchTile(
              icon: Icons.terminal_rounded,
              iconColor: IosColors.green,
              title: 'Background terminal',
              subtitle: 'The agent runs commands silently. Nothing is shown on screen',
              value: s.terminalEnabled,
              onChanged: (v) {
                s.setTerminalEnabled(v);
                setState(() {});
              },
            ),
            IosSwitchTile(
              icon: Icons.language_rounded,
              iconColor: IosColors.teal,
              title: 'Browser automation',
              subtitle: 'Open pages, click and type in an in-app browser',
              value: s.browserEnabled,
              onChanged: (v) {
                s.setBrowserEnabled(v);
                setState(() {});
              },
            ),
            if (s.browserEnabled)
              IosSwitchTile(
                icon: Icons.shield_rounded,
                iconColor: IosColors.orange,
                title: 'Ask before browser actions',
                subtitle: 'Recommended: web pages can try to trick the model',
                value: s.browserConfirm,
                onChanged: (v) {
                  s.setBrowserConfirm(v);
                  setState(() {});
                },
              ),
            IosSwitchTile(
              icon: Icons.folder_rounded,
              iconColor: IosColors.blue,
              title: 'Phone file access',
              subtitle: 'Deletes ask first and go to a 30-day trash',
              value: s.deviceFilesEnabled,
              onChanged: _toggleDeviceFiles,
            ),
          ],
        ),
        IosSection(
          header: 'Assistant',
          footer: 'Added to every chat as the system prompt.',
          children: [
            IosField(
              controller: _prompt,
              placeholder: 'You are a helpful coding assistant.',
              maxLines: 6,
              onChanged: s.setSystemPrompt,
            ),
          ],
        ),
        IosSection(
          header: 'Power',
          footer: 'Power Mode never grants root, ADB, hidden app access or silent installs.',
          children: [
            IosSwitchTile(
              icon: Icons.bolt_rounded,
              iconColor: IosColors.orange,
              title: 'Power Mode',
              subtitle: 'Advanced agent workflows',
              value: s.powerMode,
              onChanged: (v) {
                s.setPowerMode(v);
                setState(() {});
              },
            ),
            IosTile(
              icon: Icons.speed_rounded,
              iconColor: IosColors.pink,
              title: 'Routing profile',
              value: _profileLabel(s.routingProfile),
              close: true,
              onTap: _pickProfile,
            ),
          ],
        ),
        IosSection(header: 'Chats', children: [
          IosTile(
              icon: Icons.upload_rounded,
              iconColor: IosColors.blue,
              title: 'Export as JSON',
              close: true,
              onTap: () => _export(false)),
          IosTile(
              icon: Icons.description_rounded,
              iconColor: IosColors.indigo,
              title: 'Export as Markdown',
              close: true,
              onTap: () => _export(true)),
          IosTile(
              icon: Icons.download_rounded,
              iconColor: IosColors.green,
              title: 'Import JSON',
              close: true,
              onTap: _import),
        ]),
        IosSection(header: 'Advanced', children: [
          IosTile(
            icon: Icons.key_rounded,
            iconColor: IosColors.purple,
            title: 'API keys and providers',
            subtitle: 'Add keys, test connections',
            close: true,
            onTap: widget.onOpenProviders,
          ),
          IosTile(
            icon: Icons.sync_alt_rounded,
            iconColor: IosColors.gray,
            title: 'Local proxy server',
            subtitle: 'Share the router with other apps on this device',
            close: true,
            onTap: widget.onOpenProxy,
          ),
        ]),
      ],
    );
  }

  static const _profiles = {
    'auto': 'Auto',
    'fast': 'Fast',
    'cheap': 'Free tier first',
    'coding': 'Coding',
  };
  String _profileLabel(String id) => _profiles[id] ?? id;

  void _pickProfile() {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Routing profile'),
        actions: [
          for (final e in _profiles.entries)
            CupertinoActionSheetAction(
              isDefaultAction: e.key == s.routingProfile,
              onPressed: () {
                s.setRoutingProfile(e.key);
                Navigator.pop(ctx);
                setState(() {});
              },
              child: Text(e.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }
}

class _FontSize extends StatefulWidget {
  final double value;
  final ValueChanged<double> onEnd;
  const _FontSize({required this.value, required this.onEnd});

  @override
  State<_FontSize> createState() => _FontSizeState();
}

class _FontSizeState extends State<_FontSize> {
  late double _v = widget.value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          const Text('A', style: TextStyle(fontSize: 13)),
          Expanded(
            child: CupertinoSlider(
              value: _v,
              min: 0.85,
              max: 1.4,
              divisions: 11,
              onChanged: (x) => setState(() => _v = x),
              onChangeEnd: widget.onEnd,
            ),
          ),
          const Text('A', style: TextStyle(fontSize: 22)),
        ]),
      );
}
