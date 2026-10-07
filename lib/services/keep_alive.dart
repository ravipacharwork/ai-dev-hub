import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Shared Android foreground service so long agent runs and the local proxy
/// keep the process alive in the background. Reference counted: the service
/// stops only when the last user releases it.
class KeepAlive {
  static int _n = 0;

  static Future<void> acquire(String text) async {
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      _n++;
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
      } else {
        await FlutterForegroundTask.startService(
            notificationTitle: 'AI Dev Hub', notificationText: text);
      }
    } catch (_) {/* not Android / service unavailable: run in foreground only */}
  }

  static Future<void> update(String text) async {
    try {
      if (_n > 0 && await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
      }
    } catch (_) {}
  }

  static Future<void> release() async {
    if (_n > 0) _n--;
    if (_n == 0) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
  }
}
