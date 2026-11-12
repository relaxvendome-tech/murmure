import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../account.dart';
import '../lock.dart';
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
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _relayTimer;
  Timer? _rotateTimer;
  Timer? _permissionTimer;
  int _rotateIndex = 0;
  bool _running = false;

  /// Génération de cycle de vie, incrémentée par [stop] (donc aussi par [reset]). Corrigé :
  /// [start] enchaîne plusieurs `await` (ouverture de base, scan, serveur GATT natif…) ; un
  /// [stop]/[reset] survenant pendant l'un d'eux laissait ensuite [start] reprendre et créer des
  /// timers/abonnements orphelins (jamais annulés), voire ROUVRIR la base qu'un effacement
  /// d'urgence venait de supprimer. Après chaque `await`, [start] compare sa génération à celle-ci
  /// et, si elle a changé, défait ce qu'il a lui-même lancé et sort sans rien émettre.
  int _gen = 0;

  /// Incrémenté par [reset] seulement : permet à [_database]/[identity], dont l'ouverture était
  /// déjà en vol au moment d'un effacement d'urgence, de NE PAS réinstaller l'ancienne base ou
  /// l'ancienne identité dans ce singleton une fois l'effacement passé (voir ces méthodes).
  int _resetGen = 0;

  /// Vrai si le relais Bluetooth tourne (lecture seule, pour l'affichage d'état).
  bool get isRunning => _running;

  /// Vrai si le rôle périphérique natif (serveur GATT + annonce BLE) a confirmé son démarrage.
  /// Faux si l'annonce a été refusée par Android : le maillage tourne alors en rôle central seul.
  bool get peripheralActive => _peripheralActive;
  bool _peripheralActive = false;

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
    final resetGen = _resetGen;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, Account.kMeshDbName);
    final opened = await sqlcipher.openDatabase(
      dbPath,
      password: await Account.dbKey(),
      version: 5,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE outbox (
            id BLOB PRIMARY KEY,
            recipient BLOB NOT NULL,
            payload BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            own INTEGER NOT NULL DEFAULT 0
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
        await _createContactsTable(db);
      },
      onUpgrade: (db, oldV, newV) async {
        // v1 -> v2 : ajout du cliquet symétrique (confidentialité persistante, voir
        // mesh_crypto.dart). Les anciennes tables ne changent pas ; on ajoute seulement les deux
        // nouvelles. Aucune donnée ancienne à migrer : les messages déjà passés restaient
        // chiffrés avec l'ancien schéma statique et ne dépendent pas de ces tables.
        //
        // Trouvé en audit interne (revue croisée IA, vérifiée contre le code réel — bug réel, pas
        // un faux positif) : [_createRatchetTables] crée désormais `ratchet_skipped` avec sa
        // colonne `created_at` DÈS LA CRÉATION (voir plus bas), pour que les installations
        // neuves (onCreate) l'aient d'emblée. Mais cette même fonction est réutilisée ICI pour
        // amener un appareil de la version 1 à la version 2 — donc pour un tel appareil, la table
        // vient d'être créée AVEC la colonne. Le `if (oldV < 3)` qui suit étant alors également
        // vrai (1 < 3), l'ALTER TABLE qui l'accompagnait tentait d'ajouter une colonne déjà
        // présente : `duplicate column name: created_at`, une exception SQLite fatale faisant
        // planter l'appli au tout premier démarrage pour quiconque mettait à jour depuis une
        // version 1 directement vers la 4. Un `else if` (plutôt que deux `if` indépendants) rend
        // les deux branches mutuellement exclusives : un appareil en v1 obtient la colonne via la
        // création de table ci-dessus et n'a plus besoin de l'ALTER ; un appareil déjà en v2 (sans
        // cette colonne, schéma d'avant ce correctif) obtient l'ALTER sans repasser par la
        // création de table.
        if (oldV < 2) {
          await _createRatchetTables(db);
        } else if (oldV < 3) {
          // v2 -> v3 : les clés de rangs sautés (`ratchet_skipped`, conservées pour tolérer les
          // messages arrivant dans le désordre) n'avaient aucune expiration par ÂGE, seulement une
          // limite de COMPTE (_maxSkippedPerPeer) par contact. Concrètement : la clé d'un message
          // jamais livré restait indéfiniment en base tant que ce même contact n'était pas
          // recroisé assez de fois pour l'évincer par ancienneté — un écart réel avec la garantie
          // de confidentialité persistante que la documentation de ce fichier affirme sans nuance
          // pour « tous les messages déjà passés ». Ajoute une colonne d'horodatage pour purger
          // par âge ces clés (voir _purgeExpired), alignée sur la même fenêtre que les enveloppes
          // elles-mêmes (MeshEnvelope.maxAgeHours).
          await db.execute(
              'ALTER TABLE ratchet_skipped ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0');
        }
        // v3 -> v4 : trouvé en audit interne — [queueMessage] existait déjà (mise en file d'un
        // message chiffré pour une clé publique donnée) mais aucun écran ne l'appelait jamais, et
        // aucune table ne conservait les contacts Bluetooth ajoutés par QR (voir le commentaire de
        // [MeshIdentity] dans mesh_crypto.dart, qui mentionne ce flux sans qu'il existe). En
        // pratique, le mode hors-ligne pouvait recevoir et relayer des messages, mais jamais en
        // envoyer soi-même depuis l'interface : fonctionnalité silencieusement incomplète, pas
        // seulement une maladresse d'ergonomie. Ajoute la table qui manquait ; voir
        // ui/mesh_screen.dart pour l'écran de contacts/envoi qui l'utilise désormais.
        if (oldV < 4) await _createContactsTable(db);
        // v4 -> v5 : colonne `own` (1 = message que NOUS avons écrit, 0 = enveloppe d'un tiers que
        // l'on relaie). Sert à plafonner la file de relais ([_maxRelayedEnvelopes]) sans jamais
        // évincer nos propres messages. Les lignes existantes sont marquées `own = 1` si
        // l'expéditeur inscrit dans l'enveloppe (octets 17..48 du payload sérialisé, voir
        // MeshEnvelope.serialize) est notre propre clé publique.
        if (oldV < 5) {
          await db.execute('ALTER TABLE outbox ADD COLUMN own INTEGER NOT NULL DEFAULT 0');
          try {
            final me = await identity();
            await db.rawUpdate(
                'UPDATE outbox SET own = 1 WHERE substr(payload, 17, 32) = ?', [me.publicKeyBytes]);
          } catch (_) {
            // Sans identité lisible, les anciennes lignes restent `own = 0` : au pire, elles
            // deviennent évinçables par le plafond de relais, jamais une panne de migration.
          }
        }
      },
    );
    if (resetGen != _resetGen) {
      // Un [reset] (effacement d'urgence) est passé pendant l'ouverture : cette base ne doit ni
      // être réutilisée ni survivre sur disque. On la referme et on la re-supprime (best-effort).
      // (Sauf si une ouverture POSTÉRIEURE au reset a déjà installé cette même instance.)
      if (!identical(_db, opened)) {
        try {
          await opened.close();
        } catch (_) {}
        if (_db == null) await _deleteDbFiles(dbPath);
      }
      throw StateError('mesh reset');
    }
    if (_db != null) {
      // Deux ouvertures concurrentes : on garde la première. sqflite renvoie par défaut la MÊME
      // instance pour un même chemin (singleInstance) : ne fermer que si c'en est une autre.
      final current = _db!;
      if (!identical(current, opened)) {
        try {
          await opened.close();
        } catch (_) {}
      }
      return current;
    }
    _db = opened;
    return opened;
  }

  static Future<void> _deleteDbFiles(String path) async {
    try {
      await sqlcipher.deleteDatabase(path);
    } catch (_) {}
    for (final suffix in ['-wal', '-shm', '-journal']) {
      try {
        await File('$path$suffix').delete();
      } catch (_) {}
    }
  }

  Future<void> _createContactsTable(sqlcipher.Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mesh_contacts (
        peer BLOB PRIMARY KEY,
        label TEXT NOT NULL,
        added_at INTEGER NOT NULL
      )
    ''');
  }

  /// Enregistre un contact Bluetooth (clé publique X25519 obtenue par QR ou texte, voir
  /// ui/qr_screens.dart) sous un nom choisi localement — jamais transmis à personne, purement un
  /// repère pour cet appareil. `insert` avec [ConflictAlgorithm.replace] permet de renommer un
  /// contact déjà connu en le « ré-ajoutant » avec un nouveau label, sans dupliquer la ligne.
  Future<void> addContact(Uint8List peerPublicKey, String label) async {
    final db = await _database();
    await db.insert(
      'mesh_contacts',
      {
        'peer': peerPublicKey,
        'label': label,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace,
    );
  }

  Future<void> removeContact(Uint8List peerPublicKey) async {
    final db = await _database();
    await db.delete('mesh_contacts', where: 'peer = ?', whereArgs: [peerPublicKey]);
  }

  Future<List<({Uint8List peer, String label})>> contacts() async {
    final db = await _database();
    final rows = await db.query('mesh_contacts', orderBy: 'added_at ASC');
    return rows
        .map((r) => (
              peer: Uint8List.fromList(r['peer'] as List<int>),
              label: r['label'] as String,
            ))
        .toList();
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
    final cached = _identity;
    if (cached != null) return cached;
    final resetGen = _resetGen;
    final loaded = await MeshIdentity.loadOrCreate((name) => Account.seed(name));
    // Effacement d'urgence passé pendant le chargement : ne pas réinstaller l'ancienne identité.
    if (resetGen != _resetGen) throw StateError('mesh reset');
    return _identity ??= loaded;
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
    // Trouvé en audit interne (revue croisée IA, confirmé en relisant ce fichier) : rien ici
    // n'attrapait d'exception. `FlutterBluePlus.startScan` lève notamment si le Bluetooth est
    // désactivé au moment de l'appel (pas seulement un refus de permission, déjà géré en amont
    // côté UI — voir mesh_screen.dart) — et `_running` avait déjà été mis à `true` juste au-dessus.
    // Conséquence concrète pour un testeur : Bluetooth coupé, bouton « activer » → exception non
    // rattrapée (bouton restant bloqué en chargement côté mesh_screen.dart), ET `_running` reste
    // bloqué à `true` pour toute la durée de vie de l'objet [Mesh] (singleton) — un nouvel appel à
    // [start] ressort immédiatement à la ligne au-dessus sans rien faire, y compris après que
    // l'utilisateur a réactivé le Bluetooth, jusqu'au redémarrage de l'appli. `stop()` dans le
    // catch réutilise le nettoyage déjà idempotent (cancel null-safe de chaque abonnement/timer)
    // pour ne pas laisser un démarrage partiel (ex. scan lancé mais rôle périphérique natif en
    // échec) à moitié actif.
    final gen = _gen;
    // Vrai si un stop()/reset() est intervenu depuis le début de CE démarrage.
    bool cancelled() => gen != _gen;
    try {
      await _database();
      if (cancelled()) return _abandonStart();
      await identity();
      if (cancelled()) return _abandonStart();
      final calcMode = await AppLock.calcMode();
      if (cancelled()) return _abandonStart();
      // Corrigé : plus de `timeout` (était 1 jour) — à l'échéance, flutter_blue_plus arrêtait le
      // scan EN SILENCE alors que `_running` restait vrai (interrupteur « activé », plus aucun
      // relais). Sans timeout, le scan tourne jusqu'à [stop] (ou coupure de l'adaptateur, gérée
      // plus bas). Vérifié dans flutter_blue_plus 1.36.x : `Duration? timeout`, null = illimité.
      await FlutterBluePlus.startScan(
        withServices: [serviceUuid],
        continuousUpdates: true,
      );
      if (cancelled()) return _abandonStart();
      // Corrigé : le service de premier plan (notification persistante) n'est lancé qu'APRÈS le
      // succès de startScan — avant, il démarrait d'abord, et un échec du scan laissait
      // brièvement une notification pour un mode qui n'a jamais tourné.
      unawaited(MeshForegroundService.start(calcMode: calcMode));
      _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
      // Trouvé en audit interne (revue croisée IA, vérifiée contre ce code) : ce timer ne fait QUE
      // purger (_purgeExpired ne touche que des lignes expirées depuis au moins maxAgeHours = 72 h),
      // mais tournait toutes les 20 secondes — un réveil CPU/I/O SQLite totalement disproportionné
      // par rapport à la granularité réellement utile, sur un usage où l'autonomie de la batterie
      // compte (téléphone en poche en manifestation). 15 minutes laisse largement le temps de purger
      // avant que quoi que ce soit ne dépende de cette fraîcheur (fenêtre de 72 h).
      _relayTimer = Timer.periodic(const Duration(minutes: 15), (_) => _purgeExpired());

      // Rôle périphérique natif : s'annonce et répond aux lectures/écritures d'autres téléphones.
      // Échoue silencieusement sur les plateformes sans ce canal (iOS, desktop) ou si le Bluetooth
      // est indisponible — le mode reste alors limité au rôle central, comme avant cette extension.
      final peripheral = await MeshGattServerBridge.start();
      if (cancelled()) return _abandonStart();
      _peripheralActive = peripheral;
      _gattSub = MeshGattServerBridge.incoming().listen(_onGattWrite);
      _rotateTimer = Timer.periodic(const Duration(seconds: 15), (_) => _rotateReadValue());
      unawaited(_rotateReadValue());

      // Trouvé en audit interne : rien ici ne surveillait l'état de l'adaptateur Bluetooth une
      // fois le scan démarré — seul un Bluetooth déjà éteint AU MOMENT de cet appel était détecté
      // (voir le `catch` plus bas). Scénario réel pour l'usage visé par ce fichier, pas
      // hypothétique : activer le mode avion coupe le Bluetooth sur la plupart des
      // appareils/versions d'Android (sauf réglage explicite contraire, non garanti), y compris
      // pendant que ce mode était déjà actif. Sans ce qui suit, `_running` restait bloqué à `true`
      // et `MeshScreen._active` continuait d'afficher l'interrupteur sur « activé » alors que le
      // scan et l'annonce étaient déjà morts côté système — aucun message, aucun relais, sans que
      // rien ne le signale. Dangereux précisément dans le scénario visé (manifestation) : croire
      // le mode hors-ligne actif alors qu'il ne l'est plus. On s'arrête maintenant proprement dès
      // que l'adaptateur quitte l'état `on`, et on le signale distinctement d'un arrêt volontaire
      // (voir [MeshEvent.adapterOff], géré par `ui/mesh_screen.dart` pour remettre l'interrupteur
      // à l'état réel). LIMITE HONNÊTE : la fiabilité et le délai réels de ce flux
      // (`FlutterBluePlus.adapterState`) face à un vrai basculement du mode avion n'ont pas été
      // vérifiés sur un appareil physique, faute de matériel dans ce bac à sable — seule la
      // disparition totale de toute détection, le défaut d'avant ce correctif, est certaine.
      _adapterSub = FlutterBluePlus.adapterState.listen((state) {
        if (_running && gen == _gen && state != BluetoothAdapterState.on) {
          _eventsController.add(const MeshEvent.adapterOff());
          // Trouvé en audit interne (revue indépendante) : `stop()` émet toujours
          // `MeshEvent.stopped()` à la fin, quelle que soit la raison de l'arrêt. Sans le
          // paramètre ci-dessous, ce chemin ajoutait DEUX lignes au journal pour un seul
          // événement réel (« Bluetooth désactivé... » suivie immédiatement de la générique
          // « Écoute Bluetooth arrêtée », côté ui/mesh_screen.dart) — `MeshEvent.adapterOff()`
          // explique déjà entièrement l'arrêt, la seconde ligne n'ajoutait aucune information.
          unawaited(stop(emitStoppedEvent: false));
        }
      });

      // Trouvé en audit interne : seule la coupure de l'ADAPTATEUR Bluetooth était surveillée
      // une fois le relais démarré (voir [_adapterSub] ci-dessus) — pas la révocation d'une
      // PERMISSION Bluetooth, possible à tout moment depuis Réglages (Android peut même la
      // retirer de lui-même sur une appli inutilisée en arrière-plan, API 30+) sans jamais
      // couper l'adaptateur lui-même. Dans ce cas, `FlutterBluePlus.startScan`/`connect` et le
      // rôle périphérique natif échouent silencieusement à chaque tentative (avalés par les
      // `catch (_)` de [_tryExchange] et consorts, indiscernables d'un simple appareil hors de
      // portée) : `_running` restait bloqué à `true` et l'interrupteur de `ui/mesh_screen.dart`
      // continuait d'afficher « activé » alors que le relais ne fonctionne plus du tout — même
      // danger OPSEC que celui déjà corrigé pour [MeshEvent.adapterOff] (croire le mode
      // hors-ligne actif en manifestation alors qu'il ne l'est plus). `permission_handler`
      // n'offrant pas de flux à écouter (seulement une lecture ponctuelle de l'état), on sonde
      // toutes les 30 s plutôt qu'en continu — assez réactif pour cet usage sans réveil excessif.
      _permissionTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_checkPermissions(gen)),
      );

      _eventsController.add(const MeshEvent.started());
    } catch (_) {
      // Démarrage déjà annulé par un stop()/reset() concurrent : celui-ci a tout nettoyé et
      // signalé l'arrêt ; ne pas relancer un second stop() (qui émettrait un 2e événement).
      if (cancelled()) return _abandonStart();
      await stop();
      rethrow;
    }
  }

  /// Un [stop]/[reset] est intervenu pendant un `await` de [start] : ce [stop] a déjà annulé ce
  /// qui existait à ce moment-là, mais [start] a pu lancer quelque chose APRÈS (scan BLE, serveur
  /// GATT natif, service de premier plan). On défait ici, sans toucher à `_running` ni aux
  /// abonnements/timers d'un éventuel démarrage plus récent (génération différente), et sans émettre
  /// d'événement (le [stop] concurrent l'a déjà fait). Si un démarrage plus récent tourne déjà
  /// (`_running`), on ne coupe rien : ses propres ressources natives sont les mêmes (singletons).
  Future<void> _abandonStart() async {
    if (_running) return;
    try {
      await MeshGattServerBridge.stop();
    } catch (_) {}
    try {
      await MeshForegroundService.stop();
    } catch (_) {}
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// [emitStoppedEvent] : `false` uniquement quand l'appelant a déjà notifié l'UI d'une raison
  /// d'arrêt plus précise (voir l'appel depuis le listener `adapterState` ci-dessus) — pour éviter
  /// que l'UI reçoive deux événements pour un seul arrêt réel. Tous les autres appelants (arrêt
  /// volontaire via l'interrupteur, effacement d'urgence via [reset]) gardent la valeur par défaut
  /// `true`, qui préserve le comportement existant.
  Future<void> stop({bool emitStoppedEvent = true}) async {
    _gen++; // invalide tout start() en cours (voir [_gen])
    _running = false;
    _peripheralActive = false;
    await _scanSub?.cancel();
    _scanSub = null;
    _relayTimer?.cancel();
    _relayTimer = null;
    await _gattSub?.cancel();
    _gattSub = null;
    await _adapterSub?.cancel();
    _adapterSub = null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _permissionTimer?.cancel();
    _permissionTimer = null;
    _inFlightExchanges.clear();
    _lastExchangeAt.clear();
    await MeshGattServerBridge.stop();
    await MeshForegroundService.stop();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (emitStoppedEvent) _eventsController.add(const MeshEvent.stopped());
  }

  /// Un autre téléphone vient d'écrire une enveloppe sur notre caractéristique (rôle
  /// périphérique) : on la traite exactement comme une enveloppe récupérée en scannant (rôle
  /// central) — même déduplication, même logique de déchiffrement ou de relais.
  Future<void> _onGattWrite(Uint8List bytes) async {
    final rg = _resetGen;
    if (_stale(rg)) return;
    final env = MeshEnvelope.deserialize(bytes);
    if (env == null || _stale(rg)) return;
    try {
      await _handleIncoming(env);
    } catch (_) {
      // Effacement d'urgence en cours (StateError « mesh reset ») ou base fermée : on abandonne.
    }
  }

  /// Vrai si le relais est arrêté ou si un effacement d'urgence a eu lieu depuis la capture de
  /// [rg] (valeur de [_resetGen]) : l'appelant doit alors sortir sans toucher à la base.
  bool _stale(int rg) => !_running || rg != _resetGen;

  /// Sonde périodique lancée par [start] (voir [_permissionTimer]) : vérifie qu'aucune des
  /// permissions Bluetooth déjà accordées au moment du démarrage n'a été révoquée depuis. Même
  /// garantie que [MeshEvent.adapterOff] mais pour une cause différente — voir le commentaire au
  /// point d'appel. [rg] est la génération ([_gen]) capturée par [start] : un `stop`/`reset`
  /// survenu depuis rend cette vérification obsolète, à ignorer silencieusement (son propre
  /// `stop` a déjà tout nettoyé).
  Future<void> _checkPermissions(int rg) async {
    if (!_running || rg != _gen) return;
    bool lost;
    try {
      final statuses = await Future.wait([
        Permission.bluetoothScan.status,
        Permission.bluetoothConnect.status,
        Permission.bluetoothAdvertise.status,
      ]);
      lost = statuses.any((s) => !s.isGranted && !s.isLimited);
    } catch (_) {
      // Lecture du statut elle-même en échec (plateforme sans ce canal) : on ne peut rien
      // conclure, on ne coupe pas le relais sur une incertitude.
      return;
    }
    if (lost && _running && rg == _gen) {
      _eventsController.add(const MeshEvent.permissionLost());
      unawaited(stop(emitStoppedEvent: false));
    }
  }

  /// Fait tourner la valeur que le serveur GATT natif renvoie à la prochaine lecture, parmi notre
  /// file d'attente (voir la limite documentée en tête de fichier).
  Future<void> _rotateReadValue() async {
    final rg = _resetGen;
    if (_stale(rg)) return;
    final List<MeshEnvelope> queue;
    try {
      queue = await _allOutbox();
    } catch (_) {
      return;
    }
    if (_stale(rg)) return;
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
    final rg = _resetGen;
    try {
      if (_stale(rg)) return;
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
      if (_stale(rg)) return;
      final queue = await _allOutbox();
      for (final env in queue) {
        if (_stale(rg)) return;
        final bytes = env.serialize();
        if (bytes.length > 512) continue; // au-delà du MTU négocié ci-dessus, on laisse de côté
        try {
          // allowLongWrite (vérifié dans flutter_blue_plus 1.36.x, `write(..., allowLongWrite:)`) :
          // si la négociation MTU a échoué, l'enveloppe part en « Write Long » (Prepare/Execute
          // Write), que MeshGattServer.kt réassemble, au lieu d'échouer sur une écriture simple.
          await char.write(bytes, withoutResponse: false, allowLongWrite: true);
        } catch (_) {
          continue;
        }
      }

      // Et on lit ce que l'autre appareil a en attente pour nous (notification ou lecture directe
      // selon ce que la caractéristique autorise — dépend du serveur GATT distant, voir la limite
      // documentée en tête de fichier : ceci suppose un pair qui implémente déjà le serveur).
      if (char.properties.read) {
        final incoming = await char.read();
        if (_stale(rg)) return;
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

  /// Nombre maximal d'enveloppes de TIERS conservées pour relais (`outbox.own = 0`). Corrigé
  /// (inondation) : la file de relais n'avait aucune borne — n'importe quel appareil à portée
  /// pouvait la remplir sans limite (disque, temps de rotation GATT, batterie). Nos propres
  /// messages (`own = 1`) ne sont jamais évincés par ce plafond.
  static const _maxRelayedEnvelopes = 300;

  Future<void> _handleIncomingLocked(MeshEnvelope env) async {
    // Corrigé (inondation) : rejet AVANT toute écriture des enveloppes datées dans le futur
    // (au-delà de la tolérance d'horloge), au ttl supérieur au maximum ou déjà expirées — voir
    // [meshValidateIncoming]. Sans ce filtre, un horodatage lointain dans le futur rendait une
    // enveloppe indéfiniment « fraîche » (jamais purgée) et un ttl de 255 la propageait 255 sauts.
    if (!_running) return;
    if (meshValidateIncoming(env) != null) return;

    final rg = _resetGen;
    final db = await _database();
    if (_stale(rg)) return;
    final me = await identity();
    final forMe = _bytesEqual(env.recipientHint, await meshRecipientHint(me.publicKeyBytes));
    // Clé de déduplication : id seul pour un message qui NOUS est destiné (écrit seulement après
    // déchiffrement authentifié), SHA-256(id ‖ recipientHint) pour une enveloppe à relayer — voir
    // [meshSeenKey] : une copie forgée au hint modifié ne bloque plus le vrai message chez les
    // relais. Pas de migration : `seen.id` (comme `outbox.id`) est un BLOB PRIMARY KEY sans
    // contrainte de longueur ; les anciennes lignes (id seul, 16 octets) expirent d'elles-mêmes
    // par [_purgeExpired] et ne peuvent pas entrer en collision avec les nouvelles (32 octets).
    final seenKey = await meshSeenKey(id: env.id, recipientHint: env.recipientHint, forMe: forMe);
    if (_stale(rg)) return;
    final already = await db.query('seen', where: 'id = ?', whereArgs: [seenKey], limit: 1);
    if (already.isNotEmpty) return;

    if (forMe) {
      // Corrigé (usurpation) : on ne déchiffre/affiche que les messages d'expéditeurs présents
      // dans `mesh_contacts`. La clé publique de l'expéditeur voyage en clair : sans ce filtre,
      // n'importe qui pouvait ouvrir un canal avec nous sous une identité jamais validée par QR.
      if (await _isContact(db, env.senderPublicKey)) {
        // Corrigé (CRITIQUE) : la clé est d'abord seulement CALCULÉE (plan, aucune écriture), le
        // déchiffrement AES-GCM l'authentifie, et ce n'est qu'en cas de succès que l'état du
        // cliquet est modifié (transaction), puis l'id marqué `seen`. Avant, le cliquet avançait
        // (et `seen` était écrit) avant toute authentification : une seule fausse écriture GATT
        // avec un compteur élevé détruisait le canal de réception de ce contact.
        final plan = await _planRecvKey(env.senderPublicKey, env.chainCounter);
        final plain =
            plan == null ? null : await meshDecryptWithKey(messageKey: plan.messageKey, envelope: env);
        if (plan != null && plain != null) {
          if (_stale(rg)) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          final committed = await db.transaction((txn) async {
            if (!await _commitRecvPlan(txn, env.senderPublicKey, env.chainCounter, plan)) {
              return false;
            }
            await txn.insert('seen', {'id': seenKey, 'seen_at': now},
                conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore);
            await _capSeen(txn);
            await txn.insert(
              'inbox',
              {'id': env.id, 'sender': env.senderPublicKey, 'plaintext': plain, 'received_at': now},
              conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
            );
            return true;
          });
          if (committed) {
            _eventsController.add(MeshEvent.messageReceived(env.senderPublicKey, plain));
          }
          return;
        }
      }
      // Pour nous mais non authentifié (falsifié, corrompu) ou d'un expéditeur inconnu : surtout
      // PAS marqué `seen` — sinon une copie forgée portant l'id d'un vrai message bloquerait ce
      // dernier à son arrivée. Relayé comme n'importe quelle enveloppe (un relais qui s'abstient
      // révélerait à un observateur que l'enveloppe nous était destinée), sous la clé de relais.
      final relayKey =
          await meshSeenKey(id: env.id, recipientHint: env.recipientHint, forMe: false);
      if (_stale(rg)) return;
      await db.transaction((txn) => _storeForRelay(txn, env, relayKey));
      return;
    }

    // Pas pour nous. Une copie dont le ttl est déjà épuisé ne sera de toute façon pas relayée :
    // on ne la marque PAS `seen`, pour qu'une copie forgée à ttl 1 (le ttl n'est pas authentifié,
    // voir meshValidateIncoming) ne bloque pas la vraie enveloppe à ttl plus élevé.
    // LIMITE RESTANTE : une copie forgée au même id ET au même hint mais à ttl réduit (≥ 2) est
    // encore acceptée en premier et raccourcit la portée de l'original chez ce relais.
    if (env.relayed().expired) return;
    if (_stale(rg)) return;
    await db.transaction((txn) async {
      await txn.insert('seen', {'id': seenKey, 'seen_at': DateTime.now().millisecondsSinceEpoch},
          conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore);
      await _capSeen(txn);
      // On le garde dans notre propre file pour le repasser au prochain appareil.
      await _storeForRelay(txn, env, seenKey);
    });
  }

  /// Plafond de la table `seen` (anti-inondation : sinon bornée seulement par l'âge, 72 h).
  static const _maxSeen = 20000;

  Future<void> _capSeen(sqlcipher.DatabaseExecutor db) => db.execute(
      'DELETE FROM seen WHERE rowid NOT IN (SELECT rowid FROM seen ORDER BY rowid DESC LIMIT $_maxSeen)');

  Future<bool> _isContact(sqlcipher.DatabaseExecutor db, Uint8List peer) async {
    final rows = await db.query('mesh_contacts',
        columns: ['peer'], where: 'peer = ?', whereArgs: [peer], limit: 1);
    return rows.isNotEmpty;
  }

  /// Met une enveloppe de tiers en file de relais (`own = 0`), puis applique le plafond
  /// [_maxRelayedEnvelopes] en évinçant les plus anciennes par ordre d'INSERTION (rowid), jamais
  /// par `created_at`, que l'expéditeur choisit librement.
  ///
  /// [relayKey] = [meshSeenKey] (forMe: false) : sert de clé primaire `outbox.id` pour les
  /// enveloppes de tiers (au lieu de l'id seul), sinon une copie forgée au hint modifié, insérée
  /// la première, occuperait la ligne et le vrai message serait ignoré (`ConflictAlgorithm.ignore`)
  /// à son tour. Nos propres messages (`own = 1`) gardent leur id de 16 octets : pas de collision.
  Future<void> _storeForRelay(sqlcipher.DatabaseExecutor db, MeshEnvelope env, Uint8List relayKey) async {
    final relayed = env.relayed();
    if (relayed.expired) return;
    await db.insert(
      'outbox',
      {
        'id': relayKey,
        'recipient': env.recipientHint,
        'payload': relayed.serialize(),
        'created_at': env.createdAt.millisecondsSinceEpoch,
        'own': 0,
      },
      conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
    );
    await db.delete(
      'outbox',
      where: 'own = 0 AND rowid NOT IN '
          '(SELECT rowid FROM outbox WHERE own = 0 ORDER BY rowid DESC LIMIT ?)',
      whereArgs: [_maxRelayedEnvelopes],
    );
  }

  /// Met un message en file pour un contact, à relayer dès qu'un appareil Murmure est croisé.
  ///
  /// Lève [MeshMessageTooLongException] si [text] ne tient pas dans une seule enveloppe mesh (voir
  /// [meshMaxPlaintextBytes]) — vérifié ICI, avant d'entrer dans la section sérialisée qui avance
  /// le cliquet d'envoi, pour ne jamais consommer un rang de cliquet pour un message qui ne pourra
  /// de toute façon jamais être relayé (voir le commentaire de [meshMaxPlaintextBytes]).
  Future<void> queueMessage({required Uint8List recipientPublicKey, required String text}) {
    final bytes = utf8.encode(text).length;
    if (bytes > meshMaxPlaintextBytes) {
      throw MeshMessageTooLongException(meshMaxPlaintextBytes, bytes);
    }
    return _serialized(() => _queueMessageLocked(recipientPublicKey: recipientPublicKey, text: text));
  }

  Future<void> _queueMessageLocked({required Uint8List recipientPublicKey, required String text}) async {
    final me = await identity();
    final hint = await meshRecipientHint(recipientPublicKey);
    final db = await _database();
    // Atomique : amorçage éventuel + avance du cliquet d'envoi + insertion en file. Si l'insertion
    // échoue, le cliquet n'avance pas (pas de rang consommé pour un message jamais mis en file).
    // Uniquement `txn` dans la transaction (jamais `db`, sinon interblocage sqflite).
    await db.transaction((txn) async {
      final next = await _nextSendKey(txn, recipientPublicKey);
      final env = await meshEncryptWithKey(
        messageKey: next.messageKey,
        chainCounter: next.counter,
        senderPublicKey: me.publicKeyBytes,
        recipientHint: hint,
        plaintext: text,
      );
      await txn.insert('outbox', {
        'id': env.id,
        'recipient': env.recipientHint,
        'payload': env.serialize(),
        'created_at': env.createdAt.millisecondsSinceEpoch,
        'own': 1,
      });
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
  ///
  /// LIMITE CONNUE (documentée, non corrigée) : si plus de 200 messages consécutifs d'un contact
  /// ne nous parviennent jamais (perdus, expirés, évincés des files de relais), tout message
  /// suivant est hors fenêtre et indéchiffrable : le canal de réception depuis ce contact reste
  /// bloqué. Une « réinitialisation du canal » par simple suppression locale de `ratchet_chain` /
  /// `ratchet_skipped` n'est PAS sûre : [_ensureRatchetSeeded] ré-amorcerait les deux chaînes depuis
  /// le même secret ECDH statique (un nouvel échange QR redonne les mêmes clés publiques), donc les
  /// mêmes clés de message dès le rang 0 — rejeu des anciennes enveloppes encore en circulation
  /// (la table `seen` n'en garde que 72 h) et réutilisation de clés AES-GCM. Une vraie
  /// réinitialisation demande un nouvel aléa partagé (époque de cliquet), donc un changement de
  /// protocole — hors périmètre. Voir aussi le commentaire de `_composeAndSend` (mesh_screen.dart).
  static const _maxRatchetSkipAhead = 200;

  /// Nombre de clés de rangs sautés conservées par contact, pour tolérer les messages qui
  /// arrivent dans le désordre (relais par plusieurs chemins Bluetooth) sans garder une réserve
  /// illimitée.
  static const _maxSkippedPerPeer = 50;

  /// Amorce les deux chaînes (envoi/réception) avec [peerPublicKey] depuis le secret ECDH, SI ce
  /// n'est pas déjà fait — idempotent, ignore silencieusement si l'état existe déjà.
  Future<void> _ensureRatchetSeeded(sqlcipher.DatabaseExecutor db, Uint8List peerPublicKey) async {
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
  Future<({Uint8List messageKey, int counter})> _nextSendKey(
      sqlcipher.DatabaseExecutor db, Uint8List peerPublicKey) async {
    await _ensureRatchetSeeded(db, peerPublicKey);
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

  /// Calcule, SANS RIEN ÉCRIRE en base, la clé de message pour le rang [counter] de
  /// [peerPublicKey] : soit une clé déjà en réserve (`ratchet_skipped`, message arrivé après un
  /// plus récent), soit l'avancée de la chaîne de réception jusqu'à ce rang (calculée en mémoire
  /// par [meshPlanRecvAdvance]). Retourne null si la clé n'est plus disponible : rang déjà
  /// consommé et oublié (confidentialité persistante, comportement attendu) ou saut supérieur à
  /// [_maxRatchetSkipAhead]. Le plan n'est appliqué que par [_commitRecvPlan], et seulement
  /// après un déchiffrement AES-GCM réussi avec [_RecvKeyPlan.messageKey].
  Future<_RecvKeyPlan?> _planRecvKey(Uint8List peerPublicKey, int counter) async {
    final db = await _database();

    final skipped = await db.query('ratchet_skipped',
        where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter], limit: 1);
    if (skipped.isNotEmpty) {
      return _RecvKeyPlan.fromSkipped(Uint8List.fromList(skipped.first['message_key'] as List<int>));
    }

    final rows = await db.query('ratchet_chain',
        where: 'peer = ? AND direction = ?', whereArgs: [peerPublicKey, 'recv'], limit: 1);
    Uint8List chainKey;
    int next;
    ({Uint8List send, Uint8List recv})? seed;
    if (rows.isEmpty) {
      // Cliquet jamais amorcé avec ce contact : amorçage calculé en mémoire, écrit seulement au
      // commit (voir [_commitRecvPlan]).
      final me = await identity();
      final (chainA, chainB) = await meshRatchetRoots(await me.sharedSecretWith(peerPublicKey));
      final iSendOnA = meshSendsOnChainA(me.publicKeyBytes, peerPublicKey);
      seed = (send: iSendOnA ? chainA : chainB, recv: iSendOnA ? chainB : chainA);
      chainKey = seed.recv;
      next = 0;
    } else {
      chainKey = Uint8List.fromList(rows.first['chain_key'] as List<int>);
      next = rows.first['counter'] as int;
    }

    final advance = await meshPlanRecvAdvance(
      chainKey: chainKey,
      nextCounter: next,
      targetCounter: counter,
      maxSkipAhead: _maxRatchetSkipAhead,
    );
    if (advance == null) return null;
    return _RecvKeyPlan.ratchet(advance, expectedNext: next, seed: seed);
  }

  /// Applique atomiquement (dans [txn]) un plan validé par un déchiffrement réussi : retrait de
  /// la clé de réserve consommée, OU amorçage éventuel + mise en réserve des rangs sautés +
  /// avancée du cliquet + élagage. Vérifie que l'état n'a pas bougé depuis le plan (compteur
  /// attendu, clé de réserve toujours présente) ; sinon ne fait rien et renvoie false.
  Future<bool> _commitRecvPlan(
      sqlcipher.Transaction txn, Uint8List peerPublicKey, int counter, _RecvKeyPlan plan) async {
    final advance = plan.advance;
    if (advance == null) {
      final n = await txn.delete('ratchet_skipped',
          where: 'peer = ? AND counter = ?', whereArgs: [peerPublicKey, counter]);
      return n == 1;
    }
    final seed = plan.seed;
    if (seed != null) {
      await txn.insert(
        'ratchet_chain',
        {'peer': peerPublicKey, 'direction': 'send', 'chain_key': seed.send, 'counter': 0},
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
      );
      await txn.insert(
        'ratchet_chain',
        {'peer': peerPublicKey, 'direction': 'recv', 'chain_key': seed.recv, 'counter': 0},
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
      );
    }
    final updated = await txn.update(
      'ratchet_chain',
      {'chain_key': advance.newChainKey, 'counter': advance.newNextCounter},
      where: 'peer = ? AND direction = ? AND counter = ?',
      whereArgs: [peerPublicKey, 'recv', plan.expectedNext],
    );
    if (updated != 1) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final (skippedCounter, key) in advance.skippedKeys) {
      await txn.insert(
        'ratchet_skipped',
        {'peer': peerPublicKey, 'counter': skippedCounter, 'message_key': key, 'created_at': now},
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace,
      );
    }
    await _trimSkipped(txn, peerPublicKey);
    return true;
  }

  /// Ne garde que les [_maxSkippedPerPeer] rangs sautés les plus récents par contact (les plus
  /// anciens ont le moins de chances d'être un jour réclamés par un message très en retard). Une
  /// seule requête DELETE, exécutée dans la transaction de [_commitRecvPlan].
  Future<void> _trimSkipped(sqlcipher.DatabaseExecutor db, Uint8List peerPublicKey) async {
    await db.delete(
      'ratchet_skipped',
      where: 'peer = ? AND counter NOT IN '
          '(SELECT counter FROM ratchet_skipped WHERE peer = ? ORDER BY counter DESC LIMIT ?)',
      whereArgs: [peerPublicKey, peerPublicKey, _maxSkippedPerPeer],
    );
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

  /// Efface le texte en clair des messages Bluetooth déjà reçus (table `inbox`), à la demande
  /// explicite de l'utilisateur — voir le bouton correspondant dans `ui/mesh_screen.dart`.
  ///
  /// Trouvé en audit interne (pas une proposition externe) : [_purgeExpired] purge par âge
  /// `outbox` (file d'attente de relais), `seen` (cache de déduplication) et `ratchet_skipped`
  /// (clés de rangs sautés, voir le commentaire de migration v2 -> v3 plus haut) — les trois
  /// autres tables de cette base. `inbox` en était la seule exception silencieuse : une fois un
  /// message déchiffré et affiché, son texte en clair restait en base SQLCipher SANS AUCUNE limite
  /// d'âge ni moyen de l'effacer autrement qu'en essuyant tout le compte (`Account.wipeLocal`,
  /// panique ou suppression de compte). Pour un canal pensé pour les coupures réseau en
  /// manifestation, c'est précisément le type de trace qu'un appareil saisi peut exposer après coup
  /// (le texte des messages déjà lus, potentiellement accumulés sur plusieurs sessions) — pas un
  /// secret de chiffrement (la clé SQLCipher reste nécessaire pour le lire), mais une donnée que
  /// l'utilisateur devrait pouvoir faire disparaître de ce téléphone sans tout réinitialiser.
  ///
  /// Délibérément PAS de purge automatique par âge ici, à la différence des trois autres tables :
  /// contrairement à une file de relais ou un cache technique, l'inbox est un contenu que
  /// l'utilisateur lit et consulte (voir le « Journal » de `MeshScreen`) — décider à sa place d'une
  /// fenêtre après laquelle ses messages disparaissent serait une perte de données silencieuse et
  /// surprenante, pas une amélioration d'OPSEC qu'il aurait demandée. Cette méthode lui laisse le
  /// choix explicite, au moment qu'il choisit.
  Future<void> clearInbox() async {
    final db = await _database();
    await db.delete('inbox');
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
    m._resetGen++; // voir [_database]/[identity] : une ouverture en vol ne réinstalle rien
    await m.stop(); // incrémente aussi [_gen] : un start() en cours s'arrête au prochain await
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
    // Trouvé en audit interne (pas une proposition externe) : cette méthode reproduisait le même
    // défaut déjà corrigé ailleurs dans ce dépôt pour les deux autres bases SQLCipher (voir
    // `Account.wipeLocal` et `CallOpsecStore.wipe`) — les fragments `-wal`/`-shm`/`-journal` ne
    // sont pas nettoyés par `deleteDatabase` quand le fichier principal a déjà disparu. Aujourd'hui
    // sans conséquence pratique : le seul appelant de [reset], `Account.wipeLocal`, nettoie déjà
    // ces fragments pour `kMeshDbName` dans sa propre boucle, juste après cet appel. Mais [reset]
    // se présente comme une remise à zéro complète et autonome de la base maillée (identité,
    // cliquets, messages) — tout futur appel direct (ex. un bouton « réinitialiser le mode
    // maillé » sans passer par un essuyage complet du compte) hériterait silencieusement du même
    // défaut que ces deux autres correctifs visaient justement à éliminer. Corrigé ici aussi, pour
    // que cette garantie ne dépende pas de l'ordre des appels dans `wipeLocal`.
    for (final suffix in ['-wal', '-shm', '-journal']) {
      try {
        await File('$path$suffix').delete();
      } catch (_) {}
    }
  }
}

/// Événements du mode maillé, pour l'UI (ui/mesh_screen.dart).
sealed class MeshEvent {
  const MeshEvent();
  const factory MeshEvent.started() = MeshStarted;
  const factory MeshEvent.stopped() = MeshStopped;
  const factory MeshEvent.adapterOff() = MeshAdapterOff;
  const factory MeshEvent.permissionLost() = MeshPermissionLost;
  const factory MeshEvent.messageReceived(List<int> sender, String text) = MeshMessageReceived;
}

class MeshStarted extends MeshEvent {
  const MeshStarted();
}

class MeshStopped extends MeshEvent {
  const MeshStopped();
}

/// Arrêt provoqué par l'adaptateur Bluetooth lui-même quittant l'état `on` (mode avion, extinction
/// manuelle, coupure système) PENDANT que le mode hors-ligne tournait — distinct de [MeshStopped],
/// qui couvre aussi l'arrêt volontaire par l'interrupteur de `MeshScreen`. Voir le commentaire dans
/// [Mesh.start] : sans cette distinction, l'interface ne pouvait pas dire à l'utilisateur ce qui
/// vient de se passer.
class MeshAdapterOff extends MeshEvent {
  const MeshAdapterOff();
}

/// Arrêt provoqué par la révocation d'une permission Bluetooth (BLUETOOTH_SCAN/CONNECT/ADVERTISE)
/// PENDANT que le mode hors-ligne tournait — voir [Mesh._checkPermissions]. Distinct de
/// [MeshAdapterOff] : ici l'adaptateur reste allumé, seule l'autorisation d'y accéder a disparu.
class MeshPermissionLost extends MeshEvent {
  const MeshPermissionLost();
}

class MeshMessageReceived extends MeshEvent {
  const MeshMessageReceived(this.sender, this.text);
  final List<int> sender;
  final String text;
}

extension FirstOrNullExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Clé de réception calculée sans effet de bord (voir `Mesh._planRecvKey`) : soit une clé de
/// réserve existante, soit une avancée de chaîne à appliquer seulement après déchiffrement réussi.
class _RecvKeyPlan {
  _RecvKeyPlan.fromSkipped(this.messageKey)
      : advance = null,
        expectedNext = -1,
        seed = null;
  _RecvKeyPlan.ratchet(MeshRecvPlan this.advance, {required this.expectedNext, this.seed})
      : messageKey = advance.messageKey;

  final Uint8List messageKey;
  final MeshRecvPlan? advance;
  final int expectedNext;
  final ({Uint8List send, Uint8List recv})? seed;
}
