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
}
