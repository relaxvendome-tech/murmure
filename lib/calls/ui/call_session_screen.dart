import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    // `CachedStreamController` rejoue aux nouveaux abonnés les flux déjà présents au moment de
    // l'abonnement (voir la doc de matrix-dart-sdk) : on ne manque donc pas un flux apparu avant
    // que cet écran n'existe (cas d'un appel déjà en cours de connexion côté sortant).
    _addSub = widget.session.onStreamAdd.stream.listen(_attach);
    _removeSub = widget.session.onStreamRemoved.stream.listen(_detach);

    _answered = widget.session.isOutgoing;
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

  Future<void> _accept() async {
    setState(() => _answered = true);
    await widget.session.answer();
  }

  Future<void> _decline() async {
    await widget.session.reject();
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleMute() {
    final feed = _localFeed;
    if (feed == null) return;
    setState(() => _isMuted = !_isMuted);
    feed.setAudioMuted(_isMuted);
  }

  Future<void> _hangUp() async {
    await widget.session.hangup(reason: CallErrorCode.userHangup);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _addSub?.cancel();
    _removeSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
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
