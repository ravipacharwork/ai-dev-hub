import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/haptics.dart';

/// Renders fenced code with syntax highlighting, a language tag and a copy button.
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

class _CodeBlock extends StatelessWidget {
  final String code, lang;
  final void Function(String code, String lang, {bool run})? onDeliver;
  const _CodeBlock({required this.code, required this.lang, this.onDeliver});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: (dark ? Colors.white : Colors.black).withOpacity(0.08), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(children: [
            Text(lang,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Theme.of(context).hintColor)),
            const Spacer(),
            if (onDeliver != null && (lang == 'html' || lang == 'htm') && code.length > 200)
              IconButton(
                tooltip: 'Run as app',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                onPressed: () => onDeliver!(code, lang, run: true),
              ),
            if (onDeliver != null && code.contains('\n'))
              IconButton(
                tooltip: 'Save as file',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.download_rounded, size: 18),
                onPressed: () => onDeliver!(code, lang),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 16),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                Haptics.copy();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(milliseconds: 900)));
                }
              },
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: HighlightView(
            code,
            language: lang,
            theme: dark ? atomOneDarkTheme : githubTheme,
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
            padding: EdgeInsets.zero,
          ),
        ),
      ]),
    );
  }
}
