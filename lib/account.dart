import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'calls/services/call_opsec_store.dart';
import 'config.dart';
import 'media.dart';
import 'mesh/mesh.dart';
import 'network.dart';

/// Compte local : identifiants et secrets gardés dans le Keystore Android, via
/// flutter_secure_storage.
///
/// LIMITE HONNÊTE (corrige une inexactitude trouvée en audit interne dans ce commentaire même) :
/// ce commentaire affirmait auparavant « StrongBox quand disponible », ce que la bibliothèque ne
/// permet pas de garantir. `AndroidOptions` (vérifié sur la documentation publiée du paquet) n'a
/// AUCUN paramètre lié à StrongBox — seuls `encryptedSharedPreferences`, `resetOnError`,
/// `keyCipherAlgorithm`, `storageCipherAlgorithm`, `sharedPreferencesName` et
/// `preferencesKeyPrefix` existent. Sur Android, forcer l'utilisation de la puce StrongBox (quand
/// le matériel la propose) demande d'appeler explicitement `setIsStrongBoxBacked(true)` sur le
/// `KeyGenParameterSpec` natif — flutter_secure_storage n'expose ce choix à l'appelant Dart dans
/// aucune version de son API publique, donc rien dans ce dépôt ne peut l'activer ni le garantir
/// depuis ce fichier. La clé reste protégée par l'Android Keystore (TEE, ou StrongBox si et
/// seulement si le plugin le fait lui-même en interne sans l'exposer — non vérifié ici, et à ne
/// pas supposer), ce qui est déjà la propriété de sécurité réelle sur laquelle compter ; ne pas
/// présenter StrongBox comme acquis dans la documentation ou face à l'utilisateur.
class Account {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _dbName = 'murmure_matrix.db';
  static const kMeshDbName = 'murmure_mesh.db';

