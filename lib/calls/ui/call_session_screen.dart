import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

import '../../lock.dart';
import '../services/call_manager.dart';
import '../services/call_opsec_notifier.dart';
import '../services/call_opsec_store.dart';

/// Écran d'appel : UI fine au-dessus d'une [CallSession] (`matrix-dart-sdk`), qui possède
/// elle-même la connexion WebRTC et la signalisation Matrix (`m.call.*`, avec `party_id` et
/// gestion du « glare » déjà correctement gérées par le SDK).
///
/// Remplace une version antérieure de cet écran qui créait sa propre `RTCPeerConnection` à la
/// main ET une version proposée pendant le développement qui hand-roulait l'envoi des événements
/// `m.call.*` (avec un bug réel : `type:` jamais précisé sur `sendEvent`, donc des messages de
/// discussion ordinaires au lieu de vrais événements d'appel — voir
/// `lib/calls/services/call_manager.dart` pour le détail). Toute l'application de la politique
/// réseau (zéro STUN, `iceTransportPolicy: relay` forcé, identifiants TURN dynamiques,
/// fail-closed) vit maintenant dans `MurmureWebRTCDelegate.createPeerConnection` — le seul point
/// par lequel [CallSession] crée réellement une connexion WebRTC. Cet écran n'a plus besoin de
/// s'en occuper, et ne pourrait de toute façon pas la contourner : il ne voit que ce que
/// [CallSession] choisit de lui montrer (flux locaux/distants, état de l'appel).
class CallSessionScreen extends StatefulWidget {
  const CallSessionScreen({super.key, required this.session});
  final CallSession session;

  @override
  State<CallSessionScreen> createState() => _CallSessionScreenState();
}

