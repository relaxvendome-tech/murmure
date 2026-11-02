import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;

import 'account.dart';
import 'config.dart';

/// Mode de connexion au serveur.
enum NetMode {
  /// Connexion directe (HTTPS classique).
  direct,

  /// Via Tor, par Orbot (proxy SOCKS5 local, 127.0.0.1:9050 par défaut).
  tor,

  /// Via un proxy SOCKS5 personnalisé (contournement de blocage).
  customProxy,
}

/// Réglages réseau persistés localement : URL du serveur, jeton d'inscription et mode de
/// connexion. Modifiables depuis l'appli, jamais codés en dur (contrairement à la 2.3.0, où
/// `https://murmure.example.fr` était inscrit dans le binaire et impossible à changer sans
/// recompiler).
class NetConfig {
  NetConfig({
    required this.homeserver,
    required this.registrationToken,
    required this.mode,
    this.proxyHost,
    this.proxyPort,
  });

  final Uri homeserver;
  final String registrationToken;
  final NetMode mode;
  final String? proxyHost;
  final int? proxyPort;

  static const _kHomeserver = 'net_homeserver';
  static const _kToken = 'net_token';
  static const _kMode = 'net_mode';
  static const _kProxyHost = 'net_proxy_host';
  static const _kProxyPort = 'net_proxy_port';

  static Future<NetConfig> load() async {
    final url = await Account.read(_kHomeserver);
    final token = await Account.read(_kToken) ?? kDefaultRegistrationToken;
    final modeStr = await Account.read(_kMode);
    final host = await Account.read(_kProxyHost);
    final portStr = await Account.read(_kProxyPort);
    return NetConfig(
      homeserver: Uri.tryParse(url ?? '') ?? Uri.parse('https://invalid.invalid'),
      registrationToken: token,
      mode: NetMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => NetMode.direct,
      ),
      proxyHost: host,
      proxyPort: int.tryParse(portStr ?? ''),
    );
  }

  Future<void> save() async {
    await Account.write(_kHomeserver, homeserver.toString());
    await Account.write(_kToken, registrationToken);
    await Account.write(_kMode, mode.name);
    if (proxyHost != null) await Account.write(_kProxyHost, proxyHost!);
    if (proxyPort != null) await Account.write(_kProxyPort, proxyPort.toString());
  }

  NetConfig copyWith({
    Uri? homeserver,
    String? registrationToken,
    NetMode? mode,
    String? proxyHost,
    int? proxyPort,
  }) {
    return NetConfig(
      homeserver: homeserver ?? this.homeserver,
      registrationToken: registrationToken ?? this.registrationToken,
      mode: mode ?? this.mode,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
    );
  }

  /// Vrai si l'utilisateur a configuré un serveur. Sans ça, l'appli reste utilisable en mode
  /// Bluetooth (voir ui/mesh_screen.dart) mais ne peut pas se connecter au réseau.
  bool get isConfigured => homeserver.hasScheme && homeserver.host.isNotEmpty;

  /// Client HTTP adapté au mode choisi.
  http.Client httpClient() {
    switch (mode) {
      case NetMode.direct:
        return http.Client();
      case NetMode.tor:
        return _socksClient('127.0.0.1', 9050);
      case NetMode.customProxy:
        if (proxyHost == null || proxyPort == null) return http.Client();
        return _socksClient(proxyHost!, proxyPort!);
    }
  }

  static http.Client _socksClient(String host, int port) {
    final inner = HttpClient()..findProxy = (uri) => 'SOCKS5 $host:$port';
    return io.IOClient(inner);
  }
}

/// Test simple de blocage : si la connexion au homeserver échoue en mode direct, Murmure propose
/// de basculer automatiquement sur Tor (voir ui/onboarding_screen.dart).
Future<bool> canReach(Uri homeserver, {Duration timeout = const Duration(seconds: 6)}) async {
  if (!homeserver.hasScheme) return false;
  try {
    final resp = await http
        .get(Uri.parse('${homeserver.origin}/_matrix/client/versions'))
        .timeout(timeout);
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// Décode un message d'erreur JSON Matrix lisible, sans planter si la réponse n'est pas du JSON.
String describeMatrixError(String body) {
  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    return (j['error'] as String?) ?? body;
  } catch (_) {
    return body;
  }
}
