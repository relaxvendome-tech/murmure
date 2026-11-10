import 'package:matrix/matrix.dart';

import '../network.dart';

/// Politique d'appel : décide SI un appel peut démarrer et construit la configuration ICE à lui
/// donner, selon le mode réseau choisi par l'utilisateur (voir `docs/CALLS_ARCHITECTURE.md`).
///
/// Trouvé en audit interne : ce commentaire de classe affirmait encore, jusqu'ici, que
/// « `flutter_webrtc` n'est pas une dépendance de ce projet » et que ce fichier ne faisait que
/// construire une politique sans intégration réelle — exact au moment où ce fichier a été écrit en
/// premier (voir `docs/CALLS_ARCHITECTURE.md`, section « Décisions prises... »), mais plus du tout
/// depuis : `flutter_webrtc` est déclaré dans `pubspec.yaml`, et `lib/calls/services/
/// call_manager.dart` (`MurmureWebRTCDelegate.createPeerConnection`) utilise réellement cette
/// politique pour construire chaque connexion WebRTC, entrante comme sortante — voir
/// `docs/CALLS_ARCHITECTURE.md`, section « ce qui est fait, ce qui ne l'est pas ». Laisser ce
/// commentaire périmé à côté des garanties de sécurité ci-dessous risquait de faire croire à tort
/// qu'aucune de ces garanties n'est câblée dans l'appli réelle, alors qu'elles le sont. Ce fichier
/// reste néanmoins une politique pure au sens où il ne contient lui-même aucun appel à
/// `flutter_webrtc` ni à l'UI — c'est `call_manager.dart` qui l'utilise.
///
/// LIMITE HONNÊTE RESTANTE, elle, toujours vraie : rien ici n'a été vérifié par capture réseau
/// (Wireshark/tcpdump) sur un appareil physique — voir la case non cochée correspondante dans
/// `docs/CALLS_ARCHITECTURE.md`. C'est précisément pourquoi [isAllowed] reste `false` hors mode
/// direct, quelle que soit la qualité de la configuration ICE construite ci-dessous.
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
    // Défense en profondeur : ne garder QUE des URI TURN, même si le homeserver renvoyait une
    // entrée stun: (mauvaise config ou serveur compromis). Plus aucune URI exploitable → refus.
    // matrix >= 9 : `TurnServerCredentials.uris` est une `List<Uri>` (plus `List<String>`) ; on
    // filtre sur sa forme texte, exactement comme avant.
    final turnUris = creds.uris
        .map((u) => u.toString().trim())
        .where((u) {
          final l = u.toLowerCase();
          return l.startsWith('turn:') || l.startsWith('turns:');
        })
        .toList(growable: false);
    if (turnUris.isEmpty) return null;

    return CallIceConfig(
      // Volontairement AUCUNE entrée `stun:` ici — voir le point 1 de
      // docs/CALLS_ARCHITECTURE.md : un serveur STUN ne sert qu'à révéler l'IP publique de
      // l'appelant, ce qu'on refuse précisément dès que le mode n'est pas direct.
      iceServers: [
        CallIceServer(
          urls: turnUris,
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
