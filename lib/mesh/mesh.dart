import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../account.dart';
import 'mesh_crypto.dart';
import 'mesh_gatt_server.dart';

/// Réseau maillé Bluetooth Low Energy : fonctionnement de Murmure sans aucun serveur, pour les
/// coupures réseau (brouillage, manifestation). Principe « store-and-forward » : chaque téléphone
/// garde en mémoire les messages qu'il a vus et les repasse à tout appareil Murmure qu'il croise,
/// jusqu'à ce qu'ils atteignent leur destinataire (ou expirent — voir [MeshEnvelope.maxAgeHours]).
///
/// Chaque message reste chiffré de bout en bout pour son destinataire (voir mesh_crypto.dart) :
/// un relais intermédiaire ne peut ni le lire ni savoir à qui il est destiné au-delà de la clé
/// publique de destination. Ce canal est indépendant du compte Matrix et de la clé maîtresse
/// administrateur : rien dans cette classe ne donne à quiconque (y compris l'administrateur de
/// l'appli) la capacité de déchiffrer un message en transit.
///
/// Le paquet `flutter_blue_plus` (comme la quasi-totalité des bibliothèques BLE Flutter) ne pilote
/// que le rôle "central" — scanner et se connecter à d'autres appareils — jamais le rôle
/// "peripheral" (annoncer un service GATT que d'autres peuvent découvrir et lire). Le rôle
/// périphérique est donc assuré en natif par [MeshGattServerBridge], qui pilote un vrai
/// `BluetoothGattServer` Kotlin (voir android/.../MeshGattServer.kt, sur le modèle du canal
/// calculatrice de MainActivity.kt). Les deux rôles tournent simultanément dans [start] : ce
/// téléphone scanne ET s'annonce, donc deux appareils Murmure finissent par se découvrir
/// mutuellement, pas seulement celui qui scanne en premier.
///
/// LIMITE HONNÊTE RESTANTE : le serveur GATT natif ne répond, à chaque lecture, qu'avec UNE seule
/// enveloppe à la fois (celle que [_rotateReadValue] lui a donnée en dernier) — pas de pagination
/// sur une connexion GATT unique. [_rotateReadValue] fait tourner cette valeur dans la file
/// d'attente à intervalle régulier, donc un appareil qui reste à portée assez longtemps finit par
/// tout récupérer, mais une rencontre très brève peut ne récupérer qu'une partie de ce qui
/// l'attend. Un vrai protocole de pagination par caractéristique serait l'étape suivante si le
/// débit observé en conditions réelles (manifestation, beaucoup d'appareils, peu de temps de
/// contact) s'avère insuffisant.
class Mesh {
  Mesh._();
  static Mesh? _instance;
  static Mesh get instance => _instance ??= Mesh._();

  /// UUID de service Murmure : identifie un appareil qui fait tourner le mode maillé, sans rien
  /// révéler d'autre (pas d'identifiant utilisateur dans l'annonce BLE elle-même).
  ///
  /// LIMITE HONNÊTE (reconnue, pas corrigée dans cette passe — point soulevé en audit) : cet UUID
  /// est FIXE, identique sur tous les appareils et dans le temps. Qui que ce soit équipé d'un
  /// scanner BLE passif (capteur statique dans la rue, matériel de surveillance) peut détecter
  /// « un appareil fait tourner Murmure ici » sans jamais s'y connecter ni rien déchiffrer — une
  /// empreinte de présence, pas une fuite de contenu ni d'identité.
  ///
  /// Le faire varier n'est pas une simple modification locale : le rôle « central » (scan) doit
  /// savoir QUEL UUID chercher pour découvrir le service. Le faire dépendre d'un secret partagé
  /// entre contacts déjà validés casserait la découverte entre deux appareils Murmure qui ne se
  /// connaissent pas encore — or c'est précisément ce que le relais « store-and-forward » décrit
  /// ci-dessus doit permettre : n'importe quel appareil Murmure croisé relaie, pas seulement les
  /// contacts connus. Un système à grande échelle confronté au même problème (notification
  /// d'exposition Apple/Google, par ex.) a tranché dans le même sens : l'identifiant de SERVICE
  /// annoncé reste fixe et public ; seule la charge utile de chaque annonce est, elle, à durée de
  /// vie courte et imprévisible. Une vraie limitation de cette empreinte-ci suivrait le même
  /// modèle (garder ce UUID découvrable publiquement, réduire l'exposition autrement — ex. ne
  /// publier le service que par rafales plutôt qu'en continu) plutôt que de faire tourner l'UUID
  /// lui-même, qui romprait la découverte entre inconnus sans walkthrough de protocole public déjà
  /// éprouvé pour ce cas précis. Non implémenté ici : décision d'architecture (tolérer cette
  /// empreinte de présence vs limiter la portée du mode maillé aux seuls contacts déjà validés)
  /// qui revient à l'utilisateur, pas à corriger silencieusement.
  static final serviceUuid = Guid('5a4d5552-4d55-5245-0000-000000000001');
  static final inboxCharUuid = Guid('5a4d5552-4d55-5245-0000-000000000002');

