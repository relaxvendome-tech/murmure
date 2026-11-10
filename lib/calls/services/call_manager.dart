import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart';
// Type attendu par `WebRTCDelegate.mediaDevices` (matrix-dart-sdk) : celui de la couche
// d'abstraction `webrtc_interface`, PAS le `MediaDevices` propre à `flutter_webrtc` lui-même
// (deux classes distinctes pour l'analyseur Dart, même si `flutter_webrtc` implémente et
// renvoie bien, à l'exécution, une instance compatible avec celle-ci).
import 'package:webrtc_interface/webrtc_interface.dart' show MediaDevices;

import '../../lock.dart';
import '../../network.dart';
import '../call_policy.dart';
import 'call_opsec_notifier.dart';
import 'call_opsec_store.dart';

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

  /// Renseigné par [CallManager] juste après la construction de [VoIP] : permet à
  /// [createPeerConnection] de rejeter les sessions orphelines quand la politique réseau refuse
  /// l'appel (voir [_rejectOrphanSessions]).
  VoIP? voip;

  CallSession? _active;
  StreamSubscription<CallState>? _activeStateSub;
  DateTime? _activeSince;

  /// Sessions remises à [handleNewCall] (donc déjà « prises en charge » : écran d'appel ou chemin
  /// verrouillé, qui enregistrent eux-mêmes l'appel manqué). Sert à [handleMissedCall] pour ne
  /// compter que les appels manqués jamais présentés (refus « occupé » du SDK notamment), sans
  /// doublon avec l'écran.
  final Expando<bool> _presented = Expando<bool>('murmure_call_presented');

  /// Appel entrant arrivé pendant que l'appli était verrouillée (voir [handleNewCall]) et
  /// l'abonnement qui enregistrera l'appel manqué s'il n'est jamais présenté — repris par
  /// [presentPendingCall] au déverrouillage.
  CallSession? _pendingLockedCall;
  StreamSubscription<CallState>? _pendingLockedSub;

  /// Vrai seulement si un appel est réellement « vivant » côté utilisateur : appel sortant,
  /// appel entrant décroché par nous (ou en cours de décroché), ou appel connecté. Une simple
  /// sonnerie entrante non décrochée ne compte PAS : elle ne doit pas différer le reverrouillage.
  bool get hasLiveCall {
    final s = _active;
    if (s == null || s.callHasEnded) return false;
    if (s.isOutgoing || s.answeredByUs) return true;
    switch (s.state) {
      case CallState.kCreateAnswer:
      case CallState.kConnecting:
      case CallState.kConnected:
        return true;
      default:
        return false;
    }
  }

  /// À appeler après un déverrouillage réussi : si un appel entrant a sonné pendant que l'appli
  /// était verrouillée et sonne ENCORE, pousse maintenant son écran d'appel. L'écran reprend
  /// alors l'enregistrement d'un éventuel appel manqué (l'abonnement du chemin verrouillé est
  /// annulé pour éviter un doublon). Sans effet si rien n'est en attente, si l'appli est encore
  /// verrouillée ou si l'appel ne sonne plus (le chemin verrouillé l'enregistre alors lui-même).
  void presentPendingCall() {
    final session = _pendingLockedCall;
    if (session == null) return;
    if (!AppLock.isUnlocked) return;
    if (session.callHasEnded || !session.isRinging) return;
    if (isBlockedSession(session)) return; // bloqué entre-temps : jamais présenté
    final builder = buildCallScreen;
    final nav = navigatorKey?.currentState;
    if (builder == null || nav == null) return;
    _pendingLockedSub?.cancel();
    _pendingLockedSub = null;
    _pendingLockedCall = null;
    nav.push(MaterialPageRoute(builder: (_) => builder(session)));
  }

  /// Vrai si une fin d'appel entrant doit être comptée comme « appel manqué » : jamais décroché
  /// par nous, et pas décroché sur un autre de nos appareils.
  static bool _countsAsMissed(CallSession session) =>
      !session.isOutgoing &&
      !session.isGroupCall &&
      !session.answeredByUs &&
      session.hangupReason != CallErrorCode.answeredElsewhere;

  /// Vrai si le correspondant de [session] figure dans la liste des utilisateurs bloqués
  /// (`m.ignored_user_list`, voir [Client.ignoredUsers]). Relu à chaque fois : un blocage fait
  /// pendant la session de l'appli doit prendre effet immédiatement.
  bool isBlockedSession(CallSession session) {
    final remote = session.remoteUserId;
    if (remote == null) return false;
    try {
      return client.ignoredUsers.contains(remote);
    } catch (_) {
      return false;
    }
  }

  /// Enregistre l'appel manqué (historique chiffré + notification), SAUF s'il vient d'un
  /// utilisateur bloqué : un correspondant bloqué ne doit laisser aucune trace visible.
  Future<void> _recordMissed(CallSession session) async {
    if (isBlockedSession(session)) return;
    try {
      await CallOpsecStore.insert(MissedCall(
        roomId: session.room.id,
        remoteUserId: session.remoteUserId,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      await CallOpsecNotifier.notifyMissedCall();
    } catch (_) {
      // Best-effort : un historique raté ne doit jamais faire planter la gestion d'appel.
    }
  }

  /// Trouvé en audit interne (revue croisée à 5 IA, point de vigilance soulevé indépendamment
  /// par ChatGPT et Qwen sur le correctif [activeCallNotifier] ci-dessous, demande explicite de
  /// l'utilisateur d'implémenter un garde-fou) : si `matrix-dart-sdk` ne signale JAMAIS
  /// `CallState.kEnded` pour une session donnée — coupure réseau silencieuse côté correspondant,
  /// bug du SDK, événement `m.call.hangup` perdu — ni [_watchActive] ni [handleCallEnded]/
  /// [handleMissedCall] ne libéreront jamais [_active]. [LockGate] (voir `ui/lock_screens.dart`)
  /// différerait alors le reverrouillage automatique INDÉFINIMENT, jusqu'au prochain redémarrage
  /// de l'appli — un échec OUVERT (fail-open) sur la fonctionnalité de sécurité que ce correctif
  /// vient justement ajouter. Deux filets de sûreté périodiques, aucun des deux ne touchant
  /// jamais à la session WebRTC elle-même (on ne raccroche RIEN ici, on ne fait que relâcher
  /// notre propre drapeau si l'état qu'il reflète semble obsolète) :
  /// 1. Re-synchronisation : si [_active] existe déjà mais que `.state` vaut `kEnded` (le flux
  ///    [_activeStateSub] a pu se fermer sans émettre cette valeur, ou l'abonnement a pu rater
  ///    l'événement), on libère immédiatement — défensif, redondant avec [_watchActive] en
  ///    fonctionnement normal.
  /// 2. Durée maximale : si [_active] reste non-null en continu depuis plus de
  ///    [_maxActiveCallAge] (6 h, volontairement bien au-delà de tout appel réel), on considère
  ///    l'état comme obsolète et on le libère quand même. Un vrai appel de plus de 6 h perdrait
  ///    alors sa protection contre le relock — un compromis délibéré : le risque qu'un SDK
  ///    défaillant désactive le verrou de sécurité PERMANENTE pour le reste de la session de
  ///    l'appli est pire que celui, extrêmement rare, de reverrouiller pendant un appel
  ///    anormalement long.
  static const _maxActiveCallAge = Duration(hours: 6);
  Timer? _watchdogTimer;

  void _startWatchdog() {
    _watchdogTimer ??= Timer.periodic(const Duration(minutes: 5), (_) {
      final active = _active;
      final since = _activeSince;
      if (active == null) return;
      final stale = active.state == CallState.kEnded ||
          (since != null && DateTime.now().difference(since) > _maxActiveCallAge);
      if (stale) {
        _active = null;
        _activeSince = null;
        activeCallNotifier.value = false;
        _activeStateSub?.cancel();
        _activeStateSub = null;
      }
    });
  }

  @override
  bool get canHandleNewCall => _active == null;

  /// Trouvé en audit interne (revue croisée à 5 IA, consensus unanime sur la question ouverte du
  /// reverrouillage automatique pendant un appel — voir [LockGate._relock] dans
  /// `ui/lock_screens.dart`) : expose ici, PAS comme un simple getter ponctuel mais comme un
  /// [ValueNotifier] observable, le fait qu'un appel soit actuellement en cours. [LockGate] n'a
  /// aucune autre façon de savoir qu'un appel se termine PENDANT qu'il attend déjà (différer le
  /// reverrouillage ne suffit pas s'il ne se déclenche jamais quand l'appel finit par se
  /// terminer) — un simple `bool get hasActiveCall` ponctuel aurait obligé [LockGate] à faire du
  /// polling, inutilement coûteux et potentiellement en retard de plusieurs secondes.
  final ValueNotifier<bool> activeCallNotifier = ValueNotifier(false);

  /// Verrou de sûreté, en plus de [handleCallEnded]/[handleMissedCall] : si
  /// [createPeerConnection] refuse l'appel (fail-closed, voir [CallBlockedException]) AVANT que
  /// le SDK n'ait eu l'occasion d'appeler l'un de ces deux callbacks pour nettoyer, [_active]
  /// resterait sinon bloqué sur cette session en échec — et [canHandleNewCall] resterait `false`
  /// pour le reste de la session de l'appli, bloquant silencieusement TOUS les appels suivants
  /// (y compris légitimes, en mode direct) après le premier appel refusé. On observe donc
  /// directement l'état de la session dès qu'elle devient "active" ici, et on libère [_active]
  /// dès `CallState.kEnded`, quoi qu'il arrive par ailleurs côté SDK.
  void _watchActive(CallSession session) {
    // Idempotent : pour un appel sortant, le SDK appelle déjà [handleNewCall] (donc ceci) avant
    // que [CallManager.startCall] ne le rappelle ; se réabonner ferait rater un `kEnded` survenu
    // entre-temps (CachedStreamController ne rejoue rien aux nouveaux abonnés).
    if (_active == session && _activeStateSub != null) return;
    if (session.callHasEnded) return;
    _active = session;
    _activeSince = DateTime.now();
    activeCallNotifier.value = true;
    _startWatchdog();
    _activeStateSub?.cancel();
    _activeStateSub = session.onCallStateChanged.stream.listen((state) {
      if (state == CallState.kEnded && _active == session) {
        _active = null;
        _activeSince = null;
        activeCallNotifier.value = false;
        _activeStateSub?.cancel();
        _activeStateSub = null;
      }
    });
  }

  @override
  bool get isWeb => false;

  @override
  EncryptionKeyProvider? get keyProvider => null;

  // Type de retour délibérément non préfixé par `webrtc.` : `WebRTCDelegate.mediaDevices`
  // attend le `MediaDevices` ré-exporté par `package:matrix` (celui de `webrtc_interface`), pas
  // la classe de `flutter_webrtc` elle-même (deux types distincts, même s'ils coïncident à
  // l'exécution) — une première version de ce fichier utilisait le mauvais type et échouait à
  // la compilation (voir le run CI qui a précédé ce correctif).
  @override
  MediaDevices get mediaDevices => webrtc.navigator.mediaDevices;

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
      // Appel entrant refusé faute de TURN : le SDK a déjà lancé la sonnerie (playRingtone avant
      // initWithInvite) et avale l'exception ci-dessous sans terminer la session, qui resterait
      // orpheline (sonnerie en boucle FLAG_INSISTENT jusqu'au timeout, correspondant jamais
      // prévenu). On coupe la sonnerie tout de suite, puis — une fois la pile du SDK déroulée —
      // on rejette les sessions entrantes encore sans connexion WebRTC.
      try {
        await stopRingtone();
      } catch (_) {}
      Timer.run(_rejectOrphanSessions);
      throw const CallBlockedException(
        'Appel refusé par la politique réseau (voir docs/CALLS_ARCHITECTURE.md) : aucune '
        'connexion WebRTC ne peut être créée dans ce mode tant que son étanchéité n\'a pas été '
        'vérifiée par capture réseau.',
      );
    }
    return webrtc.createPeerConnection(iceConfig.toJson(), constraints);
  }

  /// Rejette (`m.call.reject`/`hangup` côté SDK, ce qui libère aussi tout flux local) chaque
  /// session ENTRANTE non terminée qui n'a pas de connexion WebRTC — exactement celles que
  /// [createPeerConnection] vient de refuser. Les sessions sortantes sont volontairement exclues :
  /// [CallManager.startCall] les termine lui-même après l'échec de `inviteToCall` (les rejeter ici
  /// pourrait courir contre leur `getUserMedia` encore en cours et laisser le micro ouvert).
  void _rejectOrphanSessions() {
    final v = voip;
    if (v == null) return;
    for (final session in v.calls.values.toList()) {
      if (session.isOutgoing || session.isGroupCall) continue;
      if (session.pc != null || session.callHasEnded) continue;
      unawaited(session.reject().catchError((_) {}));
    }
  }

  /// Trouvé en audit interne (revue croisée IA, confirmé en relisant la structure réelle des
  /// widgets — voir le commentaire de [AppLock.isUnlocked]) : [LockGate] n'est pas une frontière
  /// de navigation, donc le `push` ci-dessous s'empilait TOUJOURS par-dessus l'écran de
  /// verrou/calculatrice, quel que soit son état. Un appel entrant affichait ainsi « Appel
  /// entrant… » (bouton Décrocher = accès micro) sans aucun déverrouillage, et révélait l'appli
  /// même en mode discret — un contournement direct du verrou, pas seulement un détail OPSEC.
  ///
  /// Tant que l'appli est verrouillée, on ne pousse donc plus aucune UI : la session suit son
  /// cours côté signalisation (le correspondant la voit sonner puis expirer normalement, comme
  /// n'importe quel appel non décroché), et on enregistre nous-mêmes l'appel manqué dès
  /// `kEnded` — en dupliquant ici le strict minimum de ce que fait normalement
  /// `CallSessionScreen._recordMissedCall` (lib/calls/ui/call_session_screen.dart), puisque cet
  /// écran ne sera jamais monté pour cette session. La notification reste déjà camouflée selon
  /// `calc_mode` par [CallOpsecNotifier.notifyMissedCall] lui-même.
  ///
  /// Appel entrant d'un utilisateur bloqué ([Client.ignoredUsers]) : rejeté silencieusement —
  /// aucun écran, aucune sonnerie (voir [playRingtone]), aucun appel manqué enregistré.
  ///
  /// Appel SORTANT alors que l'appli est verrouillée (reverrouillage survenu pendant
  /// `inviteToCall`, ou navigateur indisponible) : raccroché immédiatement, pour ne jamais
  /// laisser un micro actif sans aucune interface permettant de le couper.
  @override
  Future<void> handleNewCall(CallSession session) async {
    // Marqué « présenté » dans tous les cas : [handleMissedCall] ne doit rien enregistrer en
    // double (ni, pour un bloqué, quoi que ce soit).
    _presented[session] = true;
    if (!session.isOutgoing && !session.isGroupCall && isBlockedSession(session)) {
      try {
        await stopRingtone();
      } catch (_) {}
      if (!session.callHasEnded) {
        try {
          await session.reject();
        } catch (_) {}
      }
      return;
    }
    if (session.isOutgoing && !AppLock.isUnlocked) {
      if (!session.callHasEnded) {
        try {
          await session.hangup(reason: CallErrorCode.userHangup);
        } catch (_) {}
      }
      return;
    }
    _watchActive(session);
    final builder = buildCallScreen;
    final nav = navigatorKey?.currentState;
    if (AppLock.isUnlocked && builder != null && nav != null) {
      nav.push(MaterialPageRoute(builder: (_) => builder(session)));
      return;
    }
    if (session.isOutgoing) {
      // Déverrouillée mais sans navigateur/écran : même règle, pas de micro sans interface.
      if (!session.callHasEnded) {
        try {
          await session.hangup(reason: CallErrorCode.userHangup);
        } catch (_) {}
      }
      return;
    }
    trackLockedIncoming(session);
  }

  /// Chemin « verrouillé » de [handleNewCall] : aucune UI n'est poussée ; on mémorise la session
  /// pour [presentPendingCall] et on enregistre nous-mêmes l'appel manqué à `kEnded` (l'écran
  /// d'appel, qui le fait normalement, n'est pas monté). Chaque abonnement se désabonne lui-même
  /// et ne touche aux champs partagés que s'ils désignent encore SA session.
  ///
  /// Public : `CallSessionScreen.dispose` y rend une session entrante encore sonnante quand son
  /// écran est fermé par le reverrouillage (la session reste sonnante, sera enregistrée comme
  /// manquée si elle se termine, et redevient présentable via [presentPendingCall]). Sans effet
  /// pour une session sortante, de groupe ou venant d'un utilisateur bloqué : retourne alors
  /// `false` (l'appelant reste responsable de la session) ; `true` si la session est suivie.
  bool trackLockedIncoming(CallSession session) {
    if (session.isOutgoing || session.isGroupCall) return false;
    if (_pendingLockedCall == session) return true;
    if (isBlockedSession(session)) return false;
    // Une seule session en attente : l'abonnement d'une éventuelle précédente reste actif (il
    // enregistrera lui-même son appel manqué), seul le pointeur « à présenter » est remplacé.
    StreamSubscription<CallState>? sub;
    var done = false;
    Future<void> onEnded() async {
      if (done) return;
      done = true;
      await sub?.cancel();
      if (_pendingLockedCall == session) {
        _pendingLockedCall = null;
        _pendingLockedSub = null;
      }
      if (_countsAsMissed(session)) await _recordMissed(session);
    }

    sub = session.onCallStateChanged.stream.listen((state) {
      if (state == CallState.kEnded) unawaited(onEnded());
    });
    _pendingLockedCall = session;
    _pendingLockedSub = sub;
    // CachedStreamController ne rejoue rien : traiter un kEnded déjà survenu.
    if (session.callHasEnded) unawaited(onEnded());
    return true;
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    if (_active == session) {
      _active = null;
      _activeSince = null;
      activeCallNotifier.value = false;
      _activeStateSub?.cancel();
      _activeStateSub = null;
    }
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    if (_active == session) {
      _active = null;
      _activeSince = null;
      activeCallNotifier.value = false;
      _activeStateSub?.cancel();
      _activeStateSub = null;
    }
    // Les appels présentés via [handleNewCall] sont enregistrés par CallSessionScreen (ou par le
    // chemin verrouillé) : rien à dupliquer ici. En revanche, un appel entrant jamais présenté —
    // typiquement refusé « occupé » par le SDK parce qu'un autre appel est en cours
    // (`canHandleNewCall == false`), ou raccroché par l'appelant avant la fin d'initWithInvite —
    // n'était jusqu'ici enregistré nulle part. NB : on ne peut pas se fier à `hangupReason`
    // (`reject(reason: userBusy)` du SDK v0.29.0 retombe sur `hangup(userHangup)`).
    if (_presented[session] != true && _countsAsMissed(session)) {
      await _recordMissed(session);
    }
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
  Future<void> playRingtone() async {
    // Le SDK appelle playRingtone sans session en argument, juste après avoir enregistré la
    // nouvelle session entrante dans `voip.calls` et AVANT initWithInvite (donc sans `pc`). Si une
    // telle session non terminée vient d'un utilisateur bloqué, on ne sonne pas : elle sera
    // rejetée silencieusement par [handleNewCall].
    if (_hasRingingBlockedSession()) return;
    // Le SDK sonne AVANT initWithInvite, donc avant que createPeerConnection n'applique le
    // fail-closed : sans ce test, un appel que la politique réseau va refuser (mode Tor/proxy)
    // ferait sonner le téléphone pour rien, puis s'arrêterait sans explication.
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) return;
    await CallOpsecNotifier.notifyIncomingCall();
  }

  bool _hasRingingBlockedSession() {
    final v = voip;
    if (v == null) return false;
    for (final session in v.calls.values) {
      if (session.isOutgoing || session.isGroupCall) continue;
      if (session.pc != null || session.callHasEnded) continue;
      if (isBlockedSession(session)) return true;
    }
    return false;
  }

  @override
  Future<void> stopRingtone() => CallOpsecNotifier.stopIncomingCall();
}