  static String _random(int bytes) {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// Clé SQLCipher commune aux bases locales, créée au premier lancement. Aléatoire, jamais
  /// dérivée du PIN (voir lock.dart pour pourquoi).
  static Future<String> dbKey() async {
    var key = await _storage.read(key: 'db_key');
    if (key == null) {
      key = _random(32);
      await _storage.write(key: 'db_key', value: key);
    }
    return key;
  }

  /// Graine aléatoire de 32 octets gardée dans le Keystore sous [name] (créée au premier appel).
  static Future<List<int>> seed(String name) async {
    var s = await _storage.read(key: name);
    if (s == null) {
      s = _random(32);
      await _storage.write(key: name, value: s);
    }
    return base64Url.decode(base64Url.normalize(s));
  }

  static Future<String?> read(String key) => _storage.read(key: key);
  static Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  static Future<void> delete(String key) => _storage.delete(key: key);

  /// Base locale du SDK Matrix (messages, clés Olm/Megolm), chiffrée par SQLCipher.
  static Future<sqlcipher.Database> openDatabase() async {
    final dir = await getApplicationSupportDirectory();
    return sqlcipher.openDatabase(p.join(dir.path, _dbName), password: await dbKey());
  }

  /// Crée un compte sans numéro de téléphone ni e-mail : identifiant et mot de passe aléatoires,
  /// jamais montrés à l'utilisateur. Seul le nom affiché est choisi.
  static Future<void> register(Client client, String displayName) async {
    final net = await NetConfig.load();
    await client.checkHomeserver(net.homeserver, checkWellKnown: false);
    final username = 'm${_random(9).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}';
    final password = _random(32);
    await _storage.write(key: 'password', value: password);
    const device = 'Murmure Android';
    try {
      await client.register(username: username, password: password, initialDeviceDisplayName: device);
    } on MatrixException catch (e) {
      if (!e.requireAdditionalAuthentication) rethrow;
      // Authentification interactive : jeton d'inscription si le serveur l'exige.
      final stages = e.authenticationFlows?.expand((f) => f.stages).toSet() ?? <String>{};
      final auth = stages.contains('m.login.registration_token')
          ? AuthenticationData.fromJson({
              'type': 'm.login.registration_token',
              'token': net.registrationToken,
              'session': e.session,
            })
          : AuthenticationData(type: 'm.login.dummy', session: e.session);
      await client.register(
          username: username, password: password, initialDeviceDisplayName: device, auth: auth);
    }
    await setDisplayName(client, displayName);
  }

  static Future<void> setDisplayName(Client client, String name) =>
      client.setDisplayName(client.userID!, name);

  /// Supprime le compte sur le serveur, puis efface tout de ce téléphone.
  ///
  /// Trouvé en audit interne (revue croisée IA, confirmé en relisant ce fichier) : le `rethrow`
  /// ci-dessous (erreur serveur/réseau NE nécessitant PAS d'authentification supplémentaire —
  /// timeout, 500, serveur injoignable) remontait directement à l'appelant, et `wipeLocal(client)`
  /// n'était alors JAMAIS atteint. Quelqu'un demandant explicitement la suppression de son compte
  /// pendant une coupure réseau se retrouvait donc avec absolument RIEN effacé localement — clés,
  /// messages, médias intacts — alors que l'intention explicite était de tout détruire. La
  /// suppression côté serveur peut légitimement échouer (c'est un appel réseau comme un autre),
  /// mais l'effacement local, lui, ne doit jamais dépendre de ce succès : c'est exactement ce que
  /// [panic] garantit déjà sans aucun réseau. `try/finally` plutôt que `catch` générique : on
  /// propage toujours l'erreur serveur à l'appelant (pour qu'il puisse prévenir l'utilisateur que
  /// la suppression côté serveur a échoué), mais `wipeLocal` s'exécute dans tous les cas avant que
  /// cette propagation n'ait lieu.
  static Future<void> deleteEverything(Client client) async {
    try {
      final password = await _storage.read(key: 'password');
      if (password != null && client.isLogged()) {
        try {
          await client.deactivateAccount();
        } on MatrixException catch (e) {
          if (!e.requireAdditionalAuthentication) rethrow;
          await client.deactivateAccount(
            auth: AuthenticationData.fromJson({
              'type': 'm.login.password',
              'identifier': {'type': 'm.id.user', 'user': client.userID},
              'password': password,
              'session': e.session,
            }),
          );
        }
      }
    } finally {
      await wipeLocal(client);
    }
  }

  /// Effacement d'urgence : sans réseau, en quelques centaines de millisecondes.
  /// Clés, messages et médias disparaissent du téléphone ; le compte reste sur le serveur mais
  /// devient inutilisable (plus aucune clé pour lire quoi que ce soit), puis l'appli se ferme
  /// immédiatement — un `exit(0)` forcé, pour ne laisser aucun état résiduel en mémoire après un
  /// code de contrainte ou un dépassement du nombre d'essais (point relevé lors de la revue de
  /// la 2.3.0 : sans cela, un observateur voit le redémarrage de l'appli, ce qui trahit l'usage
  /// du code de contrainte).
  static Future<Never> panic(Client? client) async {
    await wipeLocal(client);
    exit(0);
  }

  /// Détruit tout ce que Murmure stocke sur ce téléphone (sans réseau).
  /// [client] peut être null si le démarrage a échoué ou si seul le mode Bluetooth sert.
  static Future<void> wipeLocal(Client? client) async {
    await _storage.deleteAll(); // en premier : sans la clé, la base SQLCipher est illisible
    try {
      await client?.dispose(closeDatabase: true);
    } catch (_) {}
    await Mesh.reset();
    // Trouvé en audit interne (pas une proposition externe) : cette base a été ajoutée dans une
    // passe postérieure à l'écriture de la boucle ci-dessous, qui ne connaissait donc que les deux
    // bases historiques — `murmure_calls.db` (salons, identifiants Matrix des correspondants et
    // horodatages des appels manqués) survivait sinon à la fois à `panic()` et à
    // `deleteEverything()`, contredisant la garantie documentée juste au-dessus. Voir
    // `CallOpsecStore.wipe()` pour le détail.
    await CallOpsecStore.wipe();
    final dir = await getApplicationSupportDirectory();
    for (final name in [_dbName, kMeshDbName]) {
      final path = p.join(dir.path, name);
      try {
        await sqlcipher.deleteDatabase(path);
      } catch (_) {}
      // Trouvé en audit interne (revue croisée IA, confirmé en relisant ce fichier) : ce nettoyage
      // des fichiers annexes WAL/SHM/journal n'était tenté que dans le `catch` ci-dessus, donc
      // jamais exécuté quand `deleteDatabase` réussissait — alors que SQLite/SQLCipher peut
      // parfaitement réussir à supprimer le fichier principal tout en laissant `-wal`/`-shm`
      // derrière (comportement connu, pas spécifique à ce dépôt). La clé SQLCipher a déjà été
      // détruite tout en haut de cette méthode (`_storage.deleteAll()`), donc ces fichiers ne
      // contiennent rien de déchiffrable pour quiconque les retrouverait — mais leur simple
      // existence (nom de fichier, taille, horodatage) reste une trace qu'une base de données a
      // existé à cet endroit, contrairement à l'objectif affiché par cette méthode de ne rien
      // laisser derrière. Tenté maintenant inconditionnellement, plus seulement en cas d'échec.
      for (final suffix in ['-wal', '-shm', '-journal']) {
        try {
          await File('$path$suffix').delete();
        } catch (_) {}
      }
    }
    await purgeMediaCache();
  }
}

/// Extrait un identifiant Matrix (@utilisateur:serveur) d'un texte, lien ou QR code.
String? parseUserId(String text) =>
    RegExp(r'@[a-z0-9.=_/+-]+:[A-Za-z0-9.-]+(?::\d+)?').firstMatch(text)?[0];

String shareableId(String userId) => '$kIdPrefix$userId';
