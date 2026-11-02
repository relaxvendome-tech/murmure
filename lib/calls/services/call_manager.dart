import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart';

import '../../network.dart';
import '../call_policy.dart';

/// Lancé par [MurmureWebRTCDelegate.createPeerConnection] quand la politique réseau interdit
/// l'appel (voir [CallPolicy]). C'est le SEUL endroit par lequel `matrix-dart-sdk` (via `VoIP`/
/// `CallSession`) crée réellement une `RTCPeerConnection` — que l'appel soit sortant ou qu'il
/// arrive d'un correspondant — donc c'est le point d'application structurel du fail-closed, pas
/// une simple vérification faite avant d'appeler une fonction d'aide qu'on pourrait contourner.
class CallBlockedException implements Exception {
  const CallBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Pont entre `matrix-dart-sdk` (`VoIP`/`CallSession` — la vraie implémentation de la
/// signalisation Matrix : `m.call.invite`/`candidates`/`answer`/`hangup`, avec `party_id` et
/// gestion du « glare » déjà correctement gérés par le SDK) et `flutter_webrtc`.
///
/// Remplace une proposition reçue pendant le développement de cette fonctionnalité
/// (`MatrixVoipSignaling`) qui réimplémentait à la main l'envoi des événements `m.call.*`, avec un
/// bug réel et sérieux : elle appelait `room.sendEvent(content)` sans jamais préciser le paramètre
/// nommé `type:`, qui vaut par défaut `m.room.message` dans `matrix-dart-sdk`. Ses événements
/// seraient donc partis comme de simples messages de discussion chiffrés contenant un `msgtype`
/// non standard — invisibles pour tout client Matrix respectant la spec, y compris ce SDK lui-même
/// côté réception — jamais comme de vrais événements d'appel. Elle omettait aussi `party_id`
/// (obligatoire depuis MSC2746 pour la résolution de conflits entre appareils, le « glare ») et
/// prétendait gérer la réception des appels alors qu'aucun code de réception n'y figurait. Plutôt
/// que de corriger cette réimplémentation partielle d'un protocole déjà normalisé, ce fichier
/// utilise directement `VoIP`/`CallSession`, qui fait déjà tout cela correctement : moins de code,
/// et une signalisation réellement conforme à la spec Matrix.
class MurmureWebRTCDelegate extends WebRTCDelegate {
  MurmureWebRTCDelegate({required this.client});

  final Client client;

  /// Rempli par l'appli (voir `main.dart`) pour naviguer vers l'écran d'appel sans avoir à faire
  /// transiter un `BuildContext` jusqu'ici — ce delegate est construit avant tout arbre de
  /// widgets.
  GlobalKey<NavigatorState>? navigatorKey;

  /// Rempli par l'appli pour construire l'écran d'appel à partir d'une [CallSession] : ce fichier
  /// ne dépend pas de `lib/calls/ui/call_session_screen.dart` pour éviter un cycle d'imports
  /// inutile (ui → services → ui).
  Widget Function(CallSession session)? buildCallScreen;

  CallSession? _active;

  @override
  bool get canHandleNewCall => _active == null;

  @override
  bool get isWeb => false;

  @override
  EncryptionKeyProvider? get keyProvider => null;

  @override
  webrtc.MediaDevices get mediaDevices => webrtc.navigator.mediaDevices;

  /// Point d'application du fail-closed (voir [CallBlockedException] ci-dessus). Ignore
  /// délibérément la configuration ICE que `CallSession` calcule elle-même en interne — dont on ne
  /// maîtrise ni ne vérifie la politique — et la remplace TOUJOURS par celle de [CallPolicy],
  /// construite à partir du mode réseau relu à l'instant (jamais mis en cache ici, pour refléter
  /// un changement de mode réseau fait pendant la session) et d'identifiants TURN dynamiques
  /// (jamais un secret codé en dur).
  @override
  Future<webrtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) async {
    final net = await NetConfig.load();
    final iceConfig = await CallPolicy.buildIceConfig(client: client, mode: net.mode);
    if (iceConfig == null) {
      throw const CallBlockedException(
        'Appel refusé par la politique réseau (voir docs/CALLS_ARCHITECTURE.md) : aucune '
        'connexion WebRTC ne peut être créée dans ce mode tant que son étanchéité n\'a pas été '
        'vérifiée par capture réseau.',
      );
    }
    return webrtc.createPeerConnection(iceConfig.toJson(), constraints);
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    _active = session;
    final builder = buildCallScreen;
    if (builder == null) return;
    navigatorKey?.currentState?.push(MaterialPageRoute(builder: (_) => builder(session)));
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    if (_active == session) _active = null;
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    if (_active == session) _active = null;
    // Pas de notification d'appel manqué dans cette passe (hors scope, voir
    // docs/CALLS_ARCHITECTURE.md) : l'utilisateur voit seulement l'historique de la conversation.
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    // Appels de groupe non implémentés dans cette passe (voir docs/CALLS_ARCHITECTURE.md) :
    // Murmure ne propose aucune action pour en démarrer, donc aucun flux entrant n'est attendu
    // ici en pratique — laissé explicite plutôt que silencieusement non géré.
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}

  @override
  Future<void> registerListeners(CallSession session) async {}

  @override
  Future<void> playRingtone() async {
    // TODO (hors scope de cette passe) : sonnerie visible/sonore à l'arrivée d'un appel.
  }

  @override
  Future<void> stopRingtone() async {}
}

/// Point d'entrée unique pour démarrer un appel sortant, et porte d'accès à [VoIP] pour le reste
/// de l'appli — construit une seule fois dans `main.dart`, aux côtés du [Client] Matrix.
class CallManager {
  CallManager({required Client client}) : delegate = MurmureWebRTCDelegate(client: client) {
    voip = VoIP(client, delegate);
  }

  final MurmureWebRTCDelegate delegate;
  late final VoIP voip;

  /// Démarre un appel sortant vers [room]. Vérifie la politique réseau ICI, avant même d'envoyer
  /// un `m.call.invite` — pas seulement au moment de créer la connexion WebRTC (qui refuserait de
  /// toute façon, voir [MurmureWebRTCDelegate.createPeerConnection]), pour ne pas faire sonner le
  /// correspondant pour un appel qui ne pourra jamais aboutir. Retourne `null` si le mode réseau
  /// ne permet pas l'appel (voir [CallPolicy.isAllowed]) — à l'appelant de montrer un message
  /// explicite, jamais un échec silencieux.
  Future<CallSession?> startCall(Room room, {required CallType type}) async {
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) return null;
    final session = await voip.inviteToCall(room, type);
    delegate._active = session;
    return session;
  }
}