/// Point d'entrée unique pour démarrer un appel sortant, et porte d'accès à [VoIP] pour le reste
/// de l'appli — construit une seule fois dans `main.dart`, aux côtés du [Client] Matrix.
class CallManager {
  CallManager({required Client client}) : delegate = MurmureWebRTCDelegate(client: client) {
    voip = VoIP(client, delegate);
    delegate.voip = voip;
  }

  final MurmureWebRTCDelegate delegate;
  late final VoIP voip;

  /// Trouvé en audit interne (revue croisée à 5 IA, consensus unanime) : [LockGate] lit ceci
  /// avant de reverrouiller automatiquement, pour ne jamais couper un appel en cours (micro
  /// ouvert) juste parce que l'appli revient de l'arrière-plan après [kRelockAfter] — voir
  /// `ui/lock_screens.dart`. Simple relais public du [ValueNotifier] du delegate, qui seul
  /// observe réellement l'état de la session WebRTC/`CallSession`.
  ValueListenable<bool> get activeCallListenable => delegate.activeCallNotifier;

  /// Démarre un appel sortant vers [room]. Vérifie la politique réseau ICI, avant même d'envoyer
  /// un `m.call.invite` — pas seulement au moment de créer la connexion WebRTC (qui refuserait de
  /// toute façon, voir [MurmureWebRTCDelegate.createPeerConnection]), pour ne pas faire sonner le
  /// correspondant pour un appel qui ne pourra jamais aboutir. Retourne `null` si le mode réseau
  /// ne permet pas l'appel (voir [CallPolicy.isAllowed]) — à l'appelant de montrer un message
  /// explicite, jamais un échec silencieux.
  ///
  /// Trouvé en audit interne : même en mode direct (donc `CallPolicy.isAllowed == true`),
  /// [CallPolicy.buildIceConfig] peut refuser l'appel (`CallBlockedException`, voir
  /// `createPeerConnection`) si le homeserver ne fournit aucun serveur TURN exploitable
  /// (`Client.getTurnServer()` échoue ou vide — le cas avant qu'un coturn ne soit réellement
  /// déployé, voir docs/CALLS_ARCHITECTURE.md). Cette exception traverse
  /// `CallSession.initOutboundCall` → `_preparePeerConnection`, qui l'avale silencieusement côté
  /// SDK (elle ne fait que logger) SANS relancer ni positionner d'état d'erreur ; `pc` reste donc
  /// `null` et le code du SDK continue (`addLocalStream` notamment), ce qui finit par lever une
  /// exception de null-check (`pc!...`) non interceptée — remontant jusqu'ici en laissant
  /// l'utilisateur sans aucun message (le bouton d'appel ne fait alors rien de visible), alors que
  /// la politique a bien refusé l'appel comme prévu. Intercepté ici pour honorer le contrat déjà
  /// documenté par ce commentaire (retourner `null`, jamais un échec silencieux) quelle que soit
  /// l'origine exacte du refus.
  ///
  /// Corrigé : la pré-vérification ne portait que sur [CallPolicy.isAllowed] ; sans TURN,
  /// `inviteToCall` allait quand même jusqu'à `getUserMedia` (micro/caméra ouverts) avant d'échouer
  /// sur `pc!`, et la session sortante restait non terminée (flux jamais libérés). On construit
  /// désormais la configuration ICE AVANT tout `inviteToCall` (aucun accès micro/caméra si elle est
  /// refusée) et, en cas d'exception malgré tout, on termine chaque session sortante de ce salon
  /// créée par cette tentative. L'appel cible aussi explicitement le correspondant de la
  /// conversation directe (`userId`) : sans lui, n'importe quel membre du salon pouvait décrocher,
  /// et un salon non direct n'est pas pris en charge (retour `null`).
  Future<CallSession?> startCall(Room room, {required CallType type}) async {
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) return null;
    final peerId = room.directChatMatrixID;
    if (peerId == null) return null;
    final CallIceConfig? iceConfig;
    try {
      iceConfig = await CallPolicy.buildIceConfig(client: room.client, mode: net.mode);
    } catch (_) {
      return null;
    }
    if (iceConfig == null) return null;