  sqlcipher.Database? _db;
  MeshIdentity? _identity;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<Uint8List>? _gattSub;
  Timer? _relayTimer;
  Timer? _rotateTimer;
  int _rotateIndex = 0;
  bool _running = false;

  /// File d'attente FIFO : sérialise tout ce qui touche à l'état du cliquet (table `ratchet_chain`
  /// / `ratchet_skipped`) et à la déduplication (`seen`), pour [_handleIncoming] et [queueMessage].
  ///
  /// Trouvé en audit interne : [_onScanResults] lance volontairement [_tryExchange] EN PARALLÈLE
  /// (`unawaited`) pour chaque appareil Murmure à portée — exactement le comportement voulu pour
  /// atteindre le plus de pairs possible par cycle de scan. Mais le même envoi (même expéditeur,
  /// même rang de cliquet) relayé par deux chemins et arrivant quasi simultanément via deux de ces
  /// appels concurrents à [_handleIncoming] (ou un appel réception + un appel écriture GATT
  /// entrante en même temps) crée une véritable course : la vérification « déjà vu » (`seen`) lit
  /// puis écrit en deux opérations séparées, et l'avancement du cliquet de réception lit puis
  /// écrit lui aussi en deux temps — sans sérialisation, deux appels concurrents pour la même
  /// enveloppe peuvent tous les deux franchir la vérification « pas encore vu » avant que l'un des
  /// deux n'écrive, consommer deux fois le même rang de cliquet, et perdre un message au passage
  /// (celui dont le rang se retrouve déjà consommé à son tour). Dans un maillage dense (plusieurs
  /// téléphones Murmure à portée en même temps, le scénario même visé par cette fonctionnalité en
  /// manifestation), cette situation n'est pas un cas rare provoqué par un attaquant : c'est une
  /// conséquence directe et prévisible de la diffusion redondante par plusieurs chemins qui fait
  /// tout l'intérêt du store-and-forward. Aucune fuite de clé ou de contenu vers un tiers n'en
  /// découle (l'enveloppe reste authentifiée par AES-GCM), seulement une perte de fiabilité. Fixé
  /// en sérialisant toutes les opérations qui touchent cet état partagé : le coût (BLE est de
  /// toute façon le goulot d'étranglement, pas le calcul cryptographique local) est négligeable.
  Future<void> _mutex = Future.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _mutex.then((_) => op());
    _mutex = result.then((_) {}, onError: (_) {});
    return result;
  }

  final _eventsController = StreamController<MeshEvent>.broadcast();
  Stream<MeshEvent> get events => _eventsController.stream;

  Future<sqlcipher.Database> _database() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, Account.kMeshDbName);
    _db = await sqlcipher.openDatabase(
      dbPath,
      password: await Account.dbKey(),
      version: 2,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE outbox (
            id BLOB PRIMARY KEY,
            recipient BLOB NOT NULL,
            payload BLOB NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE seen (
            id BLOB PRIMARY KEY,
            seen_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE inbox (
            id BLOB PRIMARY KEY,
            sender BLOB NOT NULL,
            plaintext TEXT NOT NULL,
            received_at INTEGER NOT NULL
          )
        ''');
        await _createRatchetTables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        // v1 -> v2 : ajout du cliquet symétrique (confidentialité persistante, voir
        // mesh_crypto.dart). Les anciennes tables ne changent pas ; on ajoute seulement les deux
        // nouvelles. Aucune donnée ancienne à migrer : les messages déjà passés restaient
        // chiffrés avec l'ancien schéma statique et ne dépendent pas de ces tables.
        if (oldV < 2) await _createRatchetTables(db);
      },
    );
    return _db!;
  }

  Future<void> _createRatchetTables(sqlcipher.Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ratchet_chain (
        peer BLOB NOT NULL,
        direction TEXT NOT NULL,
        chain_key BLOB NOT NULL,
        counter INTEGER NOT NULL,
        PRIMARY KEY (peer, direction)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ratchet_skipped (
        peer BLOB NOT NULL,
        counter INTEGER NOT NULL,
        message_key BLOB NOT NULL,
        PRIMARY KEY (peer, counter)
      )
    ''');
  }

  Future<MeshIdentity> identity() async {
    _identity ??= await MeshIdentity.loadOrCreate((name) => Account.seed(name));
    return _identity!;
  }

  /// Démarre le scan BLE et la boucle de relais périodique. À appeler quand l'utilisateur active
  /// le mode Bluetooth (voir ui/mesh_screen.dart), jamais automatiquement en arrière-plan sans son
  /// accord (consommation de batterie, et il doit savoir que son téléphone émet/écoute du BLE).
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _database();
    await identity();
    await FlutterBluePlus.startScan(
      withServices: [serviceUuid],
      continuousUpdates: true,
      timeout: const Duration(days: 1),
    );
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    _relayTimer = Timer.periodic(const Duration(seconds: 20), (_) => _purgeExpired());

    // Rôle périphérique natif : s'annonce et répond aux lectures/écritures d'autres téléphones.
    // Échoue silencieusement sur les plateformes sans ce canal (iOS, desktop) ou si le Bluetooth
    // est indisponible — le mode reste alors limité au rôle central, comme avant cette extension.
    await MeshGattServerBridge.start();
    _gattSub = MeshGattServerBridge.incoming().listen(_onGattWrite);
    _rotateTimer = Timer.periodic(const Duration(seconds: 15), (_) => _rotateReadValue());
    unawaited(_rotateReadValue());

    _eventsController.add(const MeshEvent.started());
  }

  Future<void> stop() async {
    _running = false;
    await _scanSub?.cancel();
    _scanSub = null;
    _relayTimer?.cancel();
    _relayTimer = null;
    await _gattSub?.cancel();
    _gattSub = null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    await MeshGattServerBridge.stop();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _eventsController.add(const MeshEvent.stopped());
  }

  /// Un autre téléphone vient d'écrire une enveloppe sur notre caractéristique (rôle
  /// périphérique) : on la traite exactement comme une enveloppe récupérée en scannant (rôle
  /// central) — même déduplication, même logique de déchiffrement ou de relais.
  Future<void> _onGattWrite(Uint8List bytes) async {
    final env = MeshEnvelope.deserialize(bytes);
    if (env != null) await _handleIncoming(env);
  }

  /// Fait tourner la valeur que le serveur GATT natif renvoie à la prochaine lecture, parmi notre
  /// file d'attente (voir la limite documentée en tête de fichier).
  Future<void> _rotateReadValue() async {
    final queue = await _allOutbox();
    if (queue.isEmpty) {
      await MeshGattServerBridge.setReadValue(Uint8List(0));
      return;
    }
    _rotateIndex = _rotateIndex % queue.length;
    final env = queue[_rotateIndex];
    _rotateIndex++;
    await MeshGattServerBridge.setReadValue(env.serialize());
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    for (final r in results) {
      // Un appareil Murmure à portée : on tente de lui livrer tout ce qu'on transporte pour lui,
      // et de récupérer ce qu'il transporte pour nous — sans jamais rien déchiffrer en chemin.
      unawaited(_tryExchange(r.device));
    }
  }

  Future<void> _tryExchange(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 8), autoConnect: false);
      final services = await device.discoverServices();
      final svc = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (svc == null) return;
      final char = svc.characteristics.where((c) => c.uuid == inboxCharUuid).firstOrNull;
      if (char == null) return;

      // On pousse chaque enveloppe de notre file d'attente, une par écriture GATT (limite MTU).
      final queue = await _allOutbox();
      for (final env in queue) {
        final bytes = env.serialize();
        if (bytes.length > 512) continue; // au-delà du MTU négocié typique, on laisse de côté
        try {
          await char.write(bytes, withoutResponse: false);
        } catch (_) {
          continue;
        }
      }

      // Et on lit ce que l'autre appareil a en attente pour nous (notification ou lecture directe
      // selon ce que la caractéristique autorise — dépend du serveur GATT distant, voir la limite
      // documentée en tête de fichier : ceci suppose un pair qui implémente déjà le serveur).
      if (char.properties.read) {
        final incoming = await char.read();
        final env = MeshEnvelope.deserialize(Uint8List.fromList(incoming));
        if (env != null) await _handleIncoming(env);
      }
    } catch (_) {
      // Échecs de connexion BLE fréquents et attendus (appareil hors portée entre-temps, etc.) :
      // on ne les remonte pas individuellement pour ne pas noyer l'utilisateur de messages.
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _handleIncoming(MeshEnvelope env) => _serialized(() => _handleIncomingLocked(env));

  Future<void> _handleIncomingLocked(MeshEnvelope env) async {
    final db = await _database();
    final already = await db.query('seen', where: 'id = ?', whereArgs: [env.id], limit: 1);
    if (already.isNotEmpty) return;
    await db.insert('seen', {'id': env.id, 'seen_at': DateTime.now().millisecondsSinceEpoch});

    final me = await identity();
    if (_bytesEqual(env.recipientHint, await meshRecipientHint(me.publicKeyBytes))) {
      final msgKey = await _recvKeyFor(env.senderPublicKey, env.chainCounter);
      final plain = msgKey == null ? null : await meshDecryptWithKey(messageKey: msgKey, envelope: env);
      if (plain != null) {
        await db.insert('inbox', {
          'id': env.id,
          'sender': env.senderPublicKey,
          'plaintext': plain,
          'received_at': DateTime.now().millisecondsSinceEpoch,
        });
        _eventsController.add(MeshEvent.messageReceived(env.senderPublicKey, plain));
        return;
      }
    }
    // Pas pour nous (ou déchiffrement impossible, ce qui revient au même pour un relais) :
    // on le garde dans notre propre file pour le repasser au prochain appareil croisé.
    if (!env.expired) {
      await db.insert(
        'outbox',
        {
          'id': env.id,
          'recipient': env.recipientHint,
          'payload': env.relayed().serialize(),
          'created_at': env.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
      );
    }
  }

  /// Met un message en file pour un contact, à relayer dès qu'un appareil Murmure est croisé.
  Future<void> queueMessage({required Uint8List recipientPublicKey, required String text}) =>
      _serialized(() => _queueMessageLocked(recipientPublicKey: recipientPublicKey, text: text));

  Future<void> _queueMessageLocked({required Uint8List recipientPublicKey, required String text}) async {
    final me = await identity();
    final next = await _nextSendKey(recipientPublicKey);
    final env = await meshEncryptWithKey(
      messageKey: next.messageKey,
      chainCounter: next.counter,
      senderPublicKey: me.publicKeyBytes,
      recipientHint: await meshRecipientHint(recipientPublicKey),
      plaintext: text,
    );
    final db = await _database();
    await db.insert('outbox', {
      'id': env.id,
      'recipient': env.recipientHint,
      'payload': env.serialize(),
      'created_at': env.createdAt.millisecondsSinceEpoch,
    });
  }

  // -----------------------------------------------------------------------------------------------
  // Cliquet symétrique (forward secrecy) — voir mesh_crypto.dart pour le pourquoi et le comment.
  // Cette section gère l'ÉTAT persistant (en base, chiffrée) ; mesh_crypto.dart ne fait que les
  // calculs sans jamais toucher au disque.
  // -----------------------------------------------------------------------------------------------

  /// Borne le nombre de crans qu'un message reçu peut forcer à avancer d'un coup : au-delà, on
  /// abandonne plutôt que de faire calculer un nombre de HMAC arbitrairement grand à partir d'un
  /// compteur falsifié (un relais malveillant ne peut pas altérer le contenu — authentifié par le
  /// GCM — mais pourrait forger ce compteur en clair pour un déni de service local).
  static const _maxRatchetSkipAhead = 200;

  /// Nombre de clés de rangs sautés conservées par contact, pour tolérer les messages qui
  /// arrivent dans le désordre (relais par plusieurs chemins Bluetooth) sans garder une réserve
  /// illimitée.
  static const _maxSkippedPerPeer = 50;

  /// Amorce les deux chaînes (envoi/réception) avec [peerPublicKey] depuis le secret ECDH, SI ce
  /// n'est pas déjà fait — idempotent, ignore silencieusement si l'état existe déjà.
  Future<void> _ensureRatchetSeeded(Uint8List peerPublicKey) async {
    final db = await _database();
    final existing = await db.query('ratchet_chain',
        where: 'peer = ? AND direction = ?', whereArgs: [peerPublicKey, 'send'], limit: 1);
    if (existing.isNotEmpty) return;
    final me = await identity();
    final shared = await me.sharedSecretWith(peerPublicKey);
    final (chainA, chainB) = await meshRatchetRoots(shared);
    final iSendOnA = meshSendsOnChainA(me.publicKeyBytes, peerPublicKey);
    final sendChain = iSendOnA ? chainA : chainB;
    final recvChain = iSendOnA ? chainB : chainA;
    await db.insert(
      'ratchet_chain',
      {'peer': peerPublicKey, 'direction': 'send', 'chain_key': sendChain, 'counter': 0},
      conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
    );
    await db.insert(
      'ratchet_chain',
      {'peer': peerPublicKey, 'direction': 'recv', 'chain_key': recvChain, 'counter': 0},
      conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
    );
  }

  /// Avance la chaîne d'ENVOI vers [peerPublicKey] d'un cran et retourne la clé du message à
  /// chiffrer maintenant, avec son rang. L'ancienne clé de chaîne est écrasée en base : elle ne
  /// peut plus jamais être recalculée (confidentialité persistante).
  Future<({Uint8List messageKey, int counter})> _nextSendKey(Uint8List peerPublicKey) async {
    await _ensureRatchetSeeded(peerPublicKey);
    final db = await _database();
    final rows = await db.query('ratchet_chain',
        where: 'peer = ? AND direction = ?', whereArgs: [peerPublicKey, 'send'], limit: 1);
    final row = rows.first;
    final chainKey = Uint8List.fromList(row['chain_key'] as List<int>);
    final counter = row['counter'] as int;
    final step = await meshRatchetStep(chainKey);
    await db.update(
      'ratchet_chain',
      {'chain_key': step.nextChainKey, 'counter': counter + 1},
      where: 'peer = ? AND direction = ?',
      whereArgs: [peerPublicKey, 'send'],
    );
    return (messageKey: step.messageKey, counter: counter);
  }

  /// Retrouve la clé de message pour déchiffrer un message de rang [counter] de [peerPublicKey] :
  /// soit déjà en réserve (message arrivé après un autre plus récent), soit en avançant la chaîne
  /// de réception jusqu'à ce rang (en mettant en réserve les rangs sautés au passage). Retourne
  /// null si la clé n'est plus disponible : rang déjà consommé et oublié (comportement attendu —
  /// confidentialité persistante, pas une panne), ou saut trop grand pour être raisonnable.
  Future<Uint8List?> _recvKeyFor(Uint8List peerPublicKey, int counter) async {
    await _ensureRatchetSeeded(peerPublicKey);
    final db = await _database();

    final skipped = await db.query('ratchet_skipped',
        where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter], limit: 1);
    if (skipped.isNotEmpty) {
      await db.delete('ratchet_skipped', where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter]);
      return Uint8List.fromList(skipped.first['message_key'] as List<int>);
    }

    final rows = await db.query('ratchet_chain',
        where: 'peer = ? AND direction = ?', whereArgs: [peerPublicKey, 'recv'], limit: 1);
    final row = rows.first;
    var chainKey = Uint8List.fromList(row['chain_key'] as List<int>);
    final next = row['counter'] as int;

    if (counter < next) return null; // déjà passé, pas en réserve : clé perdue pour de bon.
    final steps = counter - next;
    if (steps > _maxRatchetSkipAhead) return null; // saut déraisonnable, on abandonne.

    Uint8List? wanted;
    for (var i = 0; i <= steps; i++) {
      final step = await meshRatchetStep(chainKey);
      if (i == steps) {
        wanted = step.messageKey;
      } else {
        await db.insert(
          'ratchet_skipped',
          {'peer': peerPublicKey, 'counter': next + i, 'message_key': step.messageKey},
          conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace,
        );
      }
      chainKey = step.nextChainKey;
    }
    await db.update(
      'ratchet_chain',
      {'chain_key': chainKey, 'counter': counter + 1},
      where: 'peer = ? AND direction = ?',
      whereArgs: [peerPublicKey, 'recv'],
    );
    await _trimSkipped(peerPublicKey);
    return wanted;
  }

  /// Ne garde que les [_maxSkippedPerPeer] rangs sautés les plus récents par contact (les plus
  /// anciens ont le moins de chances d'être un jour réclamés par un message très en retard).
  Future<void> _trimSkipped(Uint8List peerPublicKey) async {
    final db = await _database();
    final rows = await db.query('ratchet_skipped',
        where: 'peer = ?', whereArgs: [peerPublicKey], orderBy: 'counter DESC');
    if (rows.length <= _maxSkippedPerPeer) return;
    for (final r in rows.skip(_maxSkippedPerPeer)) {
      await db.delete('ratchet_skipped',
          where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, r['counter']]);
    }
  }

  Future<List<MeshEnvelope>> _allOutbox() async {
    final db = await _database();
    final rows = await db.query('outbox');
    return rows
        .map((r) => MeshEnvelope.deserialize(Uint8List.fromList(r['payload'] as List<int>)))
        .whereType<MeshEnvelope>()
        .where((e) => !e.expired)
        .toList();
  }

  Future<List<Map<String, Object?>>> inbox() async {
    final db = await _database();
    return db.query('inbox', orderBy: 'received_at DESC');
  }

  Future<void> _purgeExpired() async {
    final db = await _database();
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: MeshEnvelope.maxAgeHours))
        .millisecondsSinceEpoch;
    await db.delete('outbox', where: 'created_at < ?', whereArgs: [cutoff]);
    await db.delete('seen', where: 'seen_at < ?', whereArgs: [cutoff]);
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Efface toute trace du mode maillé (messages reçus, file d'attente, identité BLE) :
  /// appelé par [Account.wipeLocal] lors d'un effacement d'urgence.
  static Future<void> reset() async {
    final m = instance;
    await m.stop();
    try {
      await m._db?.close();
    } catch (_) {}
    m._db = null;
    m._identity = null;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, Account.kMeshDbName);
    try {
      await sqlcipher.deleteDatabase(path);
    } catch (_) {}
  }
}

/// Événements du mode maillé, pour l'UI (ui/mesh_screen.dart).
sealed class MeshEvent {
  const MeshEvent();
  const factory MeshEvent.started() = MeshStarted;
  const factory MeshEvent.stopped() = MeshStopped;
  const factory MeshEvent.messageReceived(List<int> sender, String text) = MeshMessageReceived;
}

class MeshStarted extends MeshEvent {
  const MeshStarted();
}

class MeshStopped extends MeshEvent {
  const MeshStopped();
}

class MeshMessageReceived extends MeshEvent {
  const MeshMessageReceived(this.sender, this.text);
  final List<int> sender;
  final String text;
}

extension FirstOrNullExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
