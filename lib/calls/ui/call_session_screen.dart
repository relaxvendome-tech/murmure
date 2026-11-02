import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

import '../../network.dart';
import '../call_policy.dart';

/// Écran d'appel (audio/vidéo). Corrige une proposition reçue pendant le développement de cette
/// fonctionnalité qui, mal relue, ne pouvait pas fonctionner telle quelle :
///
/// - Elle appelait `CallPolicy.isAllowed()` et `CallPolicy.generateSecureRtcConfig()` sans
///   argument — ces méthodes n'existent pas sous cette forme (la vraie politique,
///   `lib/calls/call_policy.dart`, exige explicitement un `NetMode` et, pour la config ICE, le
///   `Client` Matrix nécessaire à `getTurnServer()` — sans ça, aucune garantie fail-closed n'est
///   réellement appliquée, le code ne compilerait même pas).
/// - Elle n'ajoutait JAMAIS le flux local (micro/caméra) à la connexion : `_localRenderer` était
///   initialisé mais jamais nourri, et rien n'était envoyé au correspondant — un appel « muet et
///   noir » des deux côtés même si tout le reste fonctionnait.
/// - Elle n'avait aucun gestionnaire `onIceCandidate` : sans échange des candidats ICE (et de
///   l'offre/réponse SDP) via la signalisation Matrix, deux appareils ne peuvent tout simplement
///   jamais se connecter entre eux, quelle que soit la qualité du serveur TURN.
///
/// LIMITE HONNÊTE — ce qui N'EST PAS encore fait ici, volontairement signalé plutôt que caché :
/// la signalisation (échange de l'offre/réponse SDP et des candidats ICE via les événements
/// `m.call.*` de Matrix, voir `docs/CALLS_ARCHITECTURE.md` point 5) n'est PAS branchée. Cet écran
/// construit correctement la connexion WebRTC locale (flux local envoyé, flux distant affiché,
/// politique réseau respectée) et expose les callbacks [onLocalIceCandidate]/[onLocalOffer] pour
/// qu'une future intégration `matrix-dart-sdk` VoIP les transmette au correspondant — mais tant
/// que rien n'appelle ces callbacks vers un vrai transport, et tant que [remoteDescription]/
/// [addRemoteIceCandidate] ne sont pas alimentés par ce même transport côté réception, un appel
/// ne peut pas encore aboutir entre deux appareils réels. Ne pas présenter cet écran comme un
/// appel fonctionnel de bout en bout avant que cette intégration existe et soit testée.
class CallSessionScreen extends StatefulWidget {
  const CallSessionScreen({
    super.key,
    required this.client,
    required this.mode,
    required this.peerName,
    required this.isOutgoing,
    this.onLocalIceCandidate,
    this.onLocalOffer,
  });

  /// Client Matrix du compte courant : nécessaire à [CallPolicy.buildIceConfig] pour obtenir des
  /// identifiants TURN dynamiques (`Client.getTurnServer()`), jamais un secret codé en dur.
  final Client client;

  /// Mode réseau courant (voir `lib/network.dart`) : l'appel est refusé (voir [CallPolicy]) dès
  /// que ce n'est pas `NetMode.direct`, tant que la vérification par capture réseau décrite dans
  /// `docs/CALLS_ARCHITECTURE.md` n'a pas été faite sur ce plugin.
  final NetMode mode;

  final String peerName;
  final bool isOutgoing;

  /// Appelé à chaque candidat ICE local généré, à transmettre au correspondant par la
  /// signalisation Matrix (`m.call.candidates`) — non implémenté dans ce fichier, voir la
  /// LIMITE HONNÊTE ci-dessus. `null` par défaut : dans ce cas, les candidats sont simplement
  /// perdus et l'appel ne peut pas aboutir, ce qui est honnête tant que rien ne les transmet.
  final void Function(RTCIceCandidate candidate)? onLocalIceCandidate;

  /// Appelé une fois l'offre (ou la réponse) SDP locale prête, à transmettre de la même façon
  /// (`m.call.invite`/`m.call.answer`). Même limite que ci-dessus.
  final void Function(RTCSessionDescription description)? onLocalOffer;

  @override
  State<CallSessionScreen> createState() => _CallSessionScreenState();
}

class _CallSessionScreenState extends State<CallSessionScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  bool _isMuted = false;

  /// `null` tant que la vérification n'est pas terminée ; ensuite vrai/faux selon
  /// [CallPolicy.isAllowed]. Distinct de "false" pour ne pas afficher une seconde d'écran d'appel
  /// vide avant le message de refus.
  bool? _allowed;
  String? _setupError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!CallPolicy.isAllowed(widget.mode)) {
      setState(() => _allowed = false);
      return;
    }
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      final iceConfig = await CallPolicy.buildIceConfig(client: widget.client, mode: widget.mode);
      if (iceConfig == null) {
        // Fail-closed : pas de serveur TURN exploitable (voir CallPolicy.buildIceConfig). On ne
        // tente pas l'appel avec une configuration ICE incomplète ou sans TURN.
        setState(() {
          _allowed = false;
          _setupError = 'Serveur TURN indisponible — appel impossible dans ce mode réseau.';
        });
        return;
      }

      _peerConnection = await createPeerConnection(iceConfig.toJson());

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': true,
      });
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      _localRenderer.srcObject = _localStream;

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          setState(() => _remoteRenderer.srcObject = event.streams[0]);
        }
      };

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        widget.onLocalIceCandidate?.call(candidate);
      };

      if (widget.isOutgoing) {
        final offer = await _peerConnection!.createOffer();
        await _peerConnection!.setLocalDescription(offer);
        widget.onLocalOffer?.call(offer);
      }

      if (mounted) setState(() => _allowed = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _allowed = false;
        _setupError = '$e';
      });
    }
  }

  /// À appeler par la signalisation (une fois branchée, voir la LIMITE HONNÊTE en tête de
  /// fichier) quand l'offre/réponse du correspondant arrive.
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await _peerConnection?.setRemoteDescription(description);
    if (!widget.isOutgoing && description.type == 'offer') {
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      widget.onLocalOffer?.call(answer);
    }
  }

  /// À appeler par la signalisation quand un candidat ICE du correspondant arrive.
  Future<void> addRemoteIceCandidate(RTCIceCandidate candidate) async {
    await _peerConnection?.addCandidate(candidate);
  }

  void _toggleMute() {
    if (_localStream == null) return;
    setState(() => _isMuted = !_isMuted);
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
  }

  Future<void> _hangUp() async {
    await _cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cleanup() async {
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    for (final track in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    await _peerConnection?.close();
    _peerConnection = null;
    _localStream = null;
  }

  @override
  void dispose() {
    _cleanup();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed == false) {
      return Scaffold(
        appBar: AppBar(title: const Text('Appel')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phone_disabled, size: 48),
                const SizedBox(height: 16),
                Text(
                  _setupError ??
                      'Les appels sont désactivés en mode Tor/proxy : le flux audio/vidéo ne '
                          'peut pas être protégé par ce mode. Voir docs/CALLS_ARCHITECTURE.md.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_allowed != true) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
            top: 48,
            left: 24,
            child: Text(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 18)),
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
