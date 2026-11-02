import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../account.dart';
import 'mesh_crypto.dart';

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
/// LIMITE HONNÊTE À CONNAÎTRE AVANT MISE EN PRODUCTION : le paquet `flutter_blue_plus` (comme la
/// quasi-totalité des bibliothèques BLE Flutter) ne pilote que le rôle "central" — scanner et se
/// connecter à d'autres appareils. Il ne permet pas de faire fonctionner CE téléphone comme
/// périphérique BLE annonçant un service GATT (rôle "peripheral"), ce qui est pourtant
/// indispensable pour qu'un autre téléphone Murmure puisse le découvrir en retour. Pour un
/// maillage vraiment bidirectionnel (deux téléphones qui se découvrent mutuellement, et pas
/// seulement le scanner qui trouve des publicités), il faut un serveur GATT côté Android, qui
/// n'existe pas encore dans ce dépôt (il faudrait implémenter `BluetoothGattServer` en Kotlin,
/// exposé par un MethodChannel, sur le modèle de l'alias calculatrice déjà en place dans
/// MainActivity.kt). Tant que ce serveur GATT natif n'est pas écrit, le mode Bluetooth fonctionne
/// uniquement en scan + connexion sortante : utile pour relayer vers un appareil déjà repéré, mais
/// incomplet pour un maillage symétrique. Ce fichier est écrit pour que cette pièce manquante
/// s'intègre proprement une fois prête (voir [MeshServer], volontairement séparé).
class Mesh {
  Mesh._();
  static Mesh? _instance;
  static Mesh get instance => _instance ??= Mesh._();

  /// UUID de service Murmure : identifie un appareil qui fait tourner le mode maillé, sans rien
  /// révéler d'autre (pas d'identifiant utilisateur dans l'annonce BLE elle-même).
  static final serviceUuid = Guid('5a4d5552-4d55-5245-0000-000000000001');
  static final inboxCharUuid = Guid('5a4d5552-4d55-5245-0000-000000000002');

  sqlcipher.Database? _db;
  MeshIdentity? _identity;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _relayTimer;
  bool _running = false;

  final _eventsController = StreamController<MeshEvent>.broadcast();
  Stream<MeshEvent> get events => _eventsController.stream;

  Future<sqlcipher.Database> _database() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, Account.kMeshDbName);
    _db = await sqlcipher.openDatabase(
      dbPath,
      password: await Account.dbKey(),
      version: 1,
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
      },
    );
    return _db!;
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
    _eventsController.add(const MeshEvent.started());
  }

  Future<void> stop() async {
    _running = false;
    await _scanSub?.cancel();
    _scanSub = null;
    _relayTimer?.cancel();
    _relayTimer = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _eventsController.add(const MeshEvent.stopped());
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

  Future<void> _handleIncoming(MeshEnvelope env) async {
    final db = await _database();
    final already = await db.query('seen', where: 'id = ?', whereArgs: [env.id], limit: 1);
    if (already.isNotEmpty) return;
    await db.insert('seen', {'id': env.id, 'seen_at': DateTime.now().millisecondsSinceEpoch});

    final me = await identity();
    if (_bytesEqual(env.recipientPublicKey, me.publicKeyBytes)) {
      final plain = await meshDecrypt(identity: me, envelope: env);
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
          'recipient': env.recipientPublicKey,
          'payload': env.relayed().serialize(),
          'created_at': env.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.ignore,
      );
    }
  }

  /// Met un message en file pour un contact, à relayer dès qu'un appareil Murmure est croisé.
  Future<void> queueMessage({required Uint8List recipientPublicKey, required String text}) async {
    final me = await identity();
    final env = await meshEncrypt(identity: me, recipientPublicKey: recipientPublicKey, plaintext: text);
    final db = await _database();
    await db.insert('outbox', {
      'id': env.id,
      'recipient': env.recipientPublicKey,
      'payload': env.serialize(),
      'created_at': env.createdAt.millisecondsSinceEpoch,
    });
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
