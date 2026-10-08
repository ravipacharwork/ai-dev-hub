import 'dart:convert' show base64, jsonEncode;

import 'package:path/path.dart' as p;

import '../deliverables.dart';
import '../github_service.dart';
import 'agent_tools.dart';

/// `preview_html`: build a runnable preview of a web app that lives in the
/// repo, INCLUDING staged (uncommitted) edits, and show it live in the chat.
/// Local CSS / JS / small images are inlined so one WebView page is enough.
class PreviewToolkit implements Toolkit {
  final AgentWorkspace? Function() workspace;
  final DeliveryStore store;
  PreviewToolkit(this.workspace, this.store);

  static const _maxInlineBytes = 300 * 1024;

  @override
  List<Map<String, dynamic>> get schemas => [
        {
          'type': 'function',
          'function': {
            'name': 'preview_html',
            'description':
                'Show a live preview of a web page from the repo inside the chat (uses staged edits, no commit needed). Local .css, .js and small images referenced by the page are inlined. Use it after changing HTML/CSS/JS so the user sees the result immediately.',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': 'Repo path of the HTML entry file, default index.html'
                },
                'explore': {
                  'type': 'boolean',
                  'description':
                      'Default true: after load, the preview clicks up to 12 visible buttons / menu items once (skipping delete, buy, submit, logout style ones) so errors hidden behind interactions show up. Set false for pages where that is unwanted.'
                },
                'click': {
                  'type': 'array',
                  'items': {'type': 'string'},
                  'description':
                      'Optional CSS selectors to click in order after the page loads (max 8), to test buttons and menus. Errors raised by those clicks are returned.'
                },
              },
            },
          },
        },
      ];

  @override
  String get systemNote =>
      'Live preview: after you create or change a web page (HTML/CSS/JS), call preview_html so the user sees it running in the chat right away. For a single self-made file with nothing in the repo, deliver_file with a .html name also runs inline. After the page loads, its JavaScript errors are returned to you in the tool result: fix them and preview again (max 2 retries) before telling the user it works. The preview auto-clicks its buttons once; pass "click" selectors for specific flows (it cannot type text or fill forms). Errors the user triggers later are added to your next tool result or message.';

  @override
  String label(String name, Map<String, dynamic> args) =>
      'Preview  ${args['path'] ?? 'index.html'}';

  @override
  ApprovalRequest? approval(String name, Map<String, dynamic> args) => null;

  @override
  Future<ToolResult> run(String name, Map<String, dynamic> args) async {
    final ws = workspace();
    if (ws == null) {
      return const ToolResult(
          'No repo is selected. Pick one via GitHub, or use deliver_file with an .html name for a single-file app.',
          ok: false);
    }
    try {
      final rawClicks = args['click'];
      final clicks = rawClicks is List
          ? [for (final x in rawClicks) if (x is String && x.trim().isNotEmpty && x.length <= 200) x.trim()]
              .take(8)
              .toList()
          : <String>[];
      final explore = args['explore'] != false && clicks.isEmpty;
      final entry = _clean('${args['path'] ?? 'index.html'}');
      if (entry == null) return const ToolResult('Invalid path.', ok: false);
      final html = await ws.currentText(entry);
      if (html == null) return ToolResult('$entry not found (or staged for deletion).', ok: false);

      final dir = p.posix.dirname(entry) == '.' ? '' : p.posix.dirname(entry);
      var notes = 0;
      String? resolve(String ref) {
        if (RegExp(r'^(https?:|data:|//|#|mailto:)').hasMatch(ref)) return null;
        final clean = ref.split('?').first.split('#').first;
        return _clean(p.posix.normalize(p.posix.join(dir, clean)));
      }

      var out = html;
      out = await _replaceAsync(
          out,
          RegExp(r'''<link\b[^>]*>''', caseSensitive: false),
          (m) async {
            final tag = m.group(0)!;
            if (!RegExp(r'''rel=["']?stylesheet''', caseSensitive: false).hasMatch(tag)) return tag;
            final href = RegExp(r'''href=["']([^"']+)["']''', caseSensitive: false).firstMatch(tag)?.group(1);
            final path = href == null ? null : resolve(href);
            if (path == null) return tag;
            final css = await ws.currentText(path);
            if (css == null) return tag;
            notes++;
            return '<style>\n${css.replaceAll('</style', r'<\/style')}\n</style>';
          });
      out = await _replaceAsync(
          out,
          RegExp(r'''<script\b([^>]*?)\ssrc=["']([^"']+)["']([^>]*)>\s*</script>''',
              caseSensitive: false),
          (m) async {
            final path = resolve(m.group(2)!);
            if (path == null) return m.group(0)!;
            final js = await ws.currentText(path);
            if (js == null) return m.group(0)!;
            notes++;
            return '<script${m.group(1)}${m.group(3)}>\n${js.replaceAll('</script', r'<\/script')}\n</script>';
          });
      out = await _replaceAsync(
          out,
          RegExp(r'''(<img\b[^>]*?\bsrc=["'])([^"']+)(["'])''', caseSensitive: false),
          (m) async {
            final path = resolve(m.group(2)!);
            if (path == null) return m.group(0)!;
            try {
              final bytes = ws.staged.containsKey(path)
                  ? null
                  : await ws.gh.readBytes(ws.repo, path, ws.branch);
              if (bytes == null || bytes.length > _maxInlineBytes) return m.group(0)!;
              final mime = _mime(path);
              if (mime == null) return m.group(0)!;
              notes++;
              return '${m.group(1)}data:$mime;base64,${_b64(bytes)}${m.group(3)}';
            } on GitHubException {
              return m.group(0)!;
            }
          });

      final d = await store.saveText('preview_${p.posix.basename(entry)}', out);
      return ToolResult(
          'Preview of $entry is now running in the chat ($notes local file(s) inlined). Staged edits are included.',
          deliverables: [d],
          // The runner shows the card first, then waits here: the page loads in
          // the card and its JavaScript errors come back to the model.
          settle: () async {
            var r = await PreviewReports.instance.wait(d.path);
            if (clicks.isNotEmpty && r.loaded) {
              for (final sel in clicks) {
                final q = jsonEncode(sel);
                final done = await PreviewReports.instance.run(
                    d.path,
                    '(function(){var e=document.querySelector($q);'
                    'if(e){e.click()}else{AH.postMessage("Click target not found: "+$q)}})()');
                if (!done) break;
                await Future<void>.delayed(const Duration(milliseconds: 600));
              }
              r = await PreviewReports.instance
                  .wait(d.path, timeout: const Duration(seconds: 3), grace: const Duration(milliseconds: 800));
            }
            if (explore && r.loaded) {
              final started = await PreviewReports.instance.run(d.path, _exploreJs);
              if (started) {
                r = await PreviewReports.instance.wait(d.path,
                    timeout: const Duration(seconds: 9), grace: const Duration(milliseconds: 5800));
              }
              return _report(entry, notes, r, 0, explored: started);
            }
            return _report(entry, notes, r, clicks.length);
          });
    } on GitHubException catch (e) {
      return ToolResult('GitHub error: $e', ok: false);
    } catch (e) {
      return ToolResult('Preview failed: $e', ok: false);
    }
  }

  /// Clicks each visible button-like element once, 400 ms apart. Risky-sounding
  /// ones and form submits are skipped. Errors reach the page's AH reporter.
  static const _exploreJs = r"""(function(){
var skip=/delete|remove|erase|reset|clear all|buy|pay|purchase|order|checkout|log ?out|sign ?out|unsubscribe|submit|send/i;
var els=[].slice.call(document.querySelectorAll('button,[onclick],[role=button],summary,input[type=button],a[href^="#"],.btn')).filter(function(e){
var t=(e.innerText||e.value||e.id||e.className||'')+'';var r=e.getBoundingClientRect();
return !e.disabled&&r.width>0&&r.height>0&&!skip.test(t)&&e.type!=='submit';}).slice(0,12);
els.forEach(function(e,i){setTimeout(function(){try{e.click()}catch(x){AH.postMessage('Click failed: '+x)}},i*400)});
})()""";

  static ToolResult _report(String entry, int notes, PreviewReport r, int clicked, {bool explored = false}) {
    final after = clicked > 0
        ? ' (after clicking $clicked element(s))'
        : (explored ? ' (after auto-clicking its buttons once)' : '');
    if (r.errors.isNotEmpty) {
      final list = r.errors.map((e) => '- $e').join('\n');
      return ToolResult(
          'Preview of $entry ran$after with ${r.errors.length} JavaScript error(s):\n$list\n'
          'Fix the cause (write_file / replace_in_file; staged edits are used) and call preview_html again. '
          'Line numbers refer to the inlined page, so search the repo files for the failing code. '
          'If it still fails after 2 attempts, stop and tell the user what is wrong.',
          ok: false);
    }
    if (!r.loaded) {
      return ToolResult(
          'Preview of $entry was sent to the chat, but the page did not report back (not shown yet or still loading), '
          'so errors could not be checked. Do not claim it works; tell the user it is unverified.');
    }
    return ToolResult(
        'Preview of $entry is running in the chat ($notes local file(s) inlined). No JavaScript errors were reported while it loaded$after. '
        '${clicked == 0 && !explored ? 'To test buttons or menus, call preview_html again with "click" selectors. ' : ''}'
        'Errors from later user actions are passed on to you if they appear.');
  }

  static String? _clean(String raw) {
    var s = raw.trim().replaceAll('\\', '/');
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    if (s.startsWith('/')) s = s.substring(1);
    if (s.isEmpty || s.split('/').any((x) => x.isEmpty || x == '..')) return null;
    return s;
  }

  static String? _mime(String path) => switch (p.posix.extension(path).toLowerCase()) {
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.svg' => 'image/svg+xml',
        _ => null,
      };

  static String _b64(List<int> b) => base64.encode(b);

  static Future<String> _replaceAsync(
      String s, RegExp re, Future<String> Function(Match) f) async {
    final b = StringBuffer();
    var last = 0;
    for (final m in re.allMatches(s)) {
      b.write(s.substring(last, m.start));
      b.write(await f(m));
      last = m.end;
    }
    b.write(s.substring(last));
    return b.toString();
  }
}
