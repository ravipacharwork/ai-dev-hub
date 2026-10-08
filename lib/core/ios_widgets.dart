import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'haptics.dart';

/// Apple system colours (light / dark adaptive where Apple differs).
class IosColors {
  static const blue = Color(0xFF0A84FF);
  static const green = Color(0xFF30D158);
  static const orange = Color(0xFFFF9F0A);
  static const red = Color(0xFFFF453A);
  static const purple = Color(0xFFBF5AF2);
  static const indigo = Color(0xFF5E5CE6);
  static const teal = Color(0xFF64D2FF);
  static const pink = Color(0xFFFF375F);
  static const gray = Color(0xFF8E8E93);

  static bool dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
  static Color groupBg(BuildContext c) => dark(c) ? Colors.black : const Color(0xFFF2F2F7);
  static Color cell(BuildContext c) => dark(c) ? const Color(0xFF1C1C1E) : Colors.white;
  static Color separator(BuildContext c) =>
      dark(c) ? const Color(0xFF38383A) : const Color(0xFFC6C6C8);
  static Color secondary(BuildContext c) =>
      dark(c) ? const Color(0xFF98989F) : const Color(0xFF6C6C70);
  static Color label(BuildContext c) => dark(c) ? Colors.white : Colors.black;
}

/// A page with an Apple large title that collapses on scroll, over the
/// grouped background. Use [IosSection]s as [children].
class IosPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final Widget? bottom; // pinned below the list (e.g. a composer)
  const IosPage({super.key, required this.title, required this.children, this.trailing, this.onBack, this.onClose, this.bottom});

  @override
  Widget build(BuildContext context) {
    final dark = IosColors.dark(context);
    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        primaryColor: IosColors.blue,
      ),
      child: Scaffold(
        backgroundColor: IosColors.groupBg(context),
        body: Column(children: [
          Expanded(
            child: CustomScrollView(
              physics: const ClampingScrollPhysics(),
              slivers: [
                CupertinoSliverNavigationBar(
                largeTitle: Text(title),
                leading: onBack == null
                    ? null
                    : CupertinoButton(
                        padding: EdgeInsets.zero,
                        minSize: 36,
                        onPressed: onBack,
                        child: const Icon(CupertinoIcons.back, size: 27),
                      ),
                trailing: trailing ?? (onClose == null
                    ? null
                    : CupertinoButton(
                        padding: EdgeInsets.zero,
                        minSize: 36,
                        onPressed: onClose,
                        child: const Icon(Icons.close_rounded, size: 22),
                      )),
                  backgroundColor: IosColors.groupBg(context).withOpacity(0.85),
                  border: null,
                  stretch: true,
                ),
                SliverSafeArea(
                  top: false,
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      ...children,
                      const SizedBox(height: 32),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          if (bottom != null) bottom!,
        ]),
      ),
    );
  }
}

/// iOS "inset grouped" block: rounded cell group with hairline dividers, an
/// optional small-caps header above and a footnote below.
class IosSection extends StatelessWidget {
  final String? header, footer;
  final List<Widget> children;
  const IosSection({super.key, this.header, this.footer, required this.children});

  @override
  Widget build(BuildContext context) {
    final sec = IosColors.secondary(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Divider(height: 0.5, thickness: 0.5, indent: 16, color: IosColors.separator(context)));
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(header!.toUpperCase(),
                style: TextStyle(fontSize: 13, color: sec, letterSpacing: -0.1)),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(color: IosColors.cell(context), child: Column(children: rows)),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
            child: Text(footer!, style: TextStyle(fontSize: 13, height: 1.3, color: sec)),
          ),
      ]),
    );
  }
}

/// Rounded-square icon badge, as used by the iOS Settings app.
class IosIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const IosIconBadge(this.icon, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 18, color: Colors.white),
      );
}

