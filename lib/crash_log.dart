import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'account.dart';

/// Un plantage ou une erreur non interceptée, tel que gardé par [CrashLogStore].
class CrashEntry {
  const CrashEntry({
    required this.ts,
    required this.source,
    required this.errorType,
    required this.stack,
  });

  final DateTime ts;

  /// `flutter` (erreur de construction/rendu d'un widget) ou `dart` (erreur asynchrone non
  /// interceptée ailleurs, remontée par [PlatformDispatcher.onError]).
  final String source;

  /// `error.runtimeType.toString()` — JAMAIS `error.toString()`, voir la documentation de
  /// [CrashLogStore].
  final String errorType;

  /// Pile d'appel, tronquée (voir [CrashLogStore._maxStackChars]).
  final String stack;
}

/// Journal d'erreurs purement LOCAL — roadmap « monitoring/crash reporting respectueux de la vie
/// privée ». Ce dépôt n'intègre, et n'a pas vocation à intégrer, aucun SDK de télémétrie tiers
/// (Sentry, Crashlytics, UnifiedPush...) : créer un compte sur un tel service au nom de la personne
/// qui utilise Murmure, ou faire transiter la moindre information de plantage par un serveur
/// extérieur à son propre téléphone, est explicitement hors de question pour ce projet (modèle de
/// menace : la liste des plantages d'une personne en manifestation ne doit exister QUE sur son
/// propre appareil, sous son contrôle). Sert uniquement à l'écran « Diagnostics »
/// (ui/diagnostics_screen.dart), que la personne consulte elle-même sur SON téléphone — rien n'est
/// envoyé où que ce soit, jamais, par ce fichier.
///
/// CONFIDENTIALITÉ : on ne garde jamais `error.toString()` ni le contexte du widget en cause
/// (`FlutterErrorDetails.context`/`library`/`summary`), seulement le NOM DE TYPE de l'exception
/// (`RangeError`, `StateError`...) et sa pile d'appel. Une pile d'appel Dart ne contient que des
/// emplacements (fichier:ligne:colonne) et des noms de fonctions du CODE, jamais la valeur d'une
/// variable — mais le message d'une exception, lui, est parfois construit par le site d'origine
/// avec des données concrètes (ex. `FormatException('entrée invalide : $texte')`) : `toString()`
/// est donc délibérément exclu par précaution, plutôt que vérifié site par site dans ce dépôt et
/// ses dépendances (SDK Matrix compris).
///
/// Base SQLCipher séparée (même clé que les autres, voir [Account.dbKey]), par symétrie avec
/// `calls/services/call_opsec_store.dart` : chiffrée au repos, et supprimée par
/// `Account.wipeLocal()` (effacement de panique / suppression de compte) — son nom de fichier est
/// inclus dans `Account._allDbNames` dès sa création, précisément pour ne jamais reproduire la
/// lacune déjà trouvée (et corrigée) deux fois dans ce dépôt pour `murmure_calls.db` : une base
/// ajoutée après coup que la boucle d'effacement ne connaissait pas encore.
class CrashLogStore {
  CrashLogStore._();

  static const _maxEntries = 30;
  static const _maxAge = Duration(days: 30);
  static const _maxStackChars = 4000;

