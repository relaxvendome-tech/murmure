import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin, FlutterLocalNotificationsPlugin;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'calls/services/call_foreground_service.dart';
import 'calls/services/call_opsec_store.dart';
import 'config.dart';
import 'media.dart';
import 'mesh/mesh.dart';
import 'network.dart';

/// Le Keystore Android est (au moins temporairement) illisible : la valeur demandée existe
/// probablement mais ne peut pas être lue.
///
/// Vérifié dans le source Android de flutter_secure_storage v9.2.4 (`FlutterSecureStorage.java`,
/// `ensureInitialized`) : si l'initialisation d'EncryptedSharedPreferences échoue (erreur du
/// Keystore), le plugin bascule SILENCIEUSEMENT, pour tout le reste du processus
/// (`failedToUseEncryptedSharedPreferences = true`), sur un fichier de préférences non chiffré et
/// vide de nos valeurs : `read` renvoie alors `null` sans aucune exception. Pire, ce qui est écrit
/// dans ce mode est recopié par `checkAndMigrateToEncrypted` PAR-DESSUS les vraies valeurs au
/// lancement suivant. « Absent » et « illisible » sont donc indiscernables par le seul Keystore :
/// des marqueurs fichiers hors Keystore (voir [Account.markerExists]) disent si une valeur DOIT
/// exister. Quand c'est le cas et qu'elle est lue `null`, on lève cette exception et on n'écrit,
/// ne supprime ni ne crée RIEN. Le basculement étant collant pour le processus, réessayer dans le
/// même processus ne sert à rien : l'appli doit être entièrement fermée puis relancée.
class KeystoreUnavailable implements Exception {
  const KeystoreUnavailable();
  @override
  String toString() => 'KeystoreUnavailable';
}

