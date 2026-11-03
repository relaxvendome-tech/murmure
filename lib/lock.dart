import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'account.dart';
import 'mesh/mesh_crypto.dart' show meshB64, meshUnB64, randomBytes;

/// Résultat de la saisie d'un code.
enum PinResult {
  /// Bon code : l'appli s'ouvre.
  ok,

  /// Code de contrainte : tout est effacé et l'appli s'ouvre comme neuve.
  duress,

  /// Mauvais code.
  wrong,

  /// Trop d'erreurs : tout est effacé.
  exhausted,
}

/// Verrou de l'appli par code PIN, avec un code de contrainte optionnel.
///
/// Les codes ne sont jamais stockés : seule une empreinte PBKDF2-SHA256 salée est gardée dans
/// le Keystore Android (via flutter_secure_storage). Sous la contrainte (contrôle, arrestation),
/// donner le code de contrainte efface clés, messages et médias, puis ouvre une appli vierge,
/// indiscernable d'une installation neuve.
///
/// La clé SQLCipher des bases locales N'EST PAS dérivée du PIN : elle est aléatoire, générée une
/// fois et gardée dans le Keystore (voir [Account.dbKey]). Un PIN à 4 chiffres ferait une clé de
/// chiffrement de base de données trivialement faible même avec PBKDF2 ; la séparation signifie
/// aussi qu'un effacement du Keystore (duress) rend la base illisible instantanément, sans avoir
/// à la réécrire.
class AppLock {
  static const maxFailures = 10;
  static const minLength = 4;
  static const maxLength = 8;
  static final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);

  static Future<bool> enabled() async => (await Account.read('pin_hash')) != null;
  static Future<bool> hasDuress() async => (await Account.read('duress_hash')) != null;

  static Future<String> _salt() async {
    var s = await Account.read('pin_salt');
    if (s == null) {
      s = meshB64(randomBytes(16));
      await Account.write('pin_salt', s);
    }
    return s;
  }

  static Future<String> _hash(String pin, String salt) async {
    final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: meshUnB64(salt));
    return meshB64(await key.extractBytes());
  }

  /// Comparaison en temps constant (ne révèle pas le nombre de caractères corrects).
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static bool valid(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  static Future<void> setPin(String pin) async {
    await Account.write('pin_hash', await _hash(pin, await _salt()));
    await Account.write('pin_fails', '0');
  }

  /// Le code de contrainte doit différer du code normal (vérifié par l'appelant).
  static Future<void> setDuress(String pin) async =>
      Account.write('duress_hash', await _hash(pin, await _salt()));

  /// Définit [pin] comme code de contrainte, mais seulement s'il diffère du code normal déjà
  /// enregistré — retourne `false` sans rien écrire si ce n'est pas le cas (l'appelant doit alors
  /// montrer une erreur, voir `ui/lock_screens.dart`).
  ///
  /// Trouvé en audit interne : l'appelant faisait jusqu'ici `AppLock.classify(pin)` (une dérivation
  /// PBKDF2-SHA256 à 120 000 itérations pour comparer au code normal) PUIS, si différent,
  /// `AppLock.setDuress(pin)` — qui recalculait la MÊME dérivation PBKDF2 depuis zéro pour le même
  /// `pin`/sel, alors que le résultat du premier calcul était déjà disponible et jeté. Deux
  /// dérivations coûteuses (délibérément lentes, c'est tout l'intérêt de PBKDF2) pour une seule
  /// action utilisateur, sur le thread où tourne l'interface — un gaspillage de calcul redondant,
  /// pas seulement un ralentissement de principe. Cette méthode fait le calcul une seule fois et
  /// réutilise directement son résultat pour l'écriture.
  static Future<bool> trySetDuress(String pin) async {
    final salt = await _salt();
    final h = await _hash(pin, salt);
    final pinHash = await Account.read('pin_hash');
    if (pinHash != null && _same(h, pinHash)) return false;
    await Account.write('duress_hash', h);
    return true;
  }

  static Future<void> removeDuress() => Account.delete('duress_hash');

  static Future<void> disable() async {
    for (final k in ['pin_hash', 'duress_hash', 'pin_fails']) {
      await Account.delete(k);
    }
  }

  static Future<int> remaining() async =>
      maxFailures - (int.tryParse(await Account.read('pin_fails') ?? '0') ?? 0);

  /// Compare un code aux codes enregistrés SANS compter d'échec (écran de réglage, et
  /// mode calculatrice — voir ui/calculator_lock_screen.dart : un calcul anodin ne doit
  /// jamais consommer une tentative).
  static Future<PinResult> classify(String pin) async {
    final h = await _hash(pin, await _salt());
    final duressHash = await Account.read('duress_hash');
    final pinHash = await Account.read('pin_hash');
    if (_duressActive(duressHash, pinHash) && _same(h, duressHash!)) return PinResult.duress;
    if (pinHash != null && _same(h, pinHash)) return PinResult.ok;
    return PinResult.wrong;
  }

  /// Compare un code ET compte les échecs. Utilisé uniquement par l'écran de verrou classique
  /// (PinScreen), jamais par le mode calculatrice.
  static Future<PinResult> check(String pin) async {
    final salt = await _salt();
    final h = await _hash(pin, salt);
    final pinHash = await Account.read('pin_hash');
    final duressHash = await Account.read('duress_hash');
    // Le code de contrainte est testé en premier et de la même façon : même durée de calcul.
    if (_duressActive(duressHash, pinHash) && _same(h, duressHash!)) return PinResult.duress;
    if (pinHash != null && _same(h, pinHash)) {
      await Account.write('pin_fails', '0');
      return PinResult.ok;
    }
    final fails = maxFailures - await remaining() + 1;
    await Account.write('pin_fails', '$fails');
    return fails >= maxFailures ? PinResult.exhausted : PinResult.wrong;
  }

  /// Garde-fou défensif (en plus de la vérification faite à la création, voir [PinScreen] /
  /// `ui/lock_screens.dart`) : si jamais les empreintes du code normal et du code de contrainte
  /// se retrouvaient identiques — un état qu'un bug antérieur de l'écran de réglage permettait de
  /// créer, corrigé séparément, mais qui pourrait en théorie se reproduire par une autre voie —
  /// on ignore purement et simplement le code de contrainte plutôt que de risquer qu'un
  /// déverrouillage normal, parfaitement légitime, soit pris pour un déclenchement de contrainte
  /// et efface tout sans avertissement. Mieux vaut un code de contrainte silencieusement inerte
  /// qu'un effacement accidentel et irréversible des données de quelqu'un.
  static bool _duressActive(String? duressHash, String? pinHash) =>
      duressHash != null && duressHash != pinHash;
}
