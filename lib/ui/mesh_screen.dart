import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh.dart';
import '../mesh/mesh_crypto.dart';
import 'qr_screens.dart';
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
  List<({Uint8List peer, String label})> _contacts = [];

  /// Minuteur d'auto-effacement du presse-papiers après une copie du code de contact — voir
  /// [_copyMyCode]. Trouvé en audit interne : avant cette correction, `Clipboard.setData` n'était
  /// jamais suivi d'un effacement, donc le code (clé publique BLE de l'utilisateur) restait dans
  /// le presse-papiers système INDÉFINIMENT après usage — lisible par n'importe quelle autre appli
  /// qui y accède (y compris, selon l'appareil/la version d'Android, en arrière-plan ; et visible
  /// dans un éventuel gestionnaire d'historique de presse-papiers) bien après que l'utilisateur ait
  /// quitté cet écran. Ce n'est pas un secret de chiffrement, mais c'est un identifiant stable et
  /// partageable qui ne devrait pas survivre plus longtemps que nécessaire pour être collé une
  /// fois.
  Timer? _clipboardClearTimer;

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
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final contacts = await Mesh.instance.contacts();
    if (mounted) setState(() => _contacts = contacts);
  }

  /// Décode un code de contact collé ou scanné (même format que « Mon code de contact
  /// Bluetooth » — base64url sans rembourrage d'une clé publique X25519) et vérifie sa longueur
  /// (32 octets) avant de l'accepter. Renvoie `null` sans lever d'exception pour un texte
  /// invalide — un contact ajouté par erreur ne doit jamais faire planter l'écran, seulement
  /// afficher un message clair.
  Uint8List? _decodeContactCode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      final bytes = meshUnB64(text);
      return bytes.length == 32 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _addContact() async {
    final codeCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    String? error;
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Ajouter un contact Bluetooth'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Collez ou scannez le code que ce contact vous a montré depuis son propre écran '
                '« Mode hors-ligne ». Ce code ne contient que sa clé publique Bluetooth, jamais '
                'de secret.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(labelText: 'Nom (pour vous seul)'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(labelText: 'Code du contact'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scanner un code',
                    onPressed: () async {
                      final scanned = await Navigator.of(dialogContext).push<String>(
                          MaterialPageRoute(builder: (_) => const QrScanScreen()));
                      if (scanned != null) codeCtrl.text = scanned;
                    },
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () async {
                final label = labelCtrl.text.trim();
                final peer = _decodeContactCode(codeCtrl.text);
                if (label.isEmpty || peer == null) {
                  setDialogState(() => error = 'Nom et code valides requis');
                  return;
                }
                await Mesh.instance.addContact(peer, label);
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
    codeCtrl.dispose();
    labelCtrl.dispose();
    if (added == true) await _loadContacts();
  }

  Future<void> _removeContact(Uint8List peer) async {
    await Mesh.instance.removeContact(peer);
    await _loadContacts();
  }

  /// Compose et met en file un message pour [contact] (voir [Mesh.queueMessage]). Le message part
  /// réellement dès le prochain appareil Murmure croisé qui le relaie ou le lui remet directement
  /// — pas forcément tout de suite, c'est le principe même du store-and-forward hors-ligne.
  Future<void> _composeAndSend(({Uint8List peer, String label}) contact) async {
    final textCtrl = TextEditingController();
    final sent = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Message à ${contact.label}'),
        content: TextField(
          controller: textCtrl,
          decoration: const InputDecoration(hintText: 'Votre message'),
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Mettre en file'),
          ),
        ],
      ),
    );
    final text = textCtrl.text.trim();
    textCtrl.dispose();
    if (sent != true || text.isEmpty) return;
    await Mesh.instance.queueMessage(recipientPublicKey: contact.peer, text: text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Message mis en file pour ${contact.label} — part au prochain contact Bluetooth croisé'),
    ));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _clipboardClearTimer?.cancel();
    super.dispose();
  }

  /// Copie [_myCode] dans le presse-papiers, puis programme son effacement (voir le commentaire
  /// de [_clipboardClearTimer]). On ne réécrase le presse-papiers à l'échéance QUE s'il contient
  /// encore exactement ce qu'on y a mis : si l'utilisateur a copié autre chose pendant ce délai
  /// (un code reçu d'un contact, par exemple), on ne veut surtout pas effacer CE contenu-là à sa
  /// place.
  Future<void> _copyMyCode() async {
    final code = _myCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copié (effacé du presse-papiers dans 30 s)')),
    );
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == code) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
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
                  onPressed: _copyMyCode,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('Contacts Bluetooth', style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                icon: const Icon(Icons.person_add_outlined),
                tooltip: 'Ajouter un contact',
                onPressed: _addContact,
              ),
            ],
          ),
          if (_contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Text(
                'Aucun contact Bluetooth pour l\'instant. Ajoutez-en un pour pouvoir lui envoyer '
                'un message hors-ligne.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            ..._contacts.map((c) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: murmureAvatarColor(meshB64(c.peer)),
                      foregroundColor: Colors.white,
                      child: Text(c.label.isEmpty ? '?' : c.label[0].toUpperCase()),
                    ),
                    title: Text(c.label),
                    subtitle: Text('${meshB64(c.peer).substring(0, 8)}…'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Retirer',
                      onPressed: () => _removeContact(c.peer),
                    ),
                    onTap: () => _composeAndSend(c),
                  ),
                )),
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
