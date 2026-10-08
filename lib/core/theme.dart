import 'dart:ui';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0A84FF), // iOS system blue
    brightness: b,
  );
  // Explicit, high-contrast surface/text colours. Previously the text theme was
  // hard-wired to the *light* palette, so dark mode rendered black-on-black.
  final scheme = base.copyWith(
    surface: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
    onSurface: dark ? const Color(0xFFF5F5F7) : const Color(0xFF111114),
    onSurfaceVariant: dark ? const Color(0xFFC7C7CC) : const Color(0xFF3C3C43),
    surfaceContainerHighest:
        dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
    outline: dark ? const Color(0xFF8E8E93) : const Color(0xFF6C6C70),
    outlineVariant: dark ? const Color(0xFF48484A) : const Color(0xFFC6C6C8),
  );

  final typography = Typography.material2021(platform: TargetPlatform.iOS);
  final baseText = (dark ? typography.white : typography.black).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
    decorationColor: scheme.onSurface,
  );
  // One consistent iOS-like type scale.
  final textTheme = baseText.copyWith(
    headlineSmall: baseText.headlineSmall?.copyWith(
        fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    titleLarge: baseText.titleLarge?.copyWith(
        fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.4),
    titleMedium: baseText.titleMedium?.copyWith(
        fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    titleSmall: baseText.titleSmall?.copyWith(
        fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1),
    bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 16, height: 1.4),
    bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 15, height: 1.35),
    bodySmall: baseText.bodySmall?.copyWith(fontSize: 13, height: 1.3),
  );

  final secondary = scheme.onSurfaceVariant;

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    hintColor: secondary,
    disabledColor: scheme.onSurface.withOpacity(0.38),
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: IconThemeData(color: scheme.onSurface),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: scheme.onSurface,
      iconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: secondary),
      labelStyle: TextStyle(color: secondary),
      floatingLabelStyle: TextStyle(color: scheme.primary),
      helperStyle: TextStyle(color: secondary),
      prefixIconColor: secondary,
      suffixIconColor: secondary,
    ),
    listTileTheme: ListTileThemeData(
      textColor: scheme.onSurface,
      iconColor: scheme.onSurface,
      subtitleTextStyle: TextStyle(color: secondary, fontSize: 13),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      clipBehavior: Clip.antiAlias,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF2C2C2E) : Colors.white,
      surfaceTintColor: Colors.transparent,
      textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: dark ? const Color(0xFF111113) : const Color(0xFFFAFAFC),
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: dark ? const Color(0xFFE5E5EA) : const Color(0xFF2C2C2E),
      contentTextStyle:
          TextStyle(color: dark ? const Color(0xFF111114) : Colors.white),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStatePropertyAll(scheme.outline),
    ),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary)),
  );
}

/// Frosted-glass container: blur + translucent fill + hairline border.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  const Glass(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(12),
      this.radius = 18});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // Dark: opaque-ish raised surface so onSurface text always has contrast.
            color: dark
                ? const Color(0xFF1C1C1E).withOpacity(0.88)
                : Colors.white.withOpacity(0.78),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: (dark ? Colors.white : Colors.black)
                    .withOpacity(dark ? 0.14 : 0.08),
                width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }
}


/// iOS-style scrolling everywhere: rubber-band overscroll, no Android glow.
class IosScrollBehavior extends MaterialScrollBehavior {
  const IosScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

/// Solid (non-blurred) rounded surface for items inside scrolling lists.
/// BackdropFilter per list item is very expensive and makes scrolling janky,
/// so cards in the chat use this instead of [Glass].
class SoftCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  const SoftCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(14),
      this.radius = 18,
      this.color});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? (dark ? const Color(0xFF1C1C1E) : Colors.white),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
            color: (dark ? Colors.white : Colors.black)
                .withOpacity(dark ? 0.10 : 0.06),
            width: 0.5),
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 3))
              ],
      ),
      child: child,
    );
  }
}
