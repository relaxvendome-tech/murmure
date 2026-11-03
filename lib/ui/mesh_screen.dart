import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh.dart';
import '../mesh/mesh_crypto.dart';
import 'theme.dart';

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
  final _log = <_LogEntry>[];
  String? _myCode;

  @override
  void initState() {
    super.initState();
    // Trouvé en audit interne : avant cette correction, ce journal n'affichait QUE les messages
    // reçus pendant que cet écran était ouvert (liste en mémoire, jamais relue depuis la base) —
    // alors que `Mesh._handleIncomingLocked` les enregistre bel et bien dans la table `inbox` de
    // la base SQLCipher (voir mesh.dart). Un message arrivé pendant que le mode Bluetooth
    // tournait en arrière-plan (voir mesh_foreground_service.dart), ou lors d'une session
    // précédente, restait donc chiffré sur le disque mais invisible dans cette interface — perdu
    // en pratique pour l'utilisateur, alors qu'il était bien là. On recharge maintenant l'historique
    // persistant au démarrage de l'écran, puis on y ajoute les messages reçus en direct.
    //
    // Deuxième correction, dans le même esprit : le journal affichait seulement le TEXTE du
    // message (`'Message reçu : $text'`), jamais l'expéditeur — illisible dès que plusieurs
    // contacts envoient par Bluetooth, exactement le scénario visé (plusieurs téléphones croisés
    // en manifestation). On affiche maintenant les premiers caractères de la clé publique BLE de
    // l'expéditeur (même encodage que « Mon code de contact Bluetooth » ci-dessous) à côté de
    // chaque message, pour pouvoir au moins les distinguer entre eux — pas un nom lisible (le mode
    // Bluetooth n'a pas de carnet de contacts nommés), mais un identifiant stable et comparable.
    Mesh.instance.inbox().then((rows) {
      if (!mounted) return;
      setState(() {
        _log.addAll(rows.map((r) => _LogEntry.message(
              sender: r['sender'] as List<int>,
              text: r['plaintext'] as String,
              ts: r['received_at'] as int,
            )));
        _log.sort((a, b) => b.ts.compareTo(a.ts));
      });
    });
    _sub = Mesh.instance.events.listen((e) {
      if (!mounted) return;
      setState(() {
        switch (e) {
          case MeshStarted():
            _log.insert(0, _LogEntry.status('Écoute Bluetooth démarrée'));
          case MeshStopped():
            _log.insert(0, _LogEntry.status('Écoute Bluetooth arrêtée'));
          case MeshMessageReceived(:final sender, :final text):
            // Déjà inséré en base par Mesh._handleIncomingLocked ; on l'ajoute ici seulement à
            // l'affichage en direct, jamais une deuxième fois en base.
            _log.insert(
                0, _LogEntry.message(sender: sender, text: text, ts: DateTime.now().millisecondsSinceEpoch));
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
          const SizedBox(height: 4),
          if (_log.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Aucun message pour l\'instant. Activez le Bluetooth ci-dessus pour commencer à '
                'découvrir des contacts à portée.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            ..._log.map((l) => Card(
                  child: ListTile(
                    leading: l.isStatus
                        ? Icon(
                            l.label.contains('démarrée')
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth_disabled,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          )
                        : CircleAvatar(
                            backgroundColor: murmureAvatarColor(meshB64(l.sender!)),
                            foregroundColor: Colors.white,
                            radius: 16,
                            child: Text(
                              meshB64(l.sender!).substring(0, 1).toUpperCase(),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                    title: Text(
                      l.isStatus ? l.label : l.text!,
                      maxLines: l.isStatus ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: l.isStatus
                        ? null
                        : Text('De ${meshB64(l.sender!).substring(0, 8)}…'),
                    trailing: l.ts == 0
                        ? null
                        : Text(
                            DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(l.ts)),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                  ),
                )),
        ],
      ),
    );
  }
}

/// Une ligne du journal affiché sur cet écran : soit un changement d'état (démarré/arrêté), soit
/// un message reçu — auquel cas on garde l'expéditeur pour pouvoir au moins distinguer deux
/// contacts entre eux (voir le commentaire d'`initState` ci-dessus). Les champs bruts (plutôt
/// qu'un unique `label` déjà formaté comme avant cette passe visuelle) permettent à l'affichage de
/// distinguer une icône, un avatar coloré et un horodatage par type de ligne.
class _LogEntry {
  const _LogEntry.status(this.label)
      : ts = 0,
        sender = null,
        text = null,
        isStatus = true;
  _LogEntry.message({required this.sender, required this.text, required this.ts})
      : label = '',
        isStatus = false;

  final bool isStatus;
  final String label;
  final List<int>? sender;
  final String? text;
  final int ts;
}