  static Future<sqlcipher.Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    return sqlcipher.openDatabase(
      // Nom partagé avec `Account._allDbNames` (`Account.kCrashDbName`) : une seule constante,
      // jamais deux littéraux dupliqués à garder synchronisés entre les deux fichiers.
      p.join(dir.path, Account.kCrashDbName),
      password: await Account.dbKey(),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE crashes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL,
          source TEXT NOT NULL,
          error_type TEXT NOT NULL,
          stack TEXT NOT NULL
        )
      '''),
    );
  }

  /// Installe les deux gestionnaires globaux de Flutter — à appeler une seule fois, tout au début
  /// de `main()` (voir main.dart), avant tout autre code pouvant planter. Vérifié contre le code
  /// source réel de Flutter au tag pinné (3.41.9) :
  /// - `FlutterError.onError` vaut par défaut `FlutterError.presentError` (lui-même
  ///   `dumpErrorToConsole`) : l'appeler nous-mêmes à la fin de notre gestionnaire préserve
  ///   exactement le comportement normal (impression console), qu'on ne fait que précéder.
  /// - `PlatformDispatcher.onError` (`bool Function(Object, StackTrace)`) : `_dispatchError`
  ///   (engine/.../platform_dispatcher.dart) utilise la valeur de retour pour décider d'un repli —
  ///   `false` déclenche le mécanisme par défaut (impression sur stderr), exactement comme
  ///   l'absence de tout gestionnaire ; on renvoie donc toujours `false` pour ne RIEN changer au
  ///   comportement existant au-delà de l'enregistrement local ajouté ici.
  static void install() {
    FlutterError.onError = (details) {
      unawaited(_recordSafe(source: 'flutter', error: details.exception, stack: details.stack));
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(_recordSafe(source: 'dart', error: error, stack: stack));
      return false;
    };
  }

  static Future<void> _recordSafe({
    required String source,
    required Object error,
    StackTrace? stack,
  }) async {
    try {
      await record(source: source, error: error, stack: stack);
    } catch (_) {
      // Best-effort : le journal d'erreurs ne doit jamais lui-même devenir une cause de plantage.
    }
  }

  static Future<void> record({
    required String source,
    required Object error,
    StackTrace? stack,
  }) async {
    final db = await _open();
    try {
      final stackStr = (stack ?? StackTrace.current).toString();
      await db.insert('crashes', {
        'ts': DateTime.now().millisecondsSinceEpoch,
        'source': source,
        'error_type': error.runtimeType.toString(),
        'stack':
            stackStr.length > _maxStackChars ? stackStr.substring(0, _maxStackChars) : stackStr,
      });
      await _purge(db);
    } finally {
      await db.close();
    }
  }

  /// Purge par âge ([_maxAge], même esprit que les autres fenêtres de rétention du dépôt — voir
  /// `MeshEnvelope.maxAgeHours`) puis par nombre ([_maxEntries], les plus anciennes d'abord) : un
  /// journal de diagnostic n'a pas besoin de grandir sans limite.
  static Future<void> _purge(sqlcipher.Database db) async {
    final cutoff = DateTime.now().subtract(_maxAge).millisecondsSinceEpoch;
    await db.delete('crashes', where: 'ts < ?', whereArgs: [cutoff]);
    // `query(columns: ['id'])` plutôt que `rawQuery('SELECT COUNT(*)...')` : même méthode
    // `Database.query` déjà utilisée partout ailleurs dans ce dépôt (voir `CallOpsecStore.list`),
    // pas une nouvelle façon d'interroger la base pour un simple décompte.
    final ids = await db.query('crashes', columns: ['id']);
    final count = ids.length;
    if (count > _maxEntries) {
      await db.delete(
        'crashes',
        where: 'id IN (SELECT id FROM crashes ORDER BY ts ASC, id ASC LIMIT ?)',
        whereArgs: [count - _maxEntries],
      );
    }
  }

  /// Les plus récentes d'abord, pour l'écran Diagnostics.
  static Future<List<CrashEntry>> list() async {
    final db = await _open();
    try {
      final rows = await db.query('crashes', orderBy: 'ts DESC, id DESC');
      return rows
          .map((r) => CrashEntry(
                ts: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
                source: r['source'] as String,
                errorType: r['error_type'] as String,
                stack: r['stack'] as String,
              ))
          .toList();
    } finally {
      await db.close();
    }
  }

  static Future<void> clear() async {
    final db = await _open();
    try {
      await db.delete('crashes');
    } finally {
      await db.close();
    }
  }
}
