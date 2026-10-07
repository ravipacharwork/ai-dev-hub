import 'dart:ui';
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
  final textTheme = (dark ? typography.white : typography.black).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
    decorationColor: scheme.onSurface,
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
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceTintColor: Colors.transparent,
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
