import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import '../../account.dart';

/// Un appel manqué (entrant, jamais décroché, raccroché par le correspondant ou expiré) — voir
/// `CallSessionScreen` pour la détection.
class MissedCall {
  const MissedCall({required this.roomId, required this.remoteUserId, required this.timestamp});
  final String roomId;
  final String? remoteUserId;
  final int timestamp;
}

/// Historique des appels manqués, cloisonné dans sa propre base SQLCipher (chiffrée au repos,
/// même clé aléatoire que les autres bases locales — jamais dérivée du PIN, voir `lock.dart`) —
/// jamais dans un journal système ou un fichier en clair. Directive explicite de l'utilisateur
/// (« l'enregistrement doit être écrit exclusivement dans la base de données locale chiffrée par
/// SQLCipher ») : respectée ici avec une base séparée, plutôt que la base Matrix elle-même (pas
/// de raison de mélanger ce petit historique au schéma du SDK Matrix).
class CallOpsecStore {
  static const _dbName = 'murmure_calls.db';

  static Future<sqlcipher.Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    return sqlcipher.openDatabase(
      p.join(dir.path, _dbName),
      password: await Account.dbKey(),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE missed_calls (room_id TEXT NOT NULL, remote_user_id TEXT, ts INTEGER NOT NULL)',
      ),
    );
  }

  static Future<void> insert(MissedCall call) async {
    final db = await _open();
    try {
      await db.insert('missed_calls', {
        'room_id': call.roomId,
        'remote_user_id': call.remoteUserId,
        'ts': call.timestamp,
      });
    } finally {
      await db.close();
    }
  }

  /// Les plus récents d'abord — pour un futur écran d'historique (non implémenté dans cette
  /// passe, voir docs/CALLS_ARCHITECTURE.md).
  static Future<List<MissedCall>> list() async {
    final db = await _open();
    try {
      final rows = await db.query('missed_calls', orderBy: 'ts DESC');
      return rows
          .map((r) => MissedCall(
                roomId: r['room_id'] as String,
                remoteUserId: r['remote_user_id'] as String?,
                timestamp: r['ts'] as int,
              ))
          .toList();
    } finally {
      await db.close();
    }
  }

  static Future<void> clear() async {
    final db = await _open();
    try {
      await db.delete('missed_calls');
    } finally {
      await db.close();
    }
  }

  /// Détruit le fichier de cette base (et ses fragments `-wal`/`-shm`/`-journal` éventuels) sur le
  /// disque — appelé par `Account.wipeLocal()` (donc par `panic()` et `deleteEverything()`).
  ///
  /// Corrige une lacune trouvée en audit interne (pas une proposition externe) : cette base a été
  /// créée dans une passe ultérieure à l'écriture de `Account.wipeLocal()`, qui ne connaissait donc
  /// que `murmure_matrix.db` et `murmure_mesh.db` — la boucle de suppression de `wipeLocal()` ne
  /// mentionnait jamais `murmure_calls.db`. Conséquence concrète : après un essuyage de panique ou
  /// une suppression de compte, le fichier chiffré de cet historique (salons concernés,
  /// identifiants Matrix des correspondants, horodatages des appels manqués) restait physiquement
  /// sur le disque — illisible une fois `db_key` détruit par `_storage.deleteAll()` (clé partagée
  /// avec les autres bases SQLCipher), mais présent, ce qui contredit la garantie documentée
  /// (« Clés, messages et médias disparaissent du téléphone ») et constitue en soi une anomalie
  /// repérable lors d'un examen forensique du téléphone (fichier chiffré survivant alors que ses
  /// deux bases sœurs ont bien disparu). N'ouvre aucune connexion ici : chaque méthode ci-dessus
  /// ouvre puis referme la sienne, donc il n'y a jamais de handle à fermer au moment de l'essuyage
  /// (contrairement à `Mesh.reset()`, qui doit fermer un handle tenu en mémoire).
  ///
  /// Trouvé en audit interne (pas une proposition externe) : cette méthode reproduisait exactement
  /// le même défaut déjà corrigé ailleurs dans ce fichier pour `murmure_matrix.db`/`murmure_mesh.db`
  /// (voir `Account.wipeLocal`) — le nettoyage des fragments `-wal`/`-shm`/`-journal` n'était tenté
  /// que dans le `catch`, donc jamais exécuté quand `deleteDatabase` réussissait, ce qui est le cas
  /// courant. SQLite/SQLCipher peut parfaitement supprimer le fichier principal en laissant ces
  /// fragments derrière (comportement connu). La clé SQLCipher est déjà détruite avant l'appel à
  /// cette méthode (`_storage.deleteAll()` en tête de `Account.wipeLocal`), donc ces fragments ne
  /// contiennent rien de déchiffrable — mais leur seule présence est une trace forensique que cette
  /// méthode a justement pour but d'éliminer. Tenté maintenant inconditionnellement.
  static Future<void> wipe() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _dbName);
    try {
      await sqlcipher.deleteDatabase(path);
    } catch (_) {}
    for (final suffix in ['-wal', '-shm', '-journal']) {
      try {
        await File('$path$suffix').delete();
      } catch (_) {}
    }
  }
}
