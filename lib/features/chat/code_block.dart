import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/haptics.dart';

/// Renders fenced code with syntax highlighting, a language tag and actions.
/// Inline `code` (no newline, no language) falls through to default styling.
class CodeBlockBuilder extends MarkdownElementBuilder {
  /// Turn a block into a file card in the chat (run = open an HTML app at once).
  final void Function(String code, String lang, {bool run})? onDeliver;
  CodeBlockBuilder({this.onDeliver});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final cls = element.attributes['class'] ?? '';
    final text = element.textContent;
    final isBlock = cls.startsWith('language-') || text.contains('\n');
    if (!isBlock) return null;
    final lang = cls.startsWith('language-') ? cls.substring(9) : 'text';
    return _CodeBlock(code: text.trimRight(), lang: lang, onDeliver: onDeliver);
  }
}

Map<String, TextStyle> _transparentRoot(Map<String, TextStyle> t) => {
      ...t,
      'root': (t['root'] ?? const TextStyle())
          .copyWith(backgroundColor: Colors.transparent),
    };

final _darkCode = _transparentRoot(atomOneDarkTheme);
final _lightCode = _transparentRoot(githubTheme);

class _CodeBlock extends StatelessWidget {
  final String code, lang;
  final void Function(String code, String lang, {bool run})? onDeliver;
  const _CodeBlock({required this.code, required this.lang, this.onDeliver});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = (dark ? Colors.white : Colors.black).withOpacity(dark ? 0.10 : 0.07);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFAFAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: line, width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
          decoration: BoxDecoration(
            color: (dark ? Colors.white : Colors.black).withOpacity(dark ? 0.05 : 0.035),
            border: Border(bottom: BorderSide(color: line, width: 0.5)),
          ),
          child: Row(children: [
            Text(lang.isEmpty ? 'text' : lang,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: cs.onSurfaceVariant)),
            const Spacer(),
            if (onDeliver != null && (lang == 'html' || lang == 'htm') && code.length > 200)
              _CodeAction(
                icon: Icons.play_arrow_rounded,
                tooltip: 'Run as app',
                onTap: () => onDeliver!(code, lang, run: true),
              ),
            if (onDeliver != null && code.contains('\n'))
              _CodeAction(
                icon: Icons.download_rounded,
                tooltip: 'Save as file',
                onTap: () => onDeliver!(code, lang),
              ),
            _CopyAction(code: code),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: HighlightView(
            code,
            language: lang,
            theme: dark ? _darkCode : _lightCode,
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.45),
            padding: EdgeInsets.zero,
          ),
        ),
      ]),
    );
  }
}

class _CodeAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _CodeAction({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
        iconSize: 19,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        icon: Icon(icon),
        onPressed: () {
          Haptics.toggle();
          onTap();
        },
      );
}

class _CopyAction extends StatefulWidget {
  final String code;
  const _CopyAction({required this.code});
  @override
  State<_CopyAction> createState() => _CopyActionState();
}

class _CopyActionState extends State<_CopyAction> {
  bool _done = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'Copy',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      iconSize: 17,
      color: _done ? const Color(0xFF30D158) : cs.onSurfaceVariant,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(_done ? Icons.check_rounded : Icons.copy_rounded,
            key: ValueKey(_done)),
      ),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.code));
        Haptics.copy();
        if (!mounted) return;
        setState(() => _done = true);
        _t?.cancel();
        _t = Timer(const Duration(milliseconds: 1300), () {
          if (mounted) setState(() => _done = false);
        });
      },
    );
  }
}