    final before = voip.calls.values.map((c) => c.callId).toSet();
    try {
      final session = await voip.inviteToCall(room, type, userId: peerId);
      if (session.pc == null) {
        // Refus tardif (TURN devenu indisponible entre la pré-vérification et la création de la
        // connexion) sans exception remontée : même nettoyage que ci-dessous.
        await _abortOutgoing(room, before, extra: session);
        return null;
      }
      // Raccroché par handleNewCall (appli reverrouillée entre-temps) : rien à présenter.
      if (session.callHasEnded) return null;
      delegate._watchActive(session);
      return session;
    } catch (_) {
      await _abortOutgoing(room, before);
      return null;
    }
  }

  /// Termine (libère micro/caméra via `CallSession.cleanUp` côté SDK) toute session sortante non
  /// terminée de [room] apparue depuis [before] — c.-à-d. créée par la tentative qui vient
  /// d'échouer, jamais un autre appel en cours.
  Future<void> _abortOutgoing(Room room, Set<String> before, {CallSession? extra}) async {
    final targets = <CallSession>{
      if (extra != null) extra,
      ...voip.calls.values.where(
        (c) => c.room.id == room.id && c.isOutgoing && !before.contains(c.callId),
      ),
    };
    for (final session in targets) {
      if (session.callHasEnded) continue;
      try {
        await session.hangup(reason: CallErrorCode.userHangup);
      } catch (_) {}
    }
  }
}