class _CallSessionScreenState extends State<CallSessionScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  WrappedMediaStream? _localFeed;
  bool _isMuted = false;
  bool _answered = false;

  StreamSubscription<WrappedMediaStream>? _addSub;
  StreamSubscription<WrappedMediaStream>? _removeSub;
  StreamSubscription<CallState>? _stateSub;
  bool _missedRecorded = false;

  /// Vrai dès que l'utilisateur refuse l'appel entrant ([_decline]) : un refus volontaire n'est
  /// pas un « appel manqué » et ne doit ni être enregistré ni notifié.
  bool _declined = false;

  /// Trouvé en audit interne (revue croisée IA, confirmé en relisant ce fichier) : vrai dans tous
  /// les chemins qui terminent proprement la session (`_decline`, `_hangUp`, ou la fin détectée à
  /// distance ci-dessous) — jamais mis à vrai par une simple fermeture d'écran (bouton retour
  /// système, navigation externe). Sert à la fois à éviter un double `pop()` quand la fin à
  /// distance et l'action locale se recoupent, et de signal pour [dispose] : si cet écran disparaît
  /// sans être passé par `_closing = true`, la session WebRTC (donc le micro) n'a jamais été
  /// explicitement raccrochée.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    // Trouvé en audit interne : cet écran est poussé avec `_answered = false` (déclaration du
    // champ), donc son tout premier rendu affiche systématiquement l'écran de sonnerie entrante
    // (boutons décrocher/raccrocher) — y compris pour un appel SORTANT, où c'est à la fois faux et
    // déroutant pour l'appelant. La ligne `_answered = widget.session.isOutgoing;` qui corrigeait
    // ça plus bas n'était qu'une AFFECTATION DE CHAMP, jamais enveloppée dans un setState : pour un
    // appel sortant, rien ne redemandait de reconstruire l'écran après coup. En pratique, un flux
    // média qui arrive peu après (_attach, qui appelle bien setState) finit souvent par masquer le
    // problème par effet de bord — mais rien ne le garantit (permission micro lente, négociation
    // WebRTC qui traîne), et un appelant resterait alors bloqué sur l'écran "Appel entrant…" de son
    // propre appel sortant tant qu'aucun autre setState ne survient.
    if (!mounted) return;

    // Corrigé : un ancien commentaire affirmait que `CachedStreamController` rejoue aux nouveaux
    // abonnés les flux déjà présents — FAUX au tag v0.29.0 (simple StreamController.broadcast qui
    // mémorise la dernière valeur sans jamais la réémettre). Les flux ajoutés avant cet abonnement
    // (local d'un appel sortant, ajouté pendant `initOutboundCall` ; écran poussé tardivement par
    // `presentPendingCall`) étaient donc perdus : vidéo locale noire et bouton micro inopérant.
    // On s'abonne d'abord, puis on rattache explicitement les flux déjà présents (_attach est
    // idempotent).
    _addSub = widget.session.onStreamAdd.stream.listen(_attach);
    _removeSub = widget.session.onStreamRemoved.stream.listen(_detach);
    for (final feed in widget.session.getLocalStreams) {
      _attach(feed);
    }
    for (final feed in widget.session.getRemoteStreams) {
      _attach(feed);
    }

    // Détection d'un appel manqué : un appel ENTRANT qui atteint `kEnded` sans jamais avoir été
    // décroché (voir [_accept]). Remplace une proposition reçue dans cette conversation qui
    // reconstruisait cette détection à la main par-dessus un événement `m.call.hangup` brut et
    // une API qui n'existe pas dans ce SDK (`voip.currentSession`) — l'état de CallSession
    // lui-même est la source de vérité correcte, pas un événement réinterprété de l'extérieur.
    // Trouvé en audit interne (revue croisée IA) : seul le cas « appel manqué » (jamais décroché)
    // réagissait à `kEnded` — un appel DÉCROCHÉ puis terminé par le correspondant (raccroché à
    // distance) ne déclenchait jamais `_hangUp`/`_decline` localement, donc cet écran restait
    // affiché indéfiniment (micro ouvert, vidéo figée) jusqu'à un retour manuel de l'utilisateur.
    // `_closing` évite un double `pop()` quand la fin à distance et une action locale
    // (`_decline`/`_hangUp`, qui pop déjà elles-mêmes) se recoupent.
    _stateSub = widget.session.onCallStateChanged.stream.listen(_onCallState);

    setState(() {
      _answered = widget.session.isOutgoing || widget.session.answeredByUs;
      _isMuted = widget.session.isMicrophoneMuted;
    });

    // Même raison que pour les flux : un `kEnded` survenu avant l'abonnement (pendant
    // l'initialisation des renderers) ne serait jamais réémis — l'écran resterait affiché sur un
    // appel terminé. On traite donc l'état courant une fois abonné.
    if (widget.session.callHasEnded) _onCallState(CallState.kEnded);
  }

  void _onCallState(CallState state) {
    if (state != CallState.kEnded) return;
    final session = widget.session;
    // Pas un appel manqué : appel sortant, décroché (ici ou par nous), refusé volontairement, ou
    // décroché sur un autre de nos appareils (`answeredElsewhere`).
    if (!_answered &&
        !_declined &&
        !session.isOutgoing &&
        !session.answeredByUs &&
        session.hangupReason != CallErrorCode.answeredElsewhere &&
        !_missedRecorded) {
      _missedRecorded = true;
      unawaited(_recordMissedCall());
    }
    if (!_closing) {
      _closing = true;
      _closeOwnRoute();
    }
  }

  /// Ferme la route de CET écran, et seulement elle. Un simple `Navigator.pop()` fermait la route
  /// au sommet de la pile — pas forcément la nôtre (dialogue ou autre écran poussé par-dessus, ou
  /// second écran d'appel), d'où la fermeture du mauvais écran.
  void _closeOwnRoute() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _attach(WrappedMediaStream feed) {
    if (!mounted) return;
    setState(() {
      if (feed.isLocal()) {
        _localFeed = feed;
        _localRenderer.srcObject = feed.stream;
      } else {
        _remoteRenderer.srcObject = feed.stream;
      }
    });
  }

  void _detach(WrappedMediaStream feed) {
    if (!mounted) return;
    setState(() {
      if (feed.isLocal()) {
        if (_localFeed == feed) _localFeed = null;
        _localRenderer.srcObject = null;
      } else {
        _remoteRenderer.srcObject = null;
      }
    });
  }

  /// Écrit l'appel manqué dans l'historique chiffré (voir [CallOpsecStore], directive explicite
  /// de l'utilisateur : exclusivement dans la base SQLCipher, jamais un journal en clair) et
  /// déclenche la notification camouflée — sans bloquer sur quoi que ce soit côté UI, l'appel est
  /// de toute façon en train de se terminer.
  Future<void> _recordMissedCall() async {
    // Aucune trace (historique ni notification) pour un correspondant bloqué.
    final remote = widget.session.remoteUserId;
    try {
      if (remote != null && widget.session.room.client.ignoredUsers.contains(remote)) return;
    } catch (_) {}
    try {
      await CallOpsecStore.insert(MissedCall(
        roomId: widget.session.room.id,
        remoteUserId: widget.session.remoteUserId,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      await CallOpsecNotifier.notifyMissedCall();
    } catch (_) {
      // Best-effort : jamais de crash ni de log de contenu pour un historique raté.
    }
  }

  Future<void> _accept() async {
    setState(() => _answered = true);
    await widget.session.answer();
  }

  Future<void> _decline() async {
    _declined = true;
    _closing = true;
    try {
      await widget.session.reject();
    } catch (_) {}
    _closeOwnRoute();
  }

  /// Corrigé : `WrappedMediaStream.setAudioMuted` ne fait que basculer un drapeau et émettre un
  /// événement — il ne désactive AUCUNE piste audio : le micro continuait d'émettre alors que
  /// l'icône affichait « coupé ». `CallSession.setMicrophoneMuted` met à jour ce drapeau PUIS
  /// applique `track.enabled = false` aux pistes audio locales (`updateMuteStatus`) et prévient le
  /// correspondant (métadonnées SDP).
  Future<void> _toggleMute() async {
    final session = widget.session;
    try {
      await session.setMicrophoneMuted(!session.isMicrophoneMuted);
    } catch (_) {
      // L'envoi des métadonnées peut échouer (réseau) ; les pistes, elles, sont déjà basculées
      // localement avant cet envoi — l'icône ci-dessous reflète l'état réel de la session.
    }
    if (!mounted) return;
    setState(() => _isMuted = session.isMicrophoneMuted);
  }

  Future<void> _hangUp() async {
    _closing = true;
    try {
      await widget.session.hangup(reason: CallErrorCode.userHangup);
    } catch (_) {}
    _closeOwnRoute();
  }

  @override
  void dispose() {
    // Trouvé en audit interne (revue croisée IA, confirmé en relisant ce fichier) : avant ce
    // correctif, rien ici ne raccrochait la session si l'écran disparaissait sans passer par
    // `_decline`/`_hangUp` — en particulier le bouton retour système (ce fichier n'a pas de
    // PopScope qui l'intercepte). Dans ce cas, la `CallSession` restait active côté SDK (micro
    // potentiellement ouvert) jusqu'à un éventuel timeout, sans que l'utilisateur ne le sache.
    // Filet de sécurité générique plutôt qu'une interception du bouton retour spécifique : couvre
    // aussi une navigation externe forcée (ex. verrouillage automatique qui remplace tout l'arbre
    // de widgets). `unawaited` : dispose() ne peut pas être async, et on ne bloque pas la
    // destruction de l'écran sur la confirmation réseau du raccroché.
    // Écran fermé par le REVERROUILLAGE alors qu'un appel entrant sonne encore sans avoir été
    // décroché : on ne raccroche pas (ce serait un refus que l'utilisateur n'a jamais fait). La
    // session est rendue au chemin verrouillé du delegate : elle continue de sonner, sera
    // enregistrée comme manquée si elle se termine, et sera de nouveau présentée par
    // `presentPendingCall` après déverrouillage. Notre propre abonnement d'état est annulé
    // ci-dessous, donc aucun doublon d'appel manqué.
    if (!_closing && _shouldHandBackToLockedPath()) {
      final delegate = widget.session.voip.delegate;
      if (delegate is MurmureWebRTCDelegate && delegate.trackLockedIncoming(widget.session)) {
        _closing = true;
      }
    }
    if (!_closing) {
      _closing = true;
      unawaited(widget.session.hangup(reason: CallErrorCode.userHangup).catchError((_) {}));
    }
    _addSub?.cancel();
    _removeSub?.cancel();
    _stateSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  bool _shouldHandBackToLockedPath() {
    final session = widget.session;
    return !AppLock.isUnlocked &&
        !_answered &&
        !_declined &&
        !session.isOutgoing &&
        !session.isGroupCall &&
        !session.answeredByUs &&
        !session.callHasEnded &&
        session.isRinging;
  }

  @override
  Widget build(BuildContext context) {
    if (!_answered) {
      // Appel entrant pas encore décroché : écran de sonnerie, pas directement l'écran d'appel —
      // décrocher automatiquement sans confirmation serait une mauvaise surprise pour
      // l'utilisateur (micro/caméra activés sans qu'il l'ait voulu).
      return Scaffold(
        backgroundColor: const Color(0xFF17171C),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.call, color: Colors.white, size: 48),
              const SizedBox(height: 16),
              const Text('Appel entrant…', style: TextStyle(color: Colors.white, fontSize: 20)),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.red,
                    radius: 32,
                    child: IconButton(
                      icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
                      onPressed: _decline,
                    ),
                  ),
                  CircleAvatar(
                    backgroundColor: Colors.green,
                    radius: 32,
                    child: IconButton(
                      icon: const Icon(Icons.call, color: Colors.white, size: 28),
                      onPressed: _accept,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF17171C),
      body: Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
          Positioned(
            top: 48,
            right: 24,
            width: 120,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            ),
          ),
          Positioned(
            bottom: 48,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                CircleAvatar(
                  backgroundColor: _isMuted ? Colors.red : Colors.grey[800],
                  radius: 28,
                  child: IconButton(
                    icon: Icon(_isMuted ? Icons.mic_off : Icons.mic, color: Colors.white),
                    onPressed: _toggleMute,
                  ),
                ),
                CircleAvatar(
                  backgroundColor: Colors.red,
                  radius: 32,
                  child: IconButton(
                    icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
                    onPressed: _hangUp,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