class IosTile extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String? subtitle, value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron, close, destructive;
  const IosTile({
    super.key,
    this.icon,
    this.iconColor = IosColors.blue,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.close = false,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final sec = IosColors.secondary(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          if (icon != null) ...[IosIconBadge(icon!, iconColor), const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 17,
                      letterSpacing: -0.4,
                      color: destructive ? IosColors.red : IosColors.label(context))),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.25, color: sec)),
                ),
            ]),
          ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(value!, style: TextStyle(fontSize: 17, color: sec)),
            ),
          if (trailing != null) Padding(padding: const EdgeInsets.only(left: 8), child: trailing!),
          if (close)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.close_rounded, size: 20, color: sec),
            ),
          if (chevron)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(CupertinoIcons.chevron_right, size: 15, color: sec.withOpacity(0.6)),
            ),
        ]),
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: () {
        Haptics.toggle();
        onTap!();
      },
      splashFactory: NoSplash.splashFactory,
      highlightColor: IosColors.separator(context).withOpacity(0.35),
      child: row,
    );
  }
}

class IosSwitchTile extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const IosSwitchTile({
    super.key,
    this.icon,
    this.iconColor = IosColors.blue,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => IosTile(
        icon: icon,
        iconColor: iconColor,
        title: title,
        subtitle: subtitle,
        trailing: CupertinoSwitch(
          value: value,
          activeColor: IosColors.green,
          onChanged: onChanged == null
              ? null
              : (v) {
                  Haptics.toggle();
                  onChanged!(v);
                },
        ),
        onTap: onChanged == null ? null : () => onChanged!(!value),
      );
}

/// Sliding segmented control (iOS style) inside a cell.
class IosSegmented<T extends Object> extends StatelessWidget {
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;
  const IosSegmented({super.key, required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: CupertinoSlidingSegmentedControl<T>(
            groupValue: value,
            children: {
              for (final e in options.entries)
                e.key: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(e.value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ),
            },
            onValueChanged: (v) {
              if (v == null) return;
              Haptics.toggle();
              onChanged(v);
            },
          ),
        ),
      );
}

/// Borderless text field living in a cell.
class IosField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final bool obscure, mono;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  const IosField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.obscure = false,
    this.mono = false,
    this.maxLines = 1,
    this.onChanged,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) => CupertinoTextField(
        controller: controller,
        placeholder: placeholder,
        obscureText: obscure,
        maxLines: maxLines,
        minLines: 1,
        clearButtonMode: OverlayVisibilityMode.never,
        suffixMode: OverlayVisibilityMode.always,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: onChanged,
        suffix: suffix,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: null,
        style: TextStyle(
            fontSize: 17,
            fontFamily: mono ? 'monospace' : null,
            color: IosColors.label(context)),
        placeholderStyle: TextStyle(fontSize: 17, color: IosColors.secondary(context).withOpacity(0.7)),
      );
}

/// Full-width primary action, iOS "filled" button.
class IosButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool tinted;
  final IconData? icon;
  const IosButton(this.label, {super.key, this.onPressed, this.tinted = false, this.icon});

  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
      Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
    ]);
    void tap() {
      Haptics.toggle();
      onPressed?.call();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: SizedBox(
        width: double.infinity,
        child: tinted
            ? CupertinoButton(
                color: IosColors.blue.withOpacity(0.15),
                borderRadius: BorderRadius.circular(14),
                onPressed: onPressed == null ? null : tap,
                child: DefaultTextStyle.merge(style: const TextStyle(color: IosColors.blue), child: IconTheme.merge(data: const IconThemeData(color: IosColors.blue), child: child)),
              )
            : CupertinoButton.filled(
                borderRadius: BorderRadius.circular(14),
                onPressed: onPressed == null ? null : tap,
                child: child,
              ),
      ),
    );
  }
}

/// Small status capsule: "Ready", "Off", "3 jobs".
class IosPill extends StatelessWidget {
  final String text;
  final Color color;
  const IosPill(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: color.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      );
}
