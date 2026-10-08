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
  final _jsErrors = <String>[];
  bool _showJs = false;

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
        _web = _newController(html);
      }
      setState(() => _run = !_run);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  /// WebView for a generated page. Catches JavaScript errors and reports them
  /// back so a broken page does not fail silently.
  WebViewController _newController(String html, {void Function(String)? onError}) {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('AH', onMessageReceived: (m) {
        PreviewReports.instance.error(d.path, m.message); // the agent reads these too
        if (onError != null) return onError(m.message);
        if (!mounted) return;
        if (_jsErrors.length < 20 && !_jsErrors.contains(m.message)) {
          setState(() => _jsErrors.add(m.message));
        }
      })
      // Generated pages may not navigate the user to other sites.
      ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) => PreviewReports.instance.loaded(d.path),
          onWebResourceError: (e) =>
              PreviewReports.instance.error(d.path, 'Resource failed to load: ${e.description}'),
          onNavigationRequest: (r) => r.url == 'about:blank' || r.url.startsWith('data:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent))
      ..loadHtmlString(withErrorProbe(html));
    PreviewReports.instance.attach(d.path, c.runJavaScript); // lets the agent click through the page
    return c;
  }

  Future<void> _reload() async {
    try {
      _text = null;
      final html = await _read();
      _jsErrors.clear();
      _web ??= _newController(html);
      await _web!.loadHtmlString(withErrorProbe(html));
      if (mounted) setState(() {});
    } catch (e) {
      _toast('Cannot reload: $e');
    }
  }

  Future<void> _fullscreen() async {
    final html = await _read();
    if (!mounted) return;
    // Close the inline copy first: two WebViews of one page are heavy on a phone.
    if (_run) setState(() => _run = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PreviewPage(title: d.name, html: html, build: _newController),
    ));
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
    final isApk = d.kind == DeliverableKind.apk;
    final isHtml = d.kind == DeliverableKind.html;
    return SoftCard(
      radius: 18,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: cs.primary.withOpacity(0.13),
                borderRadius: BorderRadius.circular(13)),
            child: Icon(_icon, color: cs.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text('$_kindLabel · ${d.sizeLabel}',
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          if (isApk || isHtml) ...[
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: const StadiumBorder(),
              ),
              onPressed: isApk ? _open : _toggleRun,
              icon: Icon(
                  isApk
                      ? Icons.system_update_rounded
                      : (_run ? Icons.stop_rounded : Icons.play_arrow_rounded),
                  size: 18),
              label: Text(isApk ? 'Install' : (_run ? 'Close' : 'Run')),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (canText)
            _Pill(
                icon: _code ? Icons.visibility_off_rounded : Icons.code_rounded,
                label: _code ? 'Hide code' : 'Code',
                onTap: _toggleCode),
          if (d.kind == DeliverableKind.zip)
            _Pill(
                icon: Icons.list_rounded,
                label: _list ? 'Hide' : 'Contents',
                onTap: _toggleList),
          if (canText)
            _Pill(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: await _read()));
                  Haptics.copy();
                  _toast('Copied');
                }),
          if (isHtml && _run) ...[
            _Pill(icon: Icons.refresh_rounded, label: 'Reload', onTap: _reload),
            _Pill(icon: Icons.fullscreen_rounded, label: 'Full screen', onTap: _fullscreen),
          ],
          if (!isApk && !isHtml)
            _Pill(icon: Icons.open_in_new_rounded, label: 'Open', onTap: _open),
          _Pill(
              icon: Icons.ios_share_rounded,
              label: 'Share',
              onTap: () => Share.shareXFiles([XFile(d.path)])),
        ]),
        if (_err != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!, style: TextStyle(color: cs.error, fontSize: 12))),
        if (_jsErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GestureDetector(
              onTap: () => setState(() => _showJs = !_showJs),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.error.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.bug_report_rounded, size: 18, color: cs.error),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(
                            '${_jsErrors.length} JavaScript error${_jsErrors.length == 1 ? '' : 's'} in this page'
                            ' · tell the assistant to fix it',
                            style: TextStyle(fontSize: 12.5, color: cs.error))),
                    Icon(_showJs ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        size: 18, color: cs.error),
                  ]),
                  if (_showJs)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(_jsErrors.join('\n'),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
                    ),
                ]),
              ),
            ),
          ),
        if (d.kind == DeliverableKind.image)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(File(d.path), fit: BoxFit.contain)),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: (_run && _web != null)
              ? Container(
                  height: 380,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.outlineVariant, width: 0.5)),
                  clipBehavior: Clip.antiAlias,
                  child: WebViewWidget(controller: _web!),
                )
              : const SizedBox(width: double.infinity),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: (_code && _text != null)
              ? Container(
                  margin: const EdgeInsets.only(top: 12),
                  constraints: const BoxConstraints(maxHeight: 320),
                  decoration: BoxDecoration(
                      color: dark ? const Color(0xFF111113) : const Color(0xFFF5F5F8),
                      borderRadius: BorderRadius.circular(14)),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.all(14),
                      child: HighlightView(
                        _text!.length > 20000
                            ? '${_text!.substring(0, 20000)}\n… (truncated)'
                            : _text!,
                        language: d.language,
                        theme: {
                          ...(dark ? atomOneDarkTheme : githubTheme),
                          'root': TextStyle(
                              backgroundColor: Colors.transparent,
                              color: dark ? const Color(0xFFABB2BF) : const Color(0xFF24292E)),
                        },
                        textStyle: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12.5, height: 1.45),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: (_list && _entries != null)
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _entries!.take(60).join('\n') +
                        (_entries!.length > 60 ? '\n… ${_entries!.length - 60} more' : ''),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

/// Small tonal action chip used under a deliverable.
class _Pill extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Pill({required this.icon, required this.label, required this.onTap});

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: () {
        Haptics.toggle();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withOpacity(0.7),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 16, color: cs.onSurface),
            const SizedBox(width: 6),
            Text(widget.label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface)),
          ]),
        ),
      ),
    );
  }
}


const _probe = '''<script>(function(){function r(m){try{AH.postMessage(String(m).slice(0,300))}catch(e){}}
window.addEventListener('error',function(e){r((e.message||'Error')+(e.lineno?' (line '+e.lineno+')':''))});
window.addEventListener('unhandledrejection',function(e){r('Promise: '+((e.reason&&e.reason.message)||e.reason))});
var ce=console.error;console.error=function(){r([].join.call(arguments,' '));ce.apply(console,arguments)};})();</script>''';

/// Adds the JavaScript error reporter to the top of a generated page.
String withErrorProbe(String html) {
  final m = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
  if (m != null) return html.replaceRange(m.end, m.end, _probe);
  return '$_probe$html';
}

/// Full-screen live preview with reload.
class _PreviewPage extends StatefulWidget {
  final String title, html;
  final WebViewController Function(String html, {void Function(String)? onError}) build;
  const _PreviewPage({required this.title, required this.html, required this.build});

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  late final WebViewController _c;
  int _errors = 0;

  @override
  void initState() {
    super.initState();
    _c = widget.build(widget.html, onError: (_) {
      if (mounted) setState(() => _errors++);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        actions: [
          if (_errors > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                  child: Text('$_errors JS error${_errors == 1 ? '' : 's'}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12.5))),
            ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() => _errors = 0);
              _c.loadHtmlString(withErrorProbe(widget.html));
            },
          ),
        ],
      ),
      body: SafeArea(top: false, child: WebViewWidget(controller: _c)),
    );
  }
}
