import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../mesh/mesh.dart';
import '../network.dart';
import 'network_settings_screen.dart';

/// Puce de la barre d'app de la liste des conversations : indique en permanence par où passent
/// les messages (Direct / Tor / Proxy), si le relais Bluetooth est actif, et si la synchronisation
/// avec le serveur échoue (« Hors ligne »). Un appui ouvre les réglages réseau ; le mode est relu
/// au retour de cet écran.
class NetworkStatusChip extends StatefulWidget {
  const NetworkStatusChip({super.key, required this.client});
  final Client client;

  @override
  State<NetworkStatusChip> createState() => _NetworkStatusChipState();
}

class _NetworkStatusChipState extends State<NetworkStatusChip> {
  NetMode _mode = NetMode.direct;
  bool _meshOn = Mesh.instance.isRunning;
  bool _offline = false;
  StreamSubscription<SyncStatusUpdate>? _syncSub;
  StreamSubscription<MeshEvent>? _meshSub;

  @override
  void initState() {
    super.initState();
    _loadMode();
    // SDK v0.29.0 : SyncStatus { waitingForResponse, processing, cleaningUp, finished, error }.
    // Après une erreur, chaque nouvelle tentative repasse par `waitingForResponse` : n'en déduire
    // « en ligne » faisait clignoter « Hors ligne ». On ne repasse en ligne que sur `finished`
    // (sync réellement aboutie) ; les états intermédiaires ne changent rien.
    _offline = widget.client.onSyncStatus.value?.status == SyncStatus.error;
    _syncSub = widget.client.onSyncStatus.stream.listen((u) {
      final bool off;
      switch (u.status) {
        case SyncStatus.error:
          off = true;
        case SyncStatus.finished:
          off = false;
        default:
          return;
      }
      if (mounted && off != _offline) setState(() => _offline = off);
    });
    _meshSub = Mesh.instance.events.listen((e) {
      if (e is MeshMessageReceived) return;
      final on = Mesh.instance.isRunning;
      if (mounted && on != _meshOn) setState(() => _meshOn = on);
    });
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _meshSub?.cancel();
    super.dispose();
  }

  Future<void> _loadMode() async {
    final cfg = await NetConfig.load();
    if (mounted) setState(() => _mode = cfg.mode);
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NetworkSettingsScreen(client: widget.client)),
    );
    if (!mounted) return;
    setState(() => _meshOn = Mesh.instance.isRunning);
    await _loadMode();
  }

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label) = switch (_mode) {
      NetMode.direct => (Icons.language, 'Direct'),
      NetMode.tor => (Icons.lock_outline, 'Tor'),
      NetMode.customProxy => (Icons.swap_horiz, 'Proxy'),
    };
    final parts = <String>[
      'Réseau : $label',
      if (_meshOn) 'relais Bluetooth actif',
      if (_offline) 'hors ligne, synchronisation en échec',
    ];
    final desc = parts.join(', ');
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$desc. Ouvrir les réglages réseau',
      excludeSemantics: true,
      child: Tooltip(
        message: '$desc — toucher pour modifier',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: 3),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              if (_meshOn) ...[
                const SizedBox(width: 6),
                Icon(Icons.bluetooth, size: 16, color: scheme.primary),
              ],
              if (_offline) ...[
                const SizedBox(width: 6),
                const Icon(Icons.cloud_off, size: 16, color: Colors.orange),
                const SizedBox(width: 2),
                const Text('Hors ligne',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
