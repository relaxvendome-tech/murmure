import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'account.dart';
export 'account.dart' show KeystoreUnavailable;
import 'config.dart' show kRelockAfter;
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

  /// Au bout de ce nombre d'échecs de PIN consécutifs, le déverrouillage biométrique est coupé
  /// (clé `bio_enabled`) : quelqu'un qui devine le PIN n'a pas à pouvoir compter sur une biométrie
  /// laissée active ; il faut la réactiver depuis les réglages.
  static const bioMaxPinFailures = 3;
  static const minLength = 4;
  static const maxLength = 8;
  static const _kdfIterations = 120000;
  static const _kdfBits = 256;

  /// Trouvé en audit interne (revue croisée IA, confirmé en relisant la structure réelle des
  /// widgets) : [LockGate] (ui/lock_screens.dart) n'est qu'un simple widget sous `home:` de
  /// `MaterialApp` — PAS une frontière de navigation. Un `Navigator.push` fait depuis
  /// `murmureNavigatorKey` (voir main.dart) empile donc une nouvelle route PAR-DESSUS lui, quel
  /// que soit ce qu'il affiche à l'instant (écran de verrou/calculatrice OU l'appli réelle). Avant
  /// ce correctif, un appel entrant (`MurmureWebRTCDelegate.handleNewCall`, voir
  /// calls/services/call_manager.dart) poussait inconditionnellement `CallSessionScreen` ainsi :
  /// l'écran d'appel « Appel entrant… » s'affichait donc BY-PASSANT entièrement le PIN/la
  /// calculatrice, avec un bouton Décrocher donnant accès au micro sans aucun déverrouillage, et
  /// révélant l'identité réelle de l'appli même en mode discret — exactement la double faille
  /// (contrôle d'accès ET OPSEC) que ce verrou existe pour empêcher.
  ///
  /// Ce drapeau statique, maintenu par [LockGate] lui-même (jamais recalculé ailleurs), permet à
  /// du code hors de l'arbre de widgets (comme ce delegate d'appels, construit avant tout widget,
  /// voir main.dart) de savoir si l'appli est RÉELLEMENT déverrouillée à l'instant présent — pas
  /// seulement si un code existe (`AppLock.enabled()`, qui ne dit rien de l'état de session en
  /// cours).
  ///
  /// Trouvé en audit interne (contre-vérification croisée IA d'un correctif que je venais
  /// d'écrire, confirmé en relisant le code réel) : initialiser ce drapeau à `true` par défaut —
  /// pour ne jamais bloquer d'appel légitime quand aucun code n'est configuré — ouvrait une
  /// fenêtre d'échec OUVERT (fail-open) bien réelle : [LockGate.initState] lance `_init()` de
  /// façon asynchrone (lecture Keystore + calcul), et tant que cet `await` n'a pas abouti,
  /// `isUnlocked` reste à sa valeur de déclaration. Un appel entrant arrivant dans cette fenêtre
  /// — quelques millisecondes au tout premier lancement de l'appli — aurait donc poussé l'écran
  /// d'appel par-dessus un verrou dont l'état réel n'était pas encore connu, exactement le
  /// contournement que ce drapeau existe pour empêcher. `false` par défaut (échec FERMÉ) : le
  /// pire cas est un appel arrivant littéralement avant que l'appli n'ait fini de démarrer,
  /// traité comme un appel manqué — jamais un bypass du verrou. [LockGate._init] remet la bonne
  /// valeur dès qu'elle est connue, quelques instants plus tard.
  ///
  /// Trouvé en audit interne (contournement du verrou par appel entrant) : ce drapeau restait à
  /// `true` pendant TOUT le séjour en arrière-plan — [LockGate] ne le repassait à `false` qu'au
  /// retour au premier plan. Un appel entrant arrivant téléphone en poche, bien après
  /// [kRelockAfter], voyait donc encore l'appli « déverrouillée » et poussait l'écran d'appel
  /// par-dessus un verrou qui aurait dû être actif. [isUnlocked] est maintenant un getter qui
  /// renvoie `false` dès que l'appli est en arrière-plan depuis plus de [kRelockAfter]
  /// ([backgroundExpired], tenu à jour par [LockGate] via [markBackgrounded]/[markForeground]),
  /// quel que soit l'état de session mémorisé.
  static bool _sessionUnlocked = false;

  /// Heure murale du passage en arrière-plan (`AppLifecycleState.paused`), `null` au premier plan.
  static DateTime? _bgWall;

  /// Chronomètre MONOTONE démarré au passage en arrière-plan. Trouvé en audit interne
  /// (contournement du reverrouillage) : avec la seule heure murale, reculer l'horloge du
  /// téléphone pendant que l'appli est en arrière-plan rendait l'écart mesuré négatif ou minuscule,
  /// et l'appli se rouvrait sans code. Le `Stopwatch` Dart repose sur une horloge monotone que
  /// l'utilisateur ne peut pas régler. LIMITE : sur Android, cette horloge (CLOCK_MONOTONIC) ne
  /// progresse pas pendant la veille profonde ; l'heure murale couvre ce cas, et un recul d'horloge
  /// est détecté (écart négatif). Seul un recul d'horloge plus petit que la durée passée en veille
  /// profonde reste indétectable sans `SystemClock.elapsedRealtime()` (canal natif).
  static Stopwatch? _bgWatch;

  /// À appeler au passage en arrière-plan (`paused`). Maintenu exclusivement par [LockGate].
  static void markBackgrounded() {
    _bgWall = DateTime.now();
    _bgWatch = Stopwatch()..start();
  }

  /// À appeler au retour au premier plan (`resumed`) : renvoie [backgroundExpired] tel qu'il
  /// était à cet instant, puis oublie l'horodatage (un `resumed` sans `paused` préalable — volet
  /// de notifications, boîte de dialogue système — ne peut donc jamais reverrouiller sur la base
  /// d'un ancien horodatage).
  static bool markForeground() {
    final expired = backgroundExpired;
    _bgWall = null;
    _bgWatch = null;
    return expired;
  }

  /// Vrai si l'appli est en arrière-plan (depuis [markBackgrounded], jusqu'à [markForeground])
  /// depuis plus de [kRelockAfter] : heure murale négative (horloge reculée) OU au-delà du délai,
  /// OU chronomètre monotone au-delà du délai.
  static bool get backgroundExpired {
    final wall = _bgWall;
    if (wall == null) return false;
    final elapsedWall = DateTime.now().difference(wall);
    if (elapsedWall.isNegative || elapsedWall > kRelockAfter) return true;
    final watch = _bgWatch;
    return watch != null && watch.elapsed > kRelockAfter;
  }

  static bool get isUnlocked => !backgroundExpired && _sessionUnlocked;

  /// État de session (déverrouillé ou non), fixé par [LockGate] uniquement.
  static set isUnlocked(bool value) => _sessionUnlocked = value;

  /// Vrai quand le contenu doit être masqué par un écran opaque (appli en `inactive`/`hidden`/
  /// arrière-plan alors qu'un code est actif). Tenu par [LockGate], dessiné par-dessus TOUTES les
  /// routes par `MaterialApp.builder` (main.dart).
  static final ValueNotifier<bool> obscured = ValueNotifier<bool>(false);

  /// Dernière valeur connue de [enabled] (mise à jour à chaque lecture/écriture du code), pour que
  /// [LockGate] puisse masquer le contenu de façon synchrone au retour au premier plan sans
  /// attendre une lecture Keystore.
  static bool lastKnownEnabled = false;

  /// Un code est-il configuré ? Échec FERMÉ sur panne Keystore : si `pin_hash` est lu `null`
  /// alors que le marqueur fichier [Account.kLockOnMarker] (créé par [setPin], supprimé par
  /// [disable] et par l'effacement) existe, la valeur est illisible et non absente — on lève
  /// [KeystoreUnavailable] au lieu de renvoyer `false`, qui aurait ouvert l'appli sans code (voir
  /// [KeystoreUnavailable] pour le comportement vérifié de flutter_secure_storage).
  static Future<bool> enabled() async {
    final h = await Account.read('pin_hash');
    if (h == null) {
      if (await lockMarkerPresent() &&
          !await Account.markerExists(Account.kWipePendingMarker, onError: false)) {
        lastKnownEnabled = true;
        throw const KeystoreUnavailable();
      }
      lastKnownEnabled = false;
      return false;
    }
    // Rattrapage des installations antérieures au marqueur (ou d'un [setPin] interrompu).
    try {
      await Account.setMarker(Account.kLockOnMarker);
    } catch (_) {}
    lastKnownEnabled = true;
    return true;
  }

  /// Le marqueur fichier « code configuré » existe (lecture hors Keystore ; `true` si illisible).
  static Future<bool> lockMarkerPresent() => Account.markerExists(Account.kLockOnMarker);

  /// Mode discret (calculatrice) actif ? Même principe qu'[enabled] avec le marqueur
  /// [Account.kCalcOnMarker] : lu `null` alors que le marqueur existe => considéré ACTIF (montrer
  /// la calculatrice ne révèle rien ; montrer l'écran Murmure à la place trahirait l'appli).
  static Future<bool> calcMode() async {
    final v = await Account.read('calc_mode');
    if (v == '1') {
      try {
        await Account.setMarker(Account.kCalcOnMarker);
      } catch (_) {}
      return true;
    }
    if (v == null) return Account.markerExists(Account.kCalcOnMarker);
    return false;
  }

  /// Active/désactive le mode discret. Activation : réglage puis marqueur ; désactivation :
  /// marqueur d'abord (une interruption laisse au pire le mode actif, jamais l'inverse).
  static Future<void> setCalcMode(bool on) async {
    if (on) {
      await Account.write('calc_mode', '1');
      await Account.setMarker(Account.kCalcOnMarker);
    } else {
      await Account.clearMarker(Account.kCalcOnMarker);
      await Account.write('calc_mode', '0');
    }
  }

  static Future<bool> hasDuress() async => (await Account.read('duress_hash')) != null;

  /// Sel PBKDF2. Trouvé en audit interne : il était RECRÉÉ dès qu'il était lu `null` — or une
  /// panne Keystore fait lire `null` sans exception (voir [KeystoreUnavailable]) ; le nouveau sel,
  /// écrit dans le stockage de repli, écrasait le vrai au lancement suivant et rendait le code
  /// définitivement invalide (puis effacement après [maxFailures] essais « faux »). Il n'est
  /// désormais créé que par [setPin] (`create: true`), et seulement si aucun code n'est connu ;
  /// sinon [KeystoreUnavailable] est levée AVANT tout comptage d'échec.
  static Future<String> _salt({bool create = false}) async {
    final s = await Account.read('pin_salt');
    if (s != null) return s;
    if (!create || await lockMarkerPresent()) throw const KeystoreUnavailable();
    final fresh = meshB64(randomBytes(16));
    await Account.write('pin_salt', fresh);
    return fresh;
  }

  /// Dérivation PBKDF2-SHA256 (120 000 itérations, 256 bits) exécutée dans un isolat séparé :
  /// l'implémentation pure Dart du paquet `cryptography` bloquait sinon le thread UI (gel visible
  /// de l'écran de verrou à chaque saisie). Résultat strictement identique à l'ancien calcul fait
  /// sur le thread principal (mêmes paramètres, même sel décodé, même encodage [meshB64]) : les
  /// codes déjà enregistrés restent valides. La closure ne capture que des valeurs simples
  /// (String, List<int>), transférables entre isolats.
  static Future<String> _hash(String pin, String salt) async {
    final List<int> saltBytes = List<int>.of(meshUnB64(salt));
    final bytes = await Isolate.run<List<int>>(() => _derive(pin, saltBytes));
    return meshB64(bytes);
  }

  static Future<List<int>> _derive(String pin, List<int> salt) async {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _kdfIterations, bits: _kdfBits);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return List<int>.of(await key.extractBytes());
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
    await Account.write('pin_hash', await _hash(pin, await _salt(create: true)));
    await Account.write('pin_fails', '0');
    // Marqueur APRÈS l'empreinte : s'il ne peut pas être créé, on annule (sans marqueur, une panne
    // Keystore ouvrirait l'appli sans code). Une interruption entre les deux est rattrapée par
    // [enabled], qui recrée le marqueur dès qu'il lit l'empreinte.
    try {
      await Account.setMarker(Account.kLockOnMarker);
    } catch (_) {
      try {
        await Account.delete('pin_hash');
      } catch (_) {}
      rethrow;
    }
    lastKnownEnabled = true;
  }

  /// Remet le compteur d'échecs à zéro (déverrouillage biométrique réussi). Best-effort.
  static Future<void> resetFailures() async {
    try {
      await Account.write('pin_fails', '0');
    } catch (_) {}
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
    // Marqueur EN PREMIER : une interruption ensuite laisse `pin_hash` présent (le code reste
    // actif et le marqueur est recréé par [enabled]) ; l'ordre inverse laisserait un marqueur sans
    // empreinte, donc un verrou impossible à ouvrir.
    await Account.clearMarker(Account.kLockOnMarker);
    for (final k in ['pin_hash', 'duress_hash', 'pin_fails', 'bio_enabled']) {
      await Account.delete(k);
    }
    lastKnownEnabled = false;
  }

  static Future<int> remaining() async =>
      maxFailures - (int.tryParse(await Account.read('pin_fails') ?? '0') ?? 0);

  /// Compare un code aux codes enregistrés SANS compter d'échec. N'est plus utilisé pour
  /// déverrouiller : le mode calculatrice passe par [check] (et compte donc les échecs) depuis
  /// qu'une calculatrice affichée sous le nom « Murmure » ne cache plus qu'il s'agit d'un verrou —
  /// voir ui/calculator_lock_screen.dart, où seule une saisie ayant la forme d'un code (4 à 8
  /// chiffres réellement tapés, sans opérateur) est testée, un calcul anodin ne consommant jamais
  /// de tentative. À réserver à des comparaisons hors déverrouillage (aucun appelant actuel).
  static Future<PinResult> classify(String pin) async {
    final h = await _hash(pin, await _salt());
    final duressHash = await Account.read('duress_hash');
    final pinHash = await Account.read('pin_hash');
    if (_duressActive(duressHash, pinHash) && _same(h, duressHash!)) return PinResult.duress;
    if (pinHash != null && _same(h, pinHash)) return PinResult.ok;
    return PinResult.wrong;
  }

  /// Compare un code ET compte les échecs. Utilisé par l'écran de verrou classique (PinScreen)
  /// et par le mode calculatrice (voir [classify]).
  ///
  /// Lève [KeystoreUnavailable] (sans compter d'échec) si le sel ou l'empreinte est illisible :
  /// un code juste ne doit jamais être compté faux à cause d'une panne Keystore.
  static Future<PinResult> check(String pin) async {
    final salt = await _salt();
    final h = await _hash(pin, salt);
    final pinHash = await Account.read('pin_hash');
    if (pinHash == null) {
      if (await lockMarkerPresent()) throw const KeystoreUnavailable();
      return PinResult.wrong; // aucun code configuré : rien à comparer, aucun échec compté
    }
    final duressHash = await Account.read('duress_hash');
    // Le code de contrainte est testé en premier et de la même façon : même durée de calcul.
    if (_duressActive(duressHash, pinHash) && _same(h, duressHash!)) return PinResult.duress;
    if (_same(h, pinHash)) {
      await Account.write('pin_fails', '0');
      return PinResult.ok;
    }
    final fails = maxFailures - await remaining() + 1;
    await Account.write('pin_fails', '$fails');
    if (fails >= bioMaxPinFailures) await Account.delete('bio_enabled');
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
