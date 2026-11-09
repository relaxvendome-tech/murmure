import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;
import 'package:socks5_proxy/socks_client.dart';

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
  ///
  /// IMPORTANT : `HttpClient.findProxy` (dart:io) ne comprend QUE les formats "DIRECT" et
  /// "PROXY host:port" (un proxy HTTP CONNECT) — "SOCKS5 host:port" n'est pas un format reconnu
  /// et était silencieusement ignoré dans une version antérieure de ce fichier, ce qui faisait
  /// croire à l'utilisateur qu'il passait par Tor alors que tout partait en direct. On utilise
  /// maintenant un vrai client SOCKS5 (`socks5_proxy`) qui enveloppe les connexions TCP, y compris
  /// TLS, au niveau du socket.
  ///
  /// Échoue plutôt que de retomber sur une connexion directe (« fail closed ») : pour quelqu'un
  /// qui compte sur Tor ou un proxy pour ne pas révéler son IP réelle, un repli silencieux vers le
  /// direct serait pire qu'une erreur visible.
  Future<http.Client> httpClient() async {
    switch (mode) {
      case NetMode.direct:
        return http.Client();
      case NetMode.tor:
        return _socksClient(InternetAddress.loopbackIPv4, 9050);
      case NetMode.customProxy:
        if (proxyHost == null || proxyHost!.isEmpty || proxyPort == null) {
          throw const ProxyConfigError('Adresse ou port du proxy SOCKS5 manquant');
        }
        final literal = InternetAddress.tryParse(proxyHost!);
        if (literal != null) return _socksClient(literal, proxyPort!);
        // Corrigé : la résolution DNS du nom d'hôte du proxy se faisait ICI, au démarrage
        // (main.dart appelle httpClient() avant d'afficher quoi que ce soit) — hors ligne, la
        // résolution levait et l'appli ne démarrait plus du tout (pas même le mode Bluetooth).
        // Elle est maintenant paresseuse : faite au premier envoi de requête, et retentée au
        // suivant en cas d'échec. Toujours « fail closed » : un échec de résolution lève
        // ProxyConfigError, jamais de repli vers une connexion directe.
        return _LazySocksClient(proxyHost!, proxyPort!);
    }
  }

  static http.Client _socksClient(InternetAddress host, int port) {
    final inner = HttpClient();
    SocksTCPClient.assignToHttpClient(inner, [ProxySettings(host, port)]);
    return io.IOClient(inner);
  }
}

/// Client SOCKS5 dont le proxy est désigné par NOM D'HÔTE : la résolution DNS n'a lieu qu'au
/// premier [send] (voir [NetConfig.httpClient]). Toutes les requêtes passent par le client SOCKS
/// interne ; si la résolution échoue, [send] lève [ProxyConfigError] — aucun chemin ne mène
/// jamais à une connexion directe.
class _LazySocksClient extends http.BaseClient {
  _LazySocksClient(this._host, this._port);

  final String _host;
  final int _port;
  Future<http.Client>? _inner;
  bool _closed = false;

  Future<http.Client> _resolve() async {
    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(_host);
    } on SocketException {
      throw ProxyConfigError('Impossible de résoudre l\'adresse du proxy : $_host');
    }
    if (addrs.isEmpty) {
      throw ProxyConfigError('Impossible de résoudre l\'adresse du proxy : $_host');
    }
    return NetConfig._socksClient(addrs.first, _port);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client fermé', request.url);
    final pending = _inner ??= _resolve();
    http.Client inner;
    try {
      inner = await pending;
    } catch (_) {
      // Échec de résolution : on oublie la tentative pour réessayer au prochain envoi (le réseau
      // peut revenir), et on remonte l'erreur telle quelle (ProxyConfigError).
      if (identical(_inner, pending)) _inner = null;
      rethrow;
    }
    if (_closed) {
      inner.close();
      throw http.ClientException('Client fermé', request.url);
    }
    return inner.send(request);
  }

  @override
  void close() {
    _closed = true;
    final pending = _inner;
    _inner = null;
    pending?.then((c) => c.close(), onError: (_) {});
  }
}

/// Le mode choisi exige un proxy (Tor, SOCKS5 personnalisé) mais ses réglages sont absents ou
/// invalides. Volontairement distinct d'un simple échec réseau : l'appelant ne doit jamais
/// confondre « proxy mal configuré » avec « serveur injoignable » et basculer en direct par erreur.
class ProxyConfigError implements Exception {
  const ProxyConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Test simple de blocage : si la connexion au homeserver échoue en mode direct, Murmure propose
/// de basculer automatiquement sur Tor (voir ui/onboarding_screen.dart).
///
/// Prend le client à utiliser EN PARAMÈTRE plutôt que d'en créer un en direct à l'intérieur : la
/// version précédente créait toujours un `http.get` direct ici, donc même le test « est-ce que Tor
/// fonctionne ? » ne passait jamais par Tor — il retestait deux fois la même connexion directe.
Future<bool> canReach(
  Uri homeserver, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (!homeserver.hasScheme) return false;
  try {
    final resp = await client
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
