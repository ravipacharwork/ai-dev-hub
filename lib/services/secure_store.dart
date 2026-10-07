import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

enum RouteMode { direct, gateway }

/// Secrets live in EncryptedSharedPreferences (Android Keystore-backed) /
/// Keychain (iOS). Non-secret settings use plain SharedPreferences.
class SecureStore {
  final _s = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<String?> apiKey(String providerId) => _s.read(key: 'key:$providerId');
  Future<void> setApiKey(String providerId, String? v) => (v == null || v.isEmpty)
      ? _s.delete(key: 'key:$providerId')
      : _s.write(key: 'key:$providerId', value: v);

  /// Multiple keys for one provider, stored as one encrypted JSON value.
  Future<List<String>> apiKeys(String providerId) async {
    final raw = await _s.read(key: 'keys:$providerId');
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).whereType<String>();
        return list.where((x) => x.trim().isNotEmpty).toList();
      } catch (_) {}
    }
    final legacy = await apiKey(providerId);
    return legacy == null || legacy.isEmpty ? [] : [legacy];
  }

  Future<void> setApiKeys(String providerId, List<String> values) async {
    final keys = values.map((x) => x.trim()).where((x) => x.isNotEmpty).toSet().toList();
    if (keys.isEmpty) {
      await _s.delete(key: 'keys:$providerId');
      await _s.delete(key: 'key:$providerId');
    } else {
      await _s.write(key: 'keys:$providerId', value: jsonEncode(keys));
      await _s.write(key: 'key:$providerId', value: keys.first);
    }
  }

  Future<String?> githubToken() => _s.read(key: 'github_pat');
  Future<void> setGithubToken(String? v) => (v == null || v.isEmpty)
      ? _s.delete(key: 'github_pat')
      : _s.write(key: 'github_pat', value: v);

  Future<String?> proxyToken() => _s.read(key: 'proxy_token');
  Future<void> setProxyToken(String v) => _s.write(key: 'proxy_token', value: v);

  Future<String?> gatewayToken() => _s.read(key: 'gateway_token');
  Future<void> setGatewayToken(String v) => _s.write(key: 'gateway_token', value: v);

  Future<String?> telegramToken() => _s.read(key: 'telegram_token');
  Future<void> setTelegramToken(String? v) => (v == null || v.isEmpty)
      ? _s.delete(key: 'telegram_token')
      : _s.write(key: 'telegram_token', value: v);
  Future<int?> telegramChatId() async => int.tryParse(
      (await SharedPreferences.getInstance()).getString('telegram_chat') ?? '');
  Future<void> setTelegramChatId(int? v) async {
    final p = await SharedPreferences.getInstance();
    v == null ? p.remove('telegram_chat') : p.setString('telegram_chat', '$v');
  }

  // ---- non-secret ----
  Future<String?> gatewayKind() async =>
      (await SharedPreferences.getInstance()).getString('gateway_kind');
  Future<void> setGatewayKind(String v) async =>
      (await SharedPreferences.getInstance()).setString('gateway_kind', v);

  Future<String?> baseUrl(String providerId) async =>
      (await SharedPreferences.getInstance()).getString('base:$providerId');
  Future<void> setBaseUrl(String providerId, String v) async =>
      (await SharedPreferences.getInstance()).setString('base:$providerId', v);

  Future<RouteMode> mode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('route_mode') == 'gateway' ? RouteMode.gateway : RouteMode.direct;
  }

  Future<void> setMode(RouteMode m) async =>
      (await SharedPreferences.getInstance()).setString('route_mode', m.name);

  /// "owner/repo|branch|workflowFile"
  Future<String?> repoSelection() async =>
      (await SharedPreferences.getInstance()).getString('repo_sel');
  Future<void> setRepoSelection(String v) async =>
      (await SharedPreferences.getInstance()).setString('repo_sel', v);
}
