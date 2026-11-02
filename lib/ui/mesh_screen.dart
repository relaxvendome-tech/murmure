import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh.dart';
import '../mesh/mesh_crypto.dart';

/// Mode Bluetooth maillé : fonctionnement sans réseau ni serveur (coupure, brouillage). Scanne ET
/// s'annonce simultanément (rôles BLE central + peripheral, voir mesh.dart) : deux téléphones
/// Murmure à portée se découvrent mutuellement, pas seulement celui qui scanne en premier.
class MeshScreen extends StatefulWidget {
  const MeshScreen({super.key});

  @override
  State<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends State<MeshScreen> {
  bool _active = false;
  bool _busy = false;
  StreamSubscription<MeshEvent>? _sub;
  final _log = <String>[];
  String? _myCode;

  @override
  void initState() {
    super.initState();
    _sub = Mesh.instance.events.listen((e) {
      if (!mounted) return;
      setState(() {
        switch (e) {
          case MeshStarted():
            _log.insert(0, 'Écoute Bluetooth démarrée');
          case MeshStopped():
            _log.insert(0, 'Écoute Bluetooth arrêtée');
          case MeshMessageReceived(:final text):
            _log.insert(0, 'Message reçu : $text');
        }
      });
    });
    Mesh.instance.identity().then((id) {
      if (mounted) setState(() => _myCode = meshB64(id.publicKeyBytes));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    if (on) {
      final granted = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse, // requis par Android pour le scan BLE sur certaines versions
      ].request();
      final ok = granted.values.every((s) => s.isGranted || s.isLimited);
      if (!ok) {
        if (mounted) {
          setState(() => _busy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permissions Bluetooth refusées')),
          );
        }
        return;
      }
      await Mesh.instance.start();
    } else {
      await Mesh.instance.stop();
    }
    if (mounted) setState(() {
      _active = on;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mode hors-ligne')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quand le réseau mobile est coupé ou brouillé, Murmure peut relayer vos messages '
                    'de téléphone en téléphone par Bluetooth, jusqu\'à ce qu\'ils atteignent leur '
                    'destinataire. Chaque message reste chiffré pour lui seul : les téléphones qui le '
                    'relaient ne peuvent pas le lire.',
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Activer le mode Bluetooth'),
                    value: _active,
                    onChanged: _busy ? null : _toggle,
                  ),
                ],
              ),
            ),
          ),
          if (_myCode != null)
            Card(
              child: ListTile(
                title: const Text('Mon code de contact Bluetooth'),
                subtitle: Text(_myCode!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copier',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _myCode!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copié')),
                    );
                  },
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('Journal', style: Theme.of(context).textTheme.titleMedium),
          ..._log.map((l) => Text('• $l')),
        ],
      ),
    );
  }
}
