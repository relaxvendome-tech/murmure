import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../account.dart';
import 'mesh_crypto.dart';
import 'mesh_foreground_service.dart';
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

  /// Appareils avec lesquels un échange GATT (connexion → écriture → lecture → déconnexion, voir
  /// [_tryExchange]) est déjà en cours, et horodatage du dernier échange terminé avec chacun.
  ///
  /// Trouvé en audit interne — un défaut réel, pas une optimisation de principe : [_onScanResults]
  /// est rappelé en continu (`continuousUpdates: true` au scan) avec la liste des appareils
  /// actuellement visibles, potentiellement plusieurs fois par seconde pour un même appareil à
  /// portée stable. Avant cette correction, CHAQUE appel déclenchait un nouvel essai d'échange
  /// (`unawaited(_tryExchange(...))`) pour chaque appareil visible, sans jamais vérifier qu'un
  /// échange avec ce même appareil n'était pas déjà en cours. `BluetoothDevice.connect()` sérialise
  /// bien ses opérations par un mutex global interne au paquet (vérifié dans le code source réel de
  /// `flutter_blue_plus` au tag correspondant à la version pinnée, release 1.36.0), donc rien ne
  /// pouvait planter — mais ça ne fait qu'empiler les tentatives en attente derrière ce mutex, sans
  /// jamais les annuler : pour un ou deux téléphones croisés en continu, la radio Bluetooth restait
  /// occupée en boucle à reconnecter/réécrire/relire/déconnecter le(s) même(s) appareil(s) aussi
  /// vite que le mutex le permettait, bien au-delà de ce qu'un relais de messages exige — gaspillage
  /// de batterie et de bande passante radio, qui pouvait aussi retarder l'échange avec un AUTRE
  /// appareil nouvellement détecté, coincé derrière cette file. On ignore maintenant un appareil
  /// déjà en cours d'échange, et on applique un délai minimal entre deux échanges réussis avec le
  /// même appareil (voir [_exchangeCooldown]) — le relais reste aussi réactif que nécessaire (un
  /// message neuf dans la file sera de toute façon proposé au prochain échange, pas perdu), sans
  /// solliciter la radio en continu pour rien.
  final _inFlightExchanges = <DeviceIdentifier>{};
  final _lastExchangeAt = <DeviceIdentifier, DateTime>{};
  static const _exchangeCooldown = Duration(seconds: 10);

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
      version: 3,
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
        // v2 -> v3 : trouvé en audit interne — les clés de rangs sautés (`ratchet_skipped`,
        // conservées pour tolérer les messages arrivant dans le désordre) n'avaient aucune
        // expiration par ÂGE, seulement une limite de COMPTE (_maxSkippedPerPeer) par contact.
        // Concrètement : la clé d'un message jamais livré restait indéfiniment en base tant que
        // ce même contact n'était pas recroisé assez de fois pour l'évincer par ancienneté — un
        // écart réel avec la garantie de confidentialité persistante que la documentation de ce
        // fichier affirme sans nuance pour « tous les messages déjà passés ». Ajoute une colonne
        // d'horodatage pour purger par âge ces clés (voir _purgeExpired), alignée sur la même
        // fenêtre que les enveloppes elles-mêmes (MeshEnvelope.maxAgeHours) : une clé gardée plus
        // longtemps que la durée de vie maximale d'un message n'a plus aucune utilité, le message
        // qu'elle pourrait déchiffrer étant de toute façon considéré expiré et abandonné ailleurs.
        if (oldV < 3) {
          await db.execute(
              'ALTER TABLE ratchet_skipped ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0');
        }
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
        created_at INTEGER NOT NULL DEFAULT 0,
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
  ///
  /// Trouvé en audit interne : démarre aussi le service de premier plan Android (voir
  /// mesh_foreground_service.dart / MeshForegroundService.kt), sans quoi rien n'empêchait Android
  /// de suspendre ce scan dès l'appli mise en arrière-plan ou l'écran verrouillé — alors que c'est
  /// justement l'usage visé (téléphone en poche en manifestation) qui l'exige. Best-effort comme
  /// le reste du pont natif : son échec (plateforme sans ce canal, ou refus du système) ne bloque
  /// jamais le scan BLE lui-même, qui continue de fonctionner au premier plan comme avant.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _database();
    await identity();
    final calcMode = await Account.read('calc_mode') == '1';
    unawaited(MeshForegroundService.start(calcMode: calcMode));
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
    _inFlightExchanges.clear();
    _lastExchangeAt.clear();
    await MeshGattServerBridge.stop();
    await MeshForegroundService.stop();
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
      final id = r.device.remoteId;
      // Voir le commentaire de [_inFlightExchanges] : on laisse un échange déjà en cours se
      // terminer, et on respecte un délai minimal depuis le dernier échange réussi avec cet
      // appareil, plutôt que de ré-essayer à chaque nouvel appel de ce callback.
      if (_inFlightExchanges.contains(id)) continue;
      final last = _lastExchangeAt[id];
      if (last != null && DateTime.now().difference(last) < _exchangeCooldown) continue;

      // Un appareil Murmure à portée : on tente de lui livrer tout ce qu'on transporte pour lui,
      // et de récupérer ce qu'il transporte pour nous — sans jamais rien déchiffrer en chemin.
      _inFlightExchanges.add(id);
      unawaited(_tryExchange(r.device).whenComplete(() {
        _inFlightExchanges.remove(id);
        _lastExchangeAt[id] = DateTime.now();
      }));
    }
  }

  Future<void> _tryExchange(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 8), autoConnect: false);

      // Trouvé en audit interne — un défaut sérieux, pas cosmétique : le commentaire ci-dessous
      // ("au-delà du MTU négocié typique") supposait depuis le début qu'une négociation de MTU
      // avait lieu quelque part, mais rien dans ce fichier ne l'a jamais demandée. Le MTU ATT par
      // défaut, SANS négociation explicite, est de 23 octets (20 utiles après les 3 octets
      // d'en-tête ATT) — alors que la plus petite enveloppe possible (`MeshEnvelope.serialize()` :
      // identifiant 16 + clé publique expéditeur 32 + indice destinataire 32 + compteur 4 + nonce
      // 12 + longueur 2 + MAC + ttl 1 + horodatage 4, avant même le texte chiffré) dépasse déjà
      // largement ces 20 octets. Concrètement : `char.write()` plus bas échouait silencieusement
      // (`GATT_INVALID_ATTRIBUTE_LENGTH`, avalé par le `catch (_) { continue; }` suivant) pour
      // TOUT message réel — le relais Bluetooth ne délivrait jamais rien, quel que soit le temps
      // de contact entre deux téléphones. On demande maintenant explicitement un MTU de 517 (le
      // maximum du protocole ATT, voir Bluetooth Core Spec) avant d'écrire quoi que ce soit, ce
      // qui donne 514 octets utiles — au-delà du plafond de 512 déjà appliqué ci-dessous à chaque
      // enveloppe. Best-effort : un appareil qui refuse ou ignore la demande (iOS, où la
      // négociation est automatique et `requestMtu` n'a pas d'effet documenté ; un ancien
      // appareil Android) retombe sur le comportement déjà présent avant ce correctif, pas pire.
      try {
        await device.requestMtu(517);
      } catch (_) {
        // Voir le commentaire ci-dessus : on tente quand même les écritures, comme avant.
      }

      final services = await device.discoverServices();
      final svc = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (svc == null) return;
      final char = svc.characteristics.where((c) => c.uuid == inboxCharUuid).firstOrNull;
      if (char == null) return;

      // On pousse chaque enveloppe de notre file d'attente, une par écriture GATT (limite MTU).
      final queue = await _allOutbox();
      for (final env in queue) {
        final bytes = env.serialize();
        if (bytes.length > 512) continue; // au-delà du MTU négocié ci-dessus, on laisse de côté
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
        // Voir [_consumeSkippedKey] : ne retirer la clé de la réserve des rangs sautés que
        // maintenant que le déchiffrement est confirmé réussi, jamais avant.
        await _consumeSkippedKey(env.senderPublicKey, env.chainCounter);
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
  /// À appeler uniquement après un déchiffrement RÉUSSI avec une clé obtenue via [_recvKeyFor] —
  /// voir le commentaire dans cette méthode sur la branche « clé déjà en réserve ». Ne retire la
  /// clé de [ratchet_skipped] qu'ici, jamais avant d'avoir confirmé que le déchiffrement a abouti.
  /// Sans effet (et sans erreur) si [counter] ne correspond à aucune ligne — c'est le cas normal
  /// quand la clé provenait de l'avancée directe du cliquet plutôt que de la réserve.
  Future<void> _consumeSkippedKey(Uint8List peerPublicKey, int counter) async {
    final db = await _database();
    await db.delete('ratchet_skipped',
        where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter]);
  }

  Future<Uint8List?> _recvKeyFor(Uint8List peerPublicKey, int counter) async {
    await _ensureRatchetSeeded(peerPublicKey);
    final db = await _database();

    final skipped = await db.query('ratchet_skipped',
        where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter], limit: 1);
    if (skipped.isNotEmpty) {
      // Trouvé en audit interne (revue croisée IA, vérifiée contre ce code) : cette clé était
      // supprimée de la réserve ICI, avant même la tentative de déchiffrement par l'appelant. Un
      // paquet corrompu en transit (collision Bluetooth, retransmission partielle) fait échouer
      // l'authentification GCM côté [_handleIncomingLocked] — la clé était alors déjà perdue, alors
      // qu'un exemplaire valide du MÊME message (même rang de cliquet) pouvait très bien arriver
      // plus tard par un autre chemin du maillage (relais store-and-forward multi-chemins, c'est le
      // scénario normal, pas un cas limite) : ce second exemplaire valide devenait alors
      // définitivement indéchiffrable (« clé perdue pour de bon »), pour rien. La clé n'est
      // maintenant retirée de la réserve qu'après un déchiffrement confirmé réussi, voir
      // [_consumeSkippedKey] et son appel dans [_handleIncomingLocked].
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
          {
            'peer': peerPublicKey,
            'counter': next + i,
            'message_key': step.messageKey,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
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
    // Les rangées migrées depuis le schéma v2 (avant l'ajout de cette colonne) ont `created_at`
    // à 0 par défaut, donc toujours antérieures à `cutoff` : purgées dès le premier passage après
    // la mise à jour, faute de pouvoir connaître leur âge réel — cohérent avec l'intention (mieux
    // vaut perdre une clé de rang sauté déjà peu susceptible d'être un jour réclamée que la garder
    // indéfiniment, voir la note de migration v2 -> v3 plus haut).
    await db.delete('ratchet_skipped', where: 'created_at < ?', whereArgs: [cutoff]);
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