/// Raison lisible d'un échec bloquant survenu APRÈS l'onboarding (ex. inscription annulée faute
/// de chiffrement fonctionnel), affichée par l'écran d'erreur de démarrage (main.dart). Jamais de
/// secret ni de texte d'exception brut ici : cet écran est visible sans déverrouillage.
final ValueNotifier<String?> fatalErrorReason = ValueNotifier<String?>(null);

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
  ///
  /// Trouvé en audit interne (effacement interrompu) : si `wipeLocal` est interrompu après
  /// `_storage.deleteAll()` mais avant la suppression des fichiers (appli tuée, batterie…), les
  /// bases restent sur le disque alors que leur clé a disparu. Le lancement suivant créait une
  /// NOUVELLE clé, tentait d'ouvrir l'ancienne base avec, échouait (« file is not a database »)
  /// et affichait l'écran d'erreur de démarrage en boucle, sans issue. Les bases restantes d'un
  /// effacement interrompu (marqueur [kWipePendingMarker] présent) sont donc supprimées
  /// (+ fichiers -wal/-shm/-journal) AVANT de créer la nouvelle clé — mais JAMAIS sur la seule foi
  /// d'une clé lue `null`, qui peut signifier « Keystore en panne » (voir [KeystoreUnavailable]). Les appels concurrents
  /// (base Matrix, mesh, appels ouvertes en parallèle) sont sérialisés par [_dbKeyOp] pour
  /// qu'une seule clé soit jamais créée et qu'aucune base fraîchement créée ne soit supprimée.
  static Future<String> dbKey() =>
      _dbKeyOp ??= _loadOrCreateDbKey().whenComplete(() => _dbKeyOp = null);

  static Future<String>? _dbKeyOp;

  static Future<String> _loadOrCreateDbKey() async {
    // Trouvé en audit interne (perte totale sur panne Keystore) : la version précédente supprimait
    // toutes les bases dès que `db_key` était lue `null`. Or une panne du Keystore fait renvoyer
    // `null` sans exception (voir [KeystoreUnavailable]) : un simple incident Keystore effaçait
    // donc irréversiblement messages, clés Olm et mesh. « Clé absente » (installation neuve,
    // effacement terminé ou interrompu) est maintenant distingué de « clé illisible » par le
    // marqueur fichier [kWipePendingMarker], créé en TOUT PREMIER par [wipeLocal].
    final wipePending = await markerExists(kWipePendingMarker, onError: false);
    final existing = await _storage.read(key: 'db_key');
    if (existing != null && !wipePending) return existing;
    if (existing == null && !wipePending && await _anyDatabaseExists()) {
      // Des bases existent, aucun effacement n'a été demandé : la clé existe forcément, elle est
      // seulement illisible. Ne rien supprimer, ne rien écrire (une écriture ici écraserait la
      // vraie clé au prochain lancement, voir [KeystoreUnavailable]).
      throw const KeystoreUnavailable();
    }
    // Installation neuve, ou effacement ([wipeLocal]) à terminer — y compris s'il a été
    // interrompu avant même `deleteAll()` (clé encore lisible) : l'intention d'effacer prime.
    if (wipePending) {
      try {
        await _storage.deleteAll();
      } catch (_) {}
    }
    await _deleteOrphanDatabases();
    await _clearStateMarkers();
    final key = _random(32);
    await _storage.write(key: 'db_key', value: key);
    await clearMarker(kWipePendingMarker);
    return key;
  }

  /// Noms de toutes les bases SQLCipher chiffrées par [dbKey].
  static const _allDbNames = [_dbName, kMeshDbName, _callsDbName];

  /// Nom réel de la base de `calls/services/call_opsec_store.dart` (constante privée là-bas).
  static const _callsDbName = 'murmure_calls.db';

  static Future<bool> _anyDatabaseExists() async {
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in _allDbNames) {
        for (final suffix in ['', '-wal', '-journal']) {
          if (await File(p.join(dir.path, '$name$suffix')).exists()) return true;
        }
      }
      return false;
    } catch (_) {
      // Impossible de vérifier : prudence, on considère qu'une base existe (aucune suppression).
      return true;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Marqueurs fichiers hors Keystore
  // ---------------------------------------------------------------------------------------------

  /// Effacement demandé et pas encore terminé (voir [wipeLocal], [_loadOrCreateDbKey]).
  static const kWipePendingMarker = '.wipe_pending';

  /// Un code PIN est configuré (voir `AppLock.setPin`/`disable`/`enabled`).
  static const kLockOnMarker = '.lock_on';

  /// Le mode discret (calculatrice) est actif (voir `AppLock.setCalcMode`/`calcMode`).
  static const kCalcOnMarker = '.calc_on';

  static const _seedMarkerPrefix = '.seed_';

  static Future<File> _markerFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, name));
  }

  /// Vrai si le marqueur existe. En cas d'erreur d'E/S : [onError]. Par défaut `true` (échec
  /// fermé : un marqueur d'état supposé présent ne fait que bloquer, jamais ouvrir) ; pour
  /// [kWipePendingMarker], qui AUTORISE une suppression, l'appelant passe `onError: false`.
  static Future<bool> markerExists(String name, {bool onError = true}) async {
    try {
      return await (await _markerFile(name)).exists();
    } catch (_) {
      return onError;
    }
  }

  /// Crée le marqueur (contenu vide, écrit et synchronisé sur disque). Lève en cas d'échec.
  static Future<void> setMarker(String name) async {
    final f = await _markerFile(name);
    if (await f.exists()) return;
    await f.parent.create(recursive: true);
    await f.writeAsString('', flush: true);
  }

  /// Supprime le marqueur s'il existe. Lève en cas d'échec.
  static Future<void> clearMarker(String name) async {
    final f = await _markerFile(name);
    if (await f.exists()) await f.delete();
  }

  /// Supprime tous les marqueurs d'état (PIN, mode discret, graines), pas [kWipePendingMarker].
  static Future<void> _clearStateMarkers() async {
    for (final m in [kLockOnMarker, kCalcOnMarker]) {
      try {
        await clearMarker(m);
      } catch (_) {}
    }
    try {
      final dir = await getApplicationSupportDirectory();
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && p.basename(e.path).startsWith(_seedMarkerPrefix)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Supprime toutes les bases SQLCipher connues (Matrix, mesh, appels) et leurs fichiers annexes.
  /// Chaque suppression est indépendante : l'échec de l'une n'empêche pas les autres.
  static Future<void> _deleteOrphanDatabases() async {
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in _allDbNames) {
        await _deleteDbFiles(p.join(dir.path, name));
      }
    } catch (_) {}
    try {
      await CallOpsecStore.wipe();
    } catch (_) {}
  }

  static Future<void> _deleteDbFiles(String path) async {
    try {
      await sqlcipher.deleteDatabase(path);
    } catch (_) {}
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      try {
        final f = File('$path$suffix');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Graine aléatoire de 32 octets gardée dans le Keystore sous [name] (créée au premier appel).
  ///
  /// Même règle que [dbKey] (voir [KeystoreUnavailable]) : un marqueur `.seed_<name>` (créé dès
  /// que la graine est connue, y compris pour une graine antérieure à ce marqueur) indique qu'elle
  /// existe. Lue `null` alors que ce marqueur existe et qu'aucun effacement n'est en cours : on
  /// lève [KeystoreUnavailable] au lieu d'en créer une nouvelle (qui changerait l'identité mesh et
  /// écraserait la vraie graine au lancement suivant).
  static Future<List<int>> seed(String name) async {
    final marker = '$_seedMarkerPrefix${name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
    var s = await _storage.read(key: name);
    if (s == null) {
      if (await markerExists(marker) && !await markerExists(kWipePendingMarker, onError: false)) {
        throw const KeystoreUnavailable();
      }
      s = _random(32);
      await _storage.write(key: name, value: s);
    }
    try {
      await setMarker(marker);
    } catch (_) {
      // Best-effort : sans marqueur, on retombe sur l'ancien comportement (pas pire).
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
    // Trouvé en audit interne : si vodozemac ne s'initialise pas (`vod.init()` en échec, voir main.dart), le SDK initialise le client
    // SANS chiffrement (`client.encryption == null`) et les messages partiraient en clair. Une
    // messagerie chiffrée ne doit jamais fonctionner dans ce mode dégradé : on annule.
    if (!client.encryptionEnabled) {
      fatalErrorReason.value =
          'Inscription annulée : le chiffrement de bout en bout est indisponible sur cet appareil. '
          'Aucun message ne peut être envoyé sans chiffrement.';
      try {
        await client.logout();
      } catch (_) {
        // Déconnexion impossible (réseau…) : la session reste « connectée » localement, sans
        // chiffrement, et l'appli resterait bloquée sur l'écran d'erreur à chaque lancement.
        // On purge donc la session locale (jeton, base, clés) : au prochain lancement, retour à
        // l'onboarding. Le compte orphelin côté serveur n'a aucune clé et reste inutilisable.
        try {
          await wipeLocal(client);
        } catch (_) {}
      }
      throw StateError('Chiffrement indisponible');
    }
    await setDisplayName(client, displayName);
  }

  static Future<void> setDisplayName(Client client, String name) =>
      client.setDisplayName(client.userID!, name);

  /// Supprime le compte sur le serveur (désactivation Matrix), SANS toucher aux données locales.
  ///
  /// LÈVE en cas d'échec (hors ligne, timeout, erreur serveur, mot de passe introuvable, client non
  /// connecté) : l'appelant (voir `ui/rooms_screen.dart`) doit alors prévenir l'utilisateur que le
  /// compte existe toujours sur le serveur et lui laisser choisir (réessayer, n'effacer que ce
  /// téléphone, annuler) — avant, un échec réseau effaçait le téléphone en laissant croire que le
  /// compte était supprimé. En cas de succès, l'appelant enchaîne avec [wipeLocal].
  static Future<void> deactivateRemote(Client client) async {
    final password = await _storage.read(key: 'password');
    if (password == null || !client.isLogged()) {
      throw StateError('Suppression sur le serveur impossible');
    }
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

  /// Effacement d'urgence : sans réseau, en quelques centaines de millisecondes.
  /// Clés, messages et médias disparaissent du téléphone ; le compte reste sur le serveur mais
  /// devient inutilisable (plus aucune clé pour lire quoi que ce soit), puis l'appli se ferme
  /// immédiatement — un `exit(0)` forcé, pour ne laisser aucun état résiduel en mémoire après un
  /// code de contrainte ou un dépassement du nombre d'essais (point relevé lors de la revue de
  /// la 2.3.0 : sans cela, un observateur voit le redémarrage de l'appli, ce qui trahit l'usage
  /// du code de contrainte).
  static Future<Never> panic(Client? client) async {
    try {
      await wipeLocal(client);
    } catch (_) {
      // Rien : l'effacement fait de son mieux étape par étape (voir [wipeLocal]) ; l'appli doit
      // se fermer quoi qu'il arrive.
    } finally {
      exit(0);
    }
  }

  /// Canaux de notification Android créés par Murmure, actuels ET anciens (Dart :
  /// message_notifier.dart, calls/services/call_opsec_notifier.dart,
  /// mesh/mesh_opsec_notifier.dart ; natif : MeshForegroundService.kt). Leur nom (« Appels »,
  /// « Maillage Bluetooth »…) reste visible dans les réglages Android de l'appli tant qu'ils
  /// existent : une trace d'usage. Supprimer un canal inexistant est sans effet.
  static const _notificationChannels = [
    'murmure_messages',
    'murmure_calls',
    'murmure_incoming_calls',
    'discreet_activity_v3',
    'discreet_ring_v3',
    'discreet_activity_v2',
    'discreet_ring_v2',
    'discreet_activity_v1',
    'discreet_ring_v1',
    'discreet_activity',
    'discreet_ring',
    'murmure_mesh',
    'sys_calc_cache_v1',
    'discreet_bg_v2',
    ..._foregroundServiceChannels,
  ];

  /// Canaux du service de premier plan mesh (MeshForegroundService.kt) : leur suppression lève
  /// une SecurityException tant que le service tourne encore ; [wipeLocal] les retente une fois
  /// après 300 ms (le temps que l'arrêt du service par [Mesh.reset] aboutisse).
  static const _foregroundServiceChannels = [
    'murmure_mesh_fg',
    'sys_calc_bg_v1',
    'discreet_fg_v2',
    // Service de premier plan des appels (CallForegroundService.kt, notification id 4151).
    'murmure_call_fg',
    'discreet_call_fg_v1',
  ];

  /// Détruit tout ce que Murmure stocke sur ce téléphone (sans réseau).
  /// [client] peut être null si le démarrage a échoué ou si seul le mode Bluetooth sert.
  ///
  /// Chaque étape est isolée dans son propre try/catch : l'échec de l'une (plugin indisponible,
  /// fichier verrouillé…) ne doit jamais empêcher les suivantes.
  static Future<void> wipeLocal(Client? client) async {
    // TOUT PREMIER : marqueur « effacement en cours », hors Keystore. Il autorise
    // [_loadOrCreateDbKey] à supprimer les bases restantes si l'effacement est interrompu, et
    // seulement dans ce cas (voir [KeystoreUnavailable]).
    try {
      await setMarker(kWipePendingMarker);
    } catch (_) {}
    try {
      await _storage.deleteAll(); // sans la clé, la base SQLCipher est illisible
    } catch (_) {}
    await _clearStateMarkers();
    try {
      await client?.dispose(closeDatabase: true);
    } catch (_) {}
    try {
      await Mesh.reset();
    } catch (_) {}
    try {
      await CallForegroundService.stop(); // notification 4151 + micro/caméra d'un appel en cours
    } catch (_) {}
    // Trouvé en audit interne (pas une proposition externe) : cette base a été ajoutée dans une
    // passe postérieure à l'écriture de la boucle ci-dessous, qui ne connaissait donc que les deux
    // bases historiques — `murmure_calls.db` (salons, identifiants Matrix des correspondants et
    // horodatages des appels manqués) survivait sinon à la fois à `panic()` et à
    // la suppression de compte, contredisant la garantie documentée juste au-dessus. Voir
    // `CallOpsecStore.wipe()` pour le détail.
    try {
      await CallOpsecStore.wipe();
    } catch (_) {}
    // Les fichiers annexes WAL/SHM/journal sont supprimés inconditionnellement (voir
    // [_deleteDbFiles]) : SQLite peut supprimer le fichier principal en les laissant derrière.
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in _allDbNames) {
        await _deleteDbFiles(p.join(dir.path, name));
      }
    } catch (_) {}
    try {
      await purgeMediaCache();
    } catch (_) {}
    // Notifications : une notification « Nouveau message »/« Appel manqué » restée dans la barre
    // d'état après un effacement trahirait l'usage de l'appli.
    final notifications = FlutterLocalNotificationsPlugin();
    try {
      await notifications.cancelAll();
    } catch (_) {}
    AndroidFlutterLocalNotificationsPlugin? android;
    try {
      android = notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    } catch (_) {}
    if (android != null) {
      for (final id in _notificationChannels) {
        try {
          await android.deleteNotificationChannel(id);
        } catch (_) {}
      }
      // Second essai pour les canaux du service de premier plan, refusés tant qu'il tourne.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final id in _foregroundServiceChannels) {
        try {
          await android.deleteNotificationChannel(id);
        } catch (_) {}
      }
    }
  }
}

/// Extrait un identifiant Matrix (@utilisateur:serveur) d'un texte, lien ou QR code.
String? parseUserId(String text) =>
    RegExp(r'@[a-z0-9.=_/+-]+:[A-Za-z0-9.-]+(?::\d+)?').firstMatch(text)?[0];

String shareableId(String userId) => '$kIdPrefix$userId';
