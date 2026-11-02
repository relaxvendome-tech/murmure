import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'config.dart';
import 'media.dart';
import 'mesh/mesh.dart';
import 'network.dart';

/// Compte local : identifiants et secrets gardés dans le Keystore Android (StrongBox quand
/// disponible, via flutter_secure_storage).
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
      client.setProfileField(client.userID!, 'displayname', {'displayname': name});

  /// Supprime le compte sur le serveur, puis efface tout de ce téléphone.
  static Future<void> deleteEverything(Client client) async {
    final password = await _storage.read(key: 'password');
    if (password != null && client.isLogged()) {
      try {
        await client.deactivateAccount(erase: true);
      } on MatrixException catch (e) {
        if (!e.requireAdditionalAuthentication) rethrow;
        await client.deactivateAccount(
          erase: true,
          auth: AuthenticationData.fromJson({
            'type': 'm.login.password',
            'identifier': {'type': 'm.id.user', 'user': client.userID},
            'password': password,
            'session': e.session,
          }),
        );
      }
    }
    await wipeLocal(client);
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
    final dir = await getApplicationSupportDirectory();
    for (final name in [_dbName, kMeshDbName]) {
      final path = p.join(dir.path, name);
      try {
        await sqlcipher.deleteDatabase(path);
      } catch (_) {
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          try {
            await File('$path$suffix').delete();
          } catch (_) {}
        }
      }
    }
    await purgeMediaCache();
  }
}

/// Extrait un identifiant Matrix (@utilisateur:serveur) d'un texte, lien ou QR code.
String? parseUserId(String text) =>
    RegExp(r'@[a-z0-9.=_/+-]+:[A-Za-z0-9.-]+(?::\d+)?').firstMatch(text)?[0];

String shareableId(String userId) => '$kIdPrefix$userId';
