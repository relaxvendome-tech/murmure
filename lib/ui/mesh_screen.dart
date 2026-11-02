import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh.dart';
import '../mesh/mesh_crypto.dart';

/// Mode Bluetooth maillé : fonctionnement sans réseau ni serveur (coupure, brouillage).
///
/// Avertissement honnête affiché à l'utilisateur : voir le commentaire en tête de mesh.dart — ce
/// mode ne fonctionne aujourd'hui qu'en scan + connexion sortante (rôle BLE central). Il permet de
/// relayer vers un appareil déjà repéré, mais un maillage pleinement symétrique demande encore un
/// serveur GATT natif (rôle BLE peripheral) qui reste à écrire côté Android.
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
                  onPressed: () {
                    // Copie dans le presse-papiers ; échange hors-ligne du code entre contacts
                    // (lecture à voix haute, ou QR dans une version future de cet écran).
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
