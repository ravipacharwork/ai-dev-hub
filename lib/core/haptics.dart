import 'package:flutter/services.dart';

class Haptics {
  static void send() => HapticFeedback.lightImpact();
  static void copy() => HapticFeedback.selectionClick();
  static void toggle() => HapticFeedback.selectionClick();
  /// Soft confirmation when a reply finishes.
  static void done() => HapticFeedback.mediumImpact();
  static void buildDone() => HapticFeedback.heavyImpact();
  static void error() => HapticFeedback.vibrate();
}
