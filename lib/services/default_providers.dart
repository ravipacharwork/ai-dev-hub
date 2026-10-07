/// Embedded OmniRoute-style gateway. It runs inside the app on loopback and
/// routes across all configured upstream provider keys.
class DefaultGateway {
  final String id, name, baseUrl, apiKey;
  const DefaultGateway(this.id, this.name, this.baseUrl, this.apiKey);
  bool get enabled => baseUrl.trim().isNotEmpty;
}

class DefaultProviders {
  static const omniRouteId = 'omniroute';
  static const omniRoutePort = 20128;

  static DefaultGateway? _active;
  static void setActive(DefaultGateway? g) => _active = g;
  static List<DefaultGateway> get all => _active == null ? const [] : [_active!];
  static bool isDefault(String providerId) => providerId == omniRouteId;
  static String label(String providerId) => providerId == omniRouteId ? 'OmniRoute' : providerId;
}
