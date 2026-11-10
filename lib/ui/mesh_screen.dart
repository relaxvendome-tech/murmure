import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh.dart';
import '../mesh/mesh_crypto.dart';
import '../mesh/mesh_foreground_service.dart';
import '../mesh/mesh_opsec_notifier.dart';
import 'mesh_qr_screen.dart';
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
  /// Corrigé : initialisé depuis l'état réel du singleton [Mesh] — avant, `false` en dur :
  /// rouvrir l'écran pendant que le relais tournait en arrière-plan affichait « désactivé ».
  bool _active = Mesh.instance.isRunning;
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
    // L'utilisateur ouvre cet écran : toute notification « nouveau message mesh » en attente
    // (voir mesh/mesh_opsec_notifier.dart) a rempli son rôle, il va lire l'inbox juste après.
    unawaited(MeshOpsecNotifier.clear());
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
    // contacts envoient par Bluetooth. On affiche maintenant le NOM local du contact (voir
    // [_labelFor]) ; un message dont l'expéditeur n'est pas dans les contacts n'est pas affiché.
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
            _active = Mesh.instance.isRunning;
            _log.insert(0, _LogEntry.status('Écoute Bluetooth démarrée'));
            if (!Mesh.instance.peripheralActive) {
              _log.insert(0, _LogEntry.status(
                  'Annonce Bluetooth indisponible — ce téléphone peut joindre les autres, mais ne '
                  'sera pas découvert par eux'));
            }
          case MeshStopped():
            // `_active` est déjà remis à `false` par `_toggle` dans le cas normal (arrêt par
            // l'interrupteur) — refaire la même affectation ici est sans effet dans ce cas, mais
            // couvre aussi tout futur arrêt déclenché depuis `Mesh` elle-même sans passer par
            // `_toggle`, sur le même principe que [MeshAdapterOff] ci-dessous.
            _active = false;
            _log.insert(0, _LogEntry.status('Écoute Bluetooth arrêtée'));
          case MeshAdapterOff():
            // Trouvé en audit interne (voir le commentaire de `Mesh.start` dans mesh.dart) :
            // l'adaptateur Bluetooth vient de quitter l'état actif de son propre chef (mode avion,
            // extinction manuelle) — PAS un arrêt demandé via l'interrupteur ci-dessus, qui restait
            // donc affiché « activé » sans que rien ne tourne plus réellement derrière, jusqu'à ce
            // correctif. On remet l'interrupteur à l'état réel et on l'explique, plutôt que de
            // laisser l'utilisateur croire le relais actif.
            _active = false;
            _log.insert(
                0, _LogEntry.status('Bluetooth désactivé (mode avion ?) — mode hors-ligne arrêté'));
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
    // Rattrape un démarrage/arrêt survenu entre la construction de l'état et l'abonnement.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_busy && _active != Mesh.instance.isRunning) {
        setState(() => _active = Mesh.instance.isRunning);
      }
    });
  }

  /// Nom local du contact Bluetooth dont la clé publique est [sender], ou null si cet expéditeur
  /// n'est pas (ou plus) dans les contacts. Corrigé (usurpation) : le journal affichait avant un
  /// simple préfixe de clé publique, que n'importe qui peut choisir ; seuls les messages d'un
  /// contact validé par QR sont désormais affichés, sous le nom qu'on lui a donné.
  String? _labelFor(List<int> sender) {
    for (final c in _contacts) {
      if (c.peer.length != sender.length) continue;
      var same = true;
      for (var i = 0; i < sender.length; i++) {
        if (c.peer[i] != sender[i]) {
          same = false;
          break;
        }
      }
      if (same) return c.label;
    }
    return null;
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

  /// Efface le journal affiché ET la table `inbox` sur disque (voir [Mesh.clearInbox]) — jamais
  /// l'un sans l'autre, sinon un message effacé à l'écran réapparaîtrait au prochain chargement de
  /// cet écran (voir `initState`, qui recharge l'historique persistant depuis la base). Confirmation
  /// requise : irréversible, même style que la suppression de compte (voir lock_screens.dart).
  Future<void> _confirmClearLog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Effacer le journal Bluetooth ?'),
        content: const Text(
          'Les messages déjà reçus seront effacés de ce téléphone. Cette action est irréversible '
          'et ne concerne que ce journal (les contacts et le reste du compte ne sont pas touchés).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Mesh.instance.clearInbox();
    if (!mounted) return;
    setState(() => _log.removeWhere((l) => !l.isStatus));
  }

  /// Compose et met en file un message pour [contact] (voir [Mesh.queueMessage]). Le message part
  /// réellement dès le prochain appareil Murmure croisé qui le relaie ou le lui remet directement
  /// — pas forcément tout de suite, c'est le principe même du store-and-forward hors-ligne.
  ///
  /// LIMITE DU CLIQUET (200 rangs, voir `Mesh._maxRatchetSkipAhead` dans mesh.dart) : si plus de
  /// 200 messages écrits pour un contact ne lui parviennent jamais (perdus, expirés après 72 h,
  /// évincés des files de relais), le message suivant qui arrive est hors fenêtre et ne peut plus
  /// être déchiffré ; le canal de réception de ce contact reste alors bloqué. Pas de bouton
  /// « Réinitialiser le canal avec ce contact » : effacer l'état local du cliquet ferait repartir
  /// les deux chaînes du MÊME secret ECDH statique (refaire l'échange QR redonne les mêmes clés
  /// publiques), donc des MÊMES clés de message — rejeu possible des anciennes enveloppes encore en
  /// circulation et réutilisation de clés AES-GCM. Une réinitialisation sûre exige un nouvel
  /// aléa partagé (nouvelle époque de cliquet), c.-à-d. un changement de protocole, hors de cette
  /// passe. Contournement actuel : régénérer son identité Bluetooth (effacement du mode maillé) et
  /// refaire l'échange QR des deux côtés.
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
    try {
      await Mesh.instance.queueMessage(recipientPublicKey: contact.peer, text: text);
    } on MeshMessageTooLongException catch (e) {
      // Trouvé en audit interne, voir le commentaire de meshMaxPlaintextBytes dans
      // mesh_crypto.dart : sans ce rattrapage, un message trop long pour une enveloppe mesh était
      // mis en file sans erreur, puis silencieusement ignoré pour toujours au moment du relais —
      // l'utilisateur croyait son message parti alors qu'il ne le serait jamais.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Message trop long pour le mode Bluetooth (${e.actualBytes} octets, max ${e.maxBytes}) '
            '— raccourcissez-le.'),
      ));
      return;
    }
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
      // Corrigé (Android 12+) : la localisation n'est déclarée dans le manifeste que jusqu'à
      // l'API 30 (`maxSdkVersion="30"`, BLUETOOTH_SCAN en `neverForLocation` au-delà). La demander
      // sur Android 12+ renvoyait un refus systématique, donc « Permissions Bluetooth refusées »
      // et un mode hors-ligne impossible à activer. On ne la demande que si SDK <= 30 (ou si la
      // version est inconnue sur Android, par prudence).
      final sdk = Platform.isAndroid ? await MeshForegroundService.sdkInt() : null;
      final needsLocation = Platform.isAndroid && (sdk == null || sdk <= 30);
      final granted = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        if (needsLocation) Permission.locationWhenInUse, // scan BLE sur Android <= 11
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
      // Android 13+ : POST_NOTIFICATIONS est nécessaire (1) à la notification du service de
      // premier plan (sinon invisible, voir MeshForegroundService.kt) et (2) au signal « nouveau
      // message » de MeshOpsecNotifier. Elle n'est sinon demandée que par CallOpsecNotifier après
      // connexion Matrix + déverrouillage : un usage « mesh seul » ne l'aurait jamais obtenue.
      // Demandée ici, au geste explicite de l'utilisateur ; un refus ne bloque PAS le mode
      // hors-ligne (le relais BLE fonctionne sans, seul le signal de réception manque). Sans effet
      // (accordée d'office) avant Android 13.
      if (Platform.isAndroid) {
        try {
          await Permission.notification.request();
        } catch (_) {
          // Best-effort.
        }
      }
      try {
        await Mesh.instance.start();
      } catch (_) {
        // Trouvé en audit interne (revue croisée IA) : Mesh.start() peut lever (Bluetooth
        // désactivé, par exemple), ce qui restait auparavant non rattrapé ici — le bouton
        // restait bloqué en chargement indéfiniment (le setState de fin de méthode n'était
        // jamais atteint) pour un testeur dont le Bluetooth est simplement coupé.
        if (mounted) {
          setState(() => _busy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Impossible d\'activer le mode hors-ligne (Bluetooth désactivé ?)'),
            ),
          );
        }
        return;
      }
    } else {
      await Mesh.instance.stop();
    }
    if (mounted) setState(() {
      _active = Mesh.instance.isRunning;
      _busy = false;
    });
  }

  /// Journal affiché : statuts + messages dont l'expéditeur est un contact connu (voir
  /// [_labelFor]) ; les autres ne sont jamais affichés.
  List<_LogEntry> get _visibleLog =>
      _log.where((l) => l.isStatus || _labelFor(l.sender!) != null).toList();

  static String _initial(String label) => label.isEmpty ? '?' : label.characters.first.toUpperCase();

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
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.qr_code_2),
                      tooltip: 'Afficher en QR',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => MeshQrScreen(code: _myCode!)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copier',
                      onPressed: _copyMyCode,
                    ),
                  ],
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
          Row(
            children: [
              Expanded(
                child: Text('Journal', style: Theme.of(context).textTheme.titleMedium),
              ),
              if (_visibleLog.any((l) => !l.isStatus))
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Effacer le journal',
                  onPressed: _confirmClearLog,
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (_visibleLog.isEmpty)
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
            ..._visibleLog.map((l) => Card(
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
                              _initial(_labelFor(l.sender!)!),
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
                        : Text('De ${_labelFor(l.sender!)!}'),
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
