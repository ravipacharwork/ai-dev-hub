import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/deliverables.dart';

/// A file, archive, code, web app or APK delivered inline in the chat.
class DeliverableCard extends StatefulWidget {
  final Deliverable d;
  final bool autoRun; // open the HTML app right away
  const DeliverableCard({super.key, required this.d, this.autoRun = false});

  @override
  State<DeliverableCard> createState() => _DeliverableCardState();
}

class _DeliverableCardState extends State<DeliverableCard> {
  Deliverable get d => widget.d;
  bool _code = false, _run = false, _list = false;
  String? _text;
  List<String>? _entries;
  WebViewController? _web;
  String? _err;

  @override
  void initState() {
    super.initState();
    if (d.kind == DeliverableKind.html && widget.autoRun) _toggleRun();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<String> _read() async => _text ??= await File(d.path).readAsString();

  Future<void> _toggleCode() async {
    try {
      if (!_code) await _read();
      setState(() => _code = !_code);
    } catch (e) {
      _toast('Cannot preview: $e');
    }
  }

  Future<void> _toggleRun() async {
    try {
      if (!_run && _web == null) {
        final html = await _read();
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.white)
          // Generated pages may not navigate the user to other sites.
          ..setNavigationDelegate(NavigationDelegate(
              onNavigationRequest: (r) => r.url == 'about:blank' || r.url.startsWith('data:')
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent))
          ..loadHtmlString(html);
      }
      setState(() => _run = !_run);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  Future<void> _toggleList() async {
    try {
      if (_entries == null) {
        if (d.size > 20 * 1024 * 1024) return _toast('Archive too large to list');
        final a = ZipDecoder().decodeBytes(await File(d.path).readAsBytes());
        _entries = [for (final f in a) if (f.isFile) f.name];
      }
      setState(() => _list = !_list);
    } catch (e) {
      _toast('Cannot read archive: $e');
    }
  }

  Future<void> _open() async {
    final r = await OpenFilex.open(d.path,
        type: d.kind == DeliverableKind.apk
            ? 'application/vnd.android.package-archive'
            : null);
    if (r.type != ResultType.done) _toast(r.message);
  }

  IconData get _icon => switch (d.kind) {
        DeliverableKind.apk => Icons.android_rounded,
        DeliverableKind.zip => Icons.folder_zip_rounded,
        DeliverableKind.html => Icons.web_rounded,
        DeliverableKind.code => Icons.code_rounded,
        DeliverableKind.image => Icons.image_rounded,
        DeliverableKind.file => Icons.insert_drive_file_rounded,
      };

  String get _kindLabel => switch (d.kind) {
        DeliverableKind.apk => 'Android app',
        DeliverableKind.zip => 'Archive',
        DeliverableKind.html => 'Web app',
        DeliverableKind.code => 'Code',
        DeliverableKind.image => 'Image',
        DeliverableKind.file => 'File',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final canText = d.kind == DeliverableKind.code || d.kind == DeliverableKind.html;
    return Glass(
      radius: 16,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Icon(_icon, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall),
              Text('$_kindLabel · ${d.sizeLabel}',
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          if (d.kind == DeliverableKind.apk)
            FilledButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.system_update_rounded, size: 18),
                label: const Text('Install')),
          if (d.kind == DeliverableKind.html)
            FilledButton.icon(
                onPressed: _toggleRun,
                icon: Icon(_run ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                label: Text(_run ? 'Close app' : 'Run')),
          if (canText)
            OutlinedButton.icon(
                onPressed: _toggleCode,
                icon: Icon(_code ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
                label: Text(_code ? 'Hide code' : 'View code')),
          if (d.kind == DeliverableKind.zip)
            OutlinedButton.icon(
                onPressed: _toggleList,
                icon: const Icon(Icons.list_rounded, size: 18),
                label: Text(_list ? 'Hide contents' : 'Contents')),
          if (canText)
            OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: await _read()));
                  Haptics.copy();
                  _toast('Copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy')),
          OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(d.path)]),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('Share / Save')),
          if (d.kind != DeliverableKind.apk && d.kind != DeliverableKind.html)
            OutlinedButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open')),
        ]),
        if (_err != null)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_err!, style: TextStyle(color: cs.error, fontSize: 12))),
        if (d.kind == DeliverableKind.image)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(File(d.path), fit: BoxFit.contain)),
          ),
        if (_run && _web != null)
          Container(
            height: 380,
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant)),
            clipBehavior: Clip.antiAlias,
            child: WebViewWidget(controller: _web!),
          ),
        if (_code && _text != null)
          Container(
            margin: const EdgeInsets.only(top: 10),
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
                color: dark ? const Color(0xFF1C1C1E) : Colors.white,
                borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: HighlightView(
                  _text!.length > 20000 ? '${_text!.substring(0, 20000)}\n… (truncated)' : _text!,
                  language: d.language,
                  theme: dark ? atomOneDarkTheme : githubTheme,
                  textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        if (_list && _entries != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _entries!.take(60).join('\n') +
                  (_entries!.length > 60 ? '\n… ${_entries!.length - 60} more' : ''),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
      ]),
    );
  }
}
