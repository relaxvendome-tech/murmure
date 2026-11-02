import 'package:matrix/matrix.dart';

import '../network.dart';

/// Politique d'appel : décide SI un appel peut démarrer et construit la configuration ICE à lui
/// donner, selon le mode réseau choisi par l'utilisateur (voir `docs/CALLS_ARCHITECTURE.md`).
///
/// LIMITE HONNÊTE — ce que ce fichier NE fait PAS : il ne lance aucun appel, n'intègre aucun
/// plugin WebRTC (`flutter_webrtc` n'est pas une dépendance de ce projet), et ne construit aucune
/// interface utilisateur. C'est une politique pure : "dans ce mode réseau, un appel est-il
/// autorisé, et si oui avec quelle configuration ICE ?". L'intégration réelle (signalisation
/// `matrix-dart-sdk` Voip, négociation SDP, rendu audio/vidéo, bannière d'avertissement visible
/// dans l'UI) reste à faire — voir la liste "Ce qui reste à faire" dans
/// `docs/CALLS_ARCHITECTURE.md`, qui n'est pas entièrement cochée par ce fichier seul.
///
/// Ce que ce fichier garantit, lui, dès qu'il est utilisé par l'implémentation d'appel réelle :
/// - Aucun serveur STUN n'est jamais inclus dans la configuration ICE retournée (le point 1 de
///   `docs/CALLS_ARCHITECTURE.md`).
/// - `iceTransportPolicy: 'relay'` est systématiquement forcé dès que le mode n'est pas direct
///   (point 3) — la garantie structurelle, pas une simple préférence.
/// - Aucun identifiant TURN statique : chaque appel réclame des identifiants neufs et de courte
///   durée via le mécanisme Matrix standard (`Client.getTurnServer()`, point 2/5), jamais une
///   valeur codée en dur dans le code source.
/// - Fail-closed : si le mode réseau n'est pas direct et qu'aucune configuration TURN exploitable
///   n'est obtenue, l'appel est refusé plutôt que de se rabattre silencieusement sur autre chose.
class CallPolicy {
  const CallPolicy._();

  /// Vrai si l'appel est autorisé dans ce mode réseau. En mode direct, toujours vrai (l'IP réelle
  /// part de toute façon vers le homeserver, comme pour le reste du trafic — rien à protéger de
  /// plus ici). En mode Tor/proxy, les appels restent désactivés jusqu'à ce que le reste de
  /// l'intégration (plugin WebRTC vérifié, capture réseau de contrôle — voir la checklist de
  /// `docs/CALLS_ARCHITECTURE.md`) soit réellement fait, pas seulement cette politique.
  ///
  /// Volontairement toujours `false` pour `NetMode.tor`/`NetMode.customProxy` pour l'instant : la
  /// politique ICE ci-dessous est prête, mais rien dans ce dépôt n'a encore vérifié par capture
  /// réseau qu'un plugin WebRTC donné respecte réellement `iceTransportPolicy: 'relay'` sans fuite
  /// (point de la checklist). Faire confiance à la seule configuration, sans cette vérification,
  /// serait exactement le genre d'affirmation non prouvée que cet audit a cherché à éliminer.
  static bool isAllowed(NetMode mode) => mode == NetMode.direct;

  /// Construit la configuration ICE à passer au plugin d'appel, en récupérant des identifiants
  /// TURN neufs auprès du homeserver (jamais codés en dur). Retourne `null` si l'appel n'est pas
  /// autorisé dans ce mode (voir [isAllowed]) ou si le homeserver ne fournit pas de serveur TURN
  /// exploitable — jamais un repli silencieux vers une configuration sans TURN.
  static Future<CallIceConfig?> buildIceConfig({
    required Client client,
    required NetMode mode,
  }) async {
    if (!isAllowed(mode)) return null;

    final TurnServerCredentials creds;
    try {
      creds = await client.getTurnServer();
    } catch (_) {
      // Pas de serveur TURN configuré côté homeserver (voir conduit.toml, turn_uris/turn_secret)
      // ou requête échouée : fail-closed, on ne construit pas de config ICE sans TURN plutôt que
      // de laisser WebRTC tenter sa chance avec des candidats host/srflx non maîtrisés.
      return null;
    }
    if (creds.uris.isEmpty) return null;

    return CallIceConfig(
      // Volontairement AUCUNE entrée `stun:` ici — voir le point 1 de
      // docs/CALLS_ARCHITECTURE.md : un serveur STUN ne sert qu'à révéler l'IP publique de
      // l'appelant, ce qu'on refuse précisément dès que le mode n'est pas direct.
      iceServers: [
        CallIceServer(
          urls: creds.uris,
          username: creds.username,
          credential: creds.password,
        ),
      ],
      // Garantie structurelle (point 3) : interdit à ICE de même GÉNÉRER un candidat host/srflx,
      // quelle que soit par ailleurs la liste de serveurs fournie.
      iceTransportPolicy: 'relay',
    );
  }
}

/// Configuration ICE prête à être passée à un plugin WebRTC (ex. `RTCConfiguration` de
/// `flutter_webrtc`, non intégré dans ce fichier — voir la LIMITE HONNÊTE en tête de fichier).
/// Type intermédiaire neutre plutôt qu'un type d'un plugin précis, pour ne pas lier cette
/// politique à un choix de plugin qui n'a pas encore été vérifié (voir la checklist de
/// `docs/CALLS_ARCHITECTURE.md`).
class CallIceConfig {
  const CallIceConfig({required this.iceServers, required this.iceTransportPolicy});
  final List<CallIceServer> iceServers;
  final String iceTransportPolicy;

  /// Forme attendue par la plupart des API WebRTC (dont `flutter_webrtc`'s `RTCConfiguration`),
  /// à adapter si besoin au plugin réellement choisi lors de l'implémentation de l'appel.
  Map<String, dynamic> toJson() => {
        'iceServers': iceServers.map((s) => s.toJson()).toList(),
        'iceTransportPolicy': iceTransportPolicy,
      };
}

class CallIceServer {
  const CallIceServer({required this.urls, required this.username, required this.credential});
  final List<String> urls;
  final String username;
  final String credential;

  Map<String, dynamic> toJson() => {
        'urls': urls,
        'username': username,
        'credential': credential,
      };
}
