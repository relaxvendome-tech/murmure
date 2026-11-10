import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Primitives cryptographiques du mode Bluetooth maillé.
///
/// Le mode Bluetooth est un canal SÉPARÉ du chiffrement Matrix (Olm/Megolm) : il sert quand le
/// réseau est coupé (brouillage, manifestation) et relaie les messages de proche en proche via
/// Bluetooth Low Energy, sans aucun serveur. Chaque message est chiffré de bout en bout pour son
/// destinataire ; les nœuds intermédiaires ne voient que du texte chiffré opaque et le relaient
/// à l'aveugle (store-and-forward), exactement comme décrit dans l'architecture validée : aucune
/// clé maîtresse ne permet de le déchiffrer, pas même l'administrateur de l'appli.
///
/// CONFIDENTIALITÉ PERSISTANTE (forward secrecy) : le secret ECDH X25519 entre deux identités
/// Bluetooth est statique (les deux parties gardent la même paire de clés tout le temps qu'elles
/// se connaissent). Avant cette revue, ce secret ECDH chiffrait DIRECTEMENT chaque message : vol
/// d'une graine d'identité (Account.seed('mesh_identity_seed')) = tous les messages passés ET
/// futurs de cette personne, pour toujours, redeviennent lisibles. On intercale maintenant un
/// cliquet symétrique à sens unique (voir [meshRatchetStep]) entre ce secret et les messages : la
/// clé ECDH n'amorce plus que deux chaînes de dérivation (une par sens), et chaque message avance
/// sa chaîne d'un cran avant d'être chiffré — remonter une clé de chaîne vers celles d'avant est
/// mathématiquement impossible (HMAC-SHA256 à sens unique). Donc : voler l'état courant d'une
/// conversation ne redonne accès qu'aux messages À VENIR sur cette chaîne, jamais à ceux déjà
/// passés. C'est le même principe que le cliquet symétrique de Signal/Briar (sans le second étage
/// — le ré-ajustement par un nouveau DH à chaque aller-retour — qui suppose une session suivie en
/// temps réel, incompatible avec des rencontres Bluetooth brèves et désordonnées).
///
/// LIMITE HONNÊTE RESTANTE : ceci protège le PASSÉ si l'état courant est volé (forward secrecy),
/// mais pas le FUTUR si l'identité Bluetooth long terme elle-même est volée : avec la graine
/// d'identité, quelqu'un peut toujours recalculer la racine ECDH avec un nouveau contact et
/// usurper cette identité dans de nouveaux échanges. Un vrai cliquet double (à la Signal) avec
/// réajustement DH résoudrait aussi ce point, mais demande une session interactive que le
/// Bluetooth opportuniste de Murmure n'offre pas.
///
/// NUANCE trouvée en audit interne sur l'affirmation « jamais à ceux déjà passés » ci-dessus :
/// elle est vraie pour tout rang de cliquet déjà franchi par la chaîne de réception ET effacé à
/// ce passage. Elle ne l'est PAS, par construction, pour les rangs SAUTÉS en attente de livraison
/// tardive (voir `ratchet_skipped` dans mesh.dart) : ces clés sont délibérément conservées — c'est
/// leur rôle, tolérer les messages qui arrivent dans le désordre — donc toujours récupérables si
/// l'appareil est saisi avant que le message correspondant n'arrive ou n'expire. Bornée dans le
/// temps (purge par âge alignée sur [MeshEnvelope.maxAgeHours], voir `_purgeExpired` dans
/// mesh.dart) et en nombre (`_maxSkippedPerPeer`), mais pas nulle : un compromis assumé entre
/// « tolérer le désordre du Bluetooth opportuniste » et « confidentialité persistante absolue »,
/// pas un oubli à corriger silencieusement.

String meshB64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List meshUnB64(String s) => base64Url.decode(base64Url.normalize(s));

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// Identité Bluetooth : paire de clés X25519 longue durée, utilisée pour l'échange de clé
/// (ECDH) avec un contact ajouté par QR. Distincte de l'identité Matrix (Ed25519/Curve25519,
/// gérée en interne par le SDK Matrix via libolm, voir le commentaire de main.dart) : le mode
/// Bluetooth fonctionne même sans compte Matrix.
class MeshIdentity {
  MeshIdentity._(this._keyPair, this.publicKeyBytes);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKeyBytes;

  static final _algo = X25519();

  static Future<MeshIdentity> loadOrCreate(Future<List<int>> Function(String) seedReader) async {
    // La graine privée est fournie par l'appelant (Account.seed), jamais lue ici directement,
    // pour garder toute lecture du Keystore centralisée dans account.dart.
    final seed = await seedReader('mesh_identity_seed');
    final keyPair = await _algo.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return MeshIdentity._(keyPair, Uint8List.fromList(pub.bytes));
  }

  /// Calcule le secret partagé avec la clé publique d'un contact (ECDH X25519). Ce secret ne sert
  /// plus jamais à chiffrer directement : il n'amorce que les deux chaînes du cliquet (voir
  /// [meshRatchetRoots]).
  Future<SecretKey> sharedSecretWith(Uint8List peerPublicKey) {
    final peer = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);
    return _algo.sharedSecretKey(keyPair: _keyPair, remotePublicKey: peer);
  }
}

// -----------------------------------------------------------------------------------------------
// Cliquet symétrique (forward secrecy) — voir la doc de fichier ci-dessus.
// -----------------------------------------------------------------------------------------------

final _hmac = Hmac.sha256();

/// Un cran du cliquet : à partir d'une clé de chaîne, produit la clé DE CE message et la clé de
/// chaîne SUIVANTE, par deux HMAC-SHA256 avec des libellés distincts (impossible de retrouver
/// l'une à partir de l'autre). L'appelant doit détruire [chainKey] après cet appel et ne garder
/// que [MeshRatchetStep.nextChainKey] — c'est cette destruction qui donne la confidentialité
/// persistante.
class MeshRatchetStep {
  const MeshRatchetStep(this.messageKey, this.nextChainKey);
  final Uint8List messageKey;
  final Uint8List nextChainKey;
}

Future<MeshRatchetStep> meshRatchetStep(Uint8List chainKey) async {
  final secret = SecretKey(chainKey);
  final msgMac = await _hmac.calculateMac(const [0x01], secretKey: secret);
  final nextMac = await _hmac.calculateMac(const [0x02], secretKey: secret);
  return MeshRatchetStep(Uint8List.fromList(msgMac.bytes), Uint8List.fromList(nextMac.bytes));
}

/// Dérive les deux chaînes de cliquet (A et B) à partir du secret ECDH statique d'une paire de
/// contacts. Le secret ECDH n'est plus utilisé que pour amorcer ces deux chaînes, une seule fois :
/// toute dérivation ultérieure passe par [meshRatchetStep], jamais par le secret lui-même.
Future<(Uint8List chainA, Uint8List chainB)> meshRatchetRoots(SecretKey shared) async {
  final bytes = SecretKey(await shared.extractBytes());
  final a = await _hmac.calculateMac(utf8.encode('murmure-mesh-ratchet-A'), secretKey: bytes);
  final b = await _hmac.calculateMac(utf8.encode('murmure-mesh-ratchet-B'), secretKey: bytes);
  return (Uint8List.fromList(a.bytes), Uint8List.fromList(b.bytes));
}

/// Avancée de la chaîne de RÉCEPTION calculée en mémoire, sans aucun effet de bord : voir
/// [meshPlanRecvAdvance]. Rien de ceci ne doit être persisté avant que [messageKey] ait permis
/// un déchiffrement AES-GCM réussi (voir `Mesh._commitRecvPlan` dans mesh.dart).
class MeshRecvPlan {
  const MeshRecvPlan({
    required this.messageKey,
    required this.newChainKey,
    required this.newNextCounter,
    required this.skippedKeys,
  });

  /// Clé du message au rang demandé.
  final Uint8List messageKey;

  /// Clé de chaîne qui remplacera l'actuelle (l'actuelle doit alors être effacée).
  final Uint8List newChainKey;

  /// Prochain rang attendu après application (rang demandé + 1).
  final int newNextCounter;

  /// Clés des rangs sautés (rang, clé de message), à mettre en réserve à l'application.
  final List<(int, Uint8List)> skippedKeys;
}

/// Calcule — sans rien modifier — ce que deviendrait la chaîne de réception ([chainKey], dont le
/// prochain rang attendu est [nextCounter]) pour obtenir la clé du rang [targetCounter]. Mêmes
/// primitives que [meshRatchetStep], appliquées [targetCounter] - [nextCounter] + 1 fois.
///
/// Retourne null si [targetCounter] < [nextCounter] (rang déjà franchi : sa clé ne se trouve plus
/// que dans la réserve des rangs sautés, s'il y est) ou si le saut dépasse [maxSkipAhead].
Future<MeshRecvPlan?> meshPlanRecvAdvance({
  required Uint8List chainKey,
  required int nextCounter,
  required int targetCounter,
  required int maxSkipAhead,
}) async {
  if (targetCounter < nextCounter) return null;
  final steps = targetCounter - nextCounter;
  if (steps > maxSkipAhead) return null;
  var ck = chainKey;
  final skipped = <(int, Uint8List)>[];
  late Uint8List wanted;
  for (var i = 0; i <= steps; i++) {
    final step = await meshRatchetStep(ck);
    if (i == steps) {
      wanted = step.messageKey;
    } else {
      skipped.add((nextCounter + i, step.messageKey));
    }
    ck = step.nextChainKey;
  }
  return MeshRecvPlan(
    messageKey: wanted,
    newChainKey: ck,
    newNextCounter: targetCounter + 1,
    skippedKeys: List.unmodifiable(skipped),
  );
}

/// Détermine, de façon déterministe et identique des deux côtés sans aucune négociation, laquelle
/// des deux chaînes (A ou B) [myPublicKey] utilise pour ENVOYER face à [peerPublicKey] (l'autre
/// sert à recevoir) : la clé publique la plus petite, au sens de la comparaison d'octets, envoie
/// sur A. Les deux parties calculent indépendamment le même résultat, chacune avec son propre
/// point de vue (« myPublicKey » étant la sienne), donc s'accordent toujours sur qui envoie où.
bool meshSendsOnChainA(Uint8List myPublicKey, Uint8List peerPublicKey) {
  final n = myPublicKey.length < peerPublicKey.length ? myPublicKey.length : peerPublicKey.length;
  for (var i = 0; i < n; i++) {
    if (myPublicKey[i] != peerPublicKey[i]) return myPublicKey[i] < peerPublicKey[i];
  }
  return myPublicKey.length <= peerPublicKey.length;
}

/// SHA-256 d'une clé publique, utilisé comme [MeshEnvelope.recipientHint] : permet à un téléphone
/// de reconnaître qu'une enveloppe lui est destinée (il hache sa propre clé et compare) sans que
/// la clé elle-même n'ait jamais à circuler en clair sur le canal Bluetooth.
Future<Uint8List> meshRecipientHint(Uint8List publicKey) async {
  final hash = await Sha256().hash(publicKey);
  return Uint8List.fromList(hash.bytes);
}

/// Clé de déduplication (table `seen`, et `outbox.id` des enveloppes de tiers) d'une enveloppe.
///
/// Corrigé (censure par copie forgée) : un relais se contentait de l'id (16 octets, en clair et
/// NON authentifié pour lui — il ne peut pas vérifier le GCM). Un attaquant qui voyait passer un
/// message pouvait donc en émettre une copie au même id mais au [recipientHint] modifié : chaque
/// relais qui recevait la copie d'abord marquait l'id « vu » et rejetait ensuite le VRAI message,
/// qui ne se propageait plus. Désormais :
/// - [forMe] faux (enveloppe à RELAYER) : clé = SHA-256(id ‖ recipientHint), 32 octets — une copie
///   au hint modifié a une autre clé et ne bloque plus l'original ;
/// - [forMe] vrai (enveloppe qui NOUS est destinée) : l'id seul (16 octets), écrit en base
///   uniquement après un déchiffrement authentifié réussi (voir `Mesh._handleIncomingLocked`).
/// Les longueurs différentes (16 vs 32) rendent toute collision entre les deux espaces impossible.
/// Fonction pure (aucune I/O), testée dans test/mesh_crypto_test.dart.
Future<Uint8List> meshSeenKey({
  required Uint8List id,
  required Uint8List recipientHint,
  required bool forMe,
}) async {
  if (forMe) return Uint8List.fromList(id);
  final hash = await Sha256().hash([...id, ...recipientHint]);
  return Uint8List.fromList(hash.bytes);
}

// -----------------------------------------------------------------------------------------------
// Enveloppe
// -----------------------------------------------------------------------------------------------

/// Un message chiffré prêt à être relayé sur le maillage.
///
/// NOTE SUR LES MÉTADONNÉES EN CLAIR : [senderPublicKey] circule nécessairement en clair — le
/// destinataire en a besoin pour recalculer le secret ECDH avant même de pouvoir déchiffrer quoi
/// que ce soit. En revanche, la clé publique du DESTINATAIRE n'a plus besoin de voyager en clair :
/// on transmet [recipientHint] = SHA-256(clé publique du destinataire). [chainCounter] (le rang du
/// message dans le cliquet, voir plus haut) circule aussi en clair : c'est un simple compteur, pas
/// une clé, et le destinataire en a besoin pour savoir combien de crans avancer.
class MeshEnvelope {
  MeshEnvelope({
    required this.id,
    required this.senderPublicKey,
    required this.recipientHint,
    required this.chainCounter,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    required this.ttl,
    required this.createdAt,
  });

  /// Identifiant aléatoire de 16 octets (déduplication lors du relais).
  final Uint8List id;
  final Uint8List senderPublicKey;

  /// SHA-256 de la clé publique du destinataire — jamais la clé elle-même (voir doc de classe).
  final Uint8List recipientHint;

  /// Rang de ce message dans le cliquet de son expéditeur (0, 1, 2…) — permet au destinataire de
  /// retrouver ou dériver la bonne clé de message, y compris si des messages arrivent dans le
  /// désordre (relais par plusieurs chemins) : voir [MeshEnvelope] et le cliquet plus haut.
  final int chainCounter;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  /// Nombre de sauts restants (décrémenté à chaque relais, détruit à 0).
  final int ttl;
  final DateTime createdAt;

  static const maxTtl = 8;
  static const maxAgeHours = 72;

  Uint8List serialize() {
    final b = BytesBuilder();
    b.add(id);
    b.add(senderPublicKey);
    b.add(recipientHint);
    b.add(_u32(chainCounter));
    b.add(nonce);
    b.add(_u16(ciphertext.length));
    b.add(ciphertext);
    b.add(mac);
    b.addByte(ttl);
    b.add(_u32(createdAt.millisecondsSinceEpoch ~/ 1000));
    return b.toBytes();
  }

  static Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.big);
  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

  static MeshEnvelope? deserialize(Uint8List data) {
    try {
      var off = 0;
      Uint8List take(int n) {
        final s = data.sublist(off, off + n);
        off += n;
        return s;
      }

      final id = take(16);
      final sender = take(32);
      final recipientHint = take(32);
      final chainCounter = ByteData.sublistView(take(4)).getUint32(0, Endian.big);
      final nonce = take(12);
      final ctLen = ByteData.sublistView(take(2)).getUint16(0, Endian.big);
      final ct = take(ctLen);
      final mac = take(16);
      final ttl = data[off];
      off += 1;
      final ts = ByteData.sublistView(take(4)).getUint32(0, Endian.big);
      return MeshEnvelope(
        id: id,
        senderPublicKey: sender,
        recipientHint: recipientHint,
        chainCounter: chainCounter,
        nonce: nonce,
        ciphertext: ct,
        mac: mac,
        ttl: ttl,
        createdAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      );
    } catch (_) {
      return null;
    }
  }

  MeshEnvelope relayed() => MeshEnvelope(
        id: id,
        senderPublicKey: senderPublicKey,
        recipientHint: recipientHint,
        chainCounter: chainCounter,
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
        ttl: ttl - 1,
        createdAt: createdAt,
      );

  bool get expired =>
      ttl <= 0 || DateTime.now().difference(createdAt).inHours > maxAgeHours;
}

/// Tolérance d'horloge entre téléphones pour un horodatage d'enveloppe dans le futur.
const Duration meshMaxClockSkew = Duration(minutes: 10);

/// Motif de rejet d'une enveloppe entrante, voir [meshValidateIncoming].
enum MeshEnvelopeRejection { futureTimestamp, ttlTooHigh, expired }

/// Validation d'une enveloppe reçue AVANT tout traitement (aucune écriture en base, aucun
/// déchiffrement) — contre l'inondation du maillage :
/// - [MeshEnvelope.createdAt] au-delà de `now + meshMaxClockSkew` : une date lointaine rendait
///   l'enveloppe indéfiniment « fraîche » (jamais purgée par âge) ;
/// - [MeshEnvelope.ttl] > [MeshEnvelope.maxTtl] : le ttl n'est pas couvert par l'AAD, un relais
///   pouvait le porter à 255 pour propager une enveloppe bien au-delà de la portée prévue ;
/// - enveloppe expirée (ttl épuisé ou plus vieille que [MeshEnvelope.maxAgeHours]).
/// Retourne null si l'enveloppe est acceptable.
MeshEnvelopeRejection? meshValidateIncoming(MeshEnvelope env, {DateTime? now}) {
  final t = now ?? DateTime.now();
  if (env.createdAt.isAfter(t.add(meshMaxClockSkew))) return MeshEnvelopeRejection.futureTimestamp;
  if (env.ttl > MeshEnvelope.maxTtl) return MeshEnvelopeRejection.ttlTooHigh;
  if (env.ttl <= 0 || t.difference(env.createdAt).inHours > MeshEnvelope.maxAgeHours) {
    return MeshEnvelopeRejection.expired;
  }
  return null;
}

/// Octets fixes d'une enveloppe sérialisée (voir [MeshEnvelope.serialize]), hors texte chiffré :
/// id (16) + clé publique expéditeur (32) + indice destinataire (32) + compteur de cliquet (4) +
/// nonce (12) + longueur du texte chiffré (2) + MAC (16) + ttl (1) + horodatage (4).
const int meshEnvelopeFixedOverheadBytes = 16 + 32 + 32 + 4 + 12 + 2 + 16 + 1 + 4; // = 119

/// Taille maximale d'une enveloppe sérialisée tolérée au moment du relais (voir
/// `Mesh._tryExchange` dans mesh.dart : `if (bytes.length > 512) continue;`), au-delà du MTU
/// négocié (517, soit 514 octets utiles, voir le commentaire de `_tryExchange`).
const int meshMaxEnvelopeBytes = 512;

/// Taille maximale, en octets APRÈS encodage UTF-8 (pas en nombre de caractères — un emoji ou un
/// accent composé peut occuper plusieurs octets), d'un texte en clair qui tient dans une seule
/// enveloppe mesh. Le chiffrement AES-GCM ne change pas la longueur (texte chiffré et texte en
/// clair font le même nombre d'octets ; seul le MAC, déjà compté dans [meshEnvelopeFixedOverheadBytes],
/// s'ajoute à part) : `meshMaxEnvelopeBytes - meshEnvelopeFixedOverheadBytes`.
///
/// Trouvé en audit interne : rien ne vérifiait cette limite avant la mise en file d'un message
/// (voir `Mesh.queueMessage` dans mesh.dart). Un texte plus long franchissait silencieusement
/// toutes les étapes jusqu'au relais, où `Mesh._tryExchange` l'ignorait (`continue`) À CHAQUE
/// tentative, pour toujours — un message que l'interface annonçait « mis en file » ne partait en
/// réalité jamais, sans qu'aucune erreur ne remonte à l'utilisateur. Pire : avant ce correctif,
/// `_queueMessageLocked` faisait déjà avancer le cliquet d'envoi (consommant un rang pour de bon,
/// voir mesh.dart:_nextSendKey) avant de découvrir que l'enveloppe ne pourrait jamais être
/// relayée — un rang de cliquet gaspillé pour un message mort-né. Validé maintenant AVANT toute
/// consommation de cliquet (voir `Mesh.queueMessage`), via [MeshMessageTooLongException].
const int meshMaxPlaintextBytes = meshMaxEnvelopeBytes - meshEnvelopeFixedOverheadBytes; // 393

/// Vrai si [plaintext], une fois encodé en UTF-8, tient dans une seule enveloppe mesh — voir
/// [meshMaxPlaintextBytes].
bool meshPlaintextFits(String plaintext) => utf8.encode(plaintext).length <= meshMaxPlaintextBytes;

/// Levée par `Mesh.queueMessage` (mesh.dart) quand [meshPlaintextFits] est faux pour le texte
/// fourni — l'appelant (voir ui/mesh_screen.dart) doit la montrer clairement à l'utilisateur
/// plutôt que de mettre en file un message qui ne sera jamais relayé (voir le commentaire de
/// [meshMaxPlaintextBytes]).
class MeshMessageTooLongException implements Exception {
  const MeshMessageTooLongException(this.maxBytes, this.actualBytes);
  final int maxBytes;
  final int actualBytes;

  @override
  String toString() =>
      'MeshMessageTooLongException: $actualBytes octets > $maxBytes octets max par enveloppe mesh';
}

/// Trouvé en audit interne : seul le TEXTE du message passait par l'AES-GCM — l'identifiant,
/// l'expéditeur, le [recipientHint], le rang de cliquet et l'horodatage voyageaient à côté, en
/// clair et SANS AUCUNE protection d'intégrité (le tag GCM n'authentifie que ce qu'on lui donne à
/// chiffrer, pas le reste de l'enveloppe). Un relais malveillant ne peut toujours pas lire ni
/// forger un message (il n'a pas la clé de message), mais pouvait altérer ces champs en clair sans
/// que personne ne s'en aperçoive. Le cas le plus sérieux : réécrire [MeshEnvelope.chainCounter]
/// avant de relayer. Le destinataire légitime calcule alors la clé de déchiffrement pour CE rang
/// falsifié (voir `_planRecvKey` dans mesh.dart) — l'authentification GCM échoue bien et le message
/// ne se déchiffre pas (pas de fuite de contenu), mais l'ancien `_recvKeyFor` avait quand même, au passage, fait
/// avancer et mis au rebut l'état du cliquet de réception jusqu'à ce rang falsifié. Un relais sur
/// le chemin d'un contact donné pouvait ainsi, sans jamais casser le chiffrement, pousser le
/// cliquet de réception du destinataire bien au-delà des messages réellement envoyés — rendant
/// irrécupérables (`counter < next`, « clé perdue pour de bon ») les prochains messages légitimes
/// de cet expéditeur dès qu'ils arriveraient par un chemin intact. Un déni de service ciblé sur la
/// confidentialité persistante elle-même, pas sur le contenu.
///
/// L'AAD du GCM lie maintenant ces champs à l'enveloppe : [id], [senderPublicKey],
/// [recipientHint], [chainCounter] et [createdAt] sont authentifiés (toute altération fait échouer
/// le déchiffrement, comme une altération du texte lui-même). ATTENTION — l'AAD seule ne
/// suffisait PAS à corriger le déni de service décrit ci-dessus, contrairement à ce qu'affirmait
/// une version précédente de ce commentaire : le cliquet de réception (et la table `seen`) était
/// modifié AVANT la vérification GCM, donc une enveloppe forgée (ou une fausse écriture GATT, qui
/// n'a même pas besoin d'altérer un vrai message) au compteur élevé détruisait quand même le
/// canal. Corrigé dans mesh.dart : la clé est d'abord calculée sans écriture
/// ([meshPlanRecvAdvance] / `Mesh._planRecvKey`), le déchiffrement l'authentifie, et seulement
/// en cas de succès l'état du cliquet est mis à jour en une transaction, puis l'id marqué `seen`.
///
/// [MeshEnvelope.ttl] est volontairement exclu de l'AAD : il DOIT rester modifiable par chaque
/// relais (décrémenté à chaque saut, voir [MeshEnvelope.relayed]). Le falsifier reste possible,
/// mais l'effet est borné : un ttl > [MeshEnvelope.maxTtl] est rejeté à la réception
/// ([meshValidateIncoming]) ; on peut seulement raccourcir ou prolonger (jusqu'à maxTtl) la
/// propagation d'un message, jamais lire ni forger son contenu, ni désynchroniser le cliquet.
Uint8List _envelopeAad({
  required Uint8List id,
  required Uint8List senderPublicKey,
  required Uint8List recipientHint,
  required int chainCounter,
  required DateTime createdAt,
}) {
  final b = BytesBuilder();
  b.add(id);
  b.add(senderPublicKey);
  b.add(recipientHint);
  b.add(Uint8List(4)..buffer.asByteData().setUint32(0, chainCounter, Endian.big));
  b.add(Uint8List(4)
    ..buffer.asByteData().setUint32(0, createdAt.millisecondsSinceEpoch ~/ 1000, Endian.big));
  return b.toBytes();
}

/// Chiffre un message en clair avec une clé de message déjà dérivée par le cliquet (voir
/// [meshRatchetStep]) — cette fonction ne fait plus d'ECDH ni de dérivation elle-même, c'est la
/// responsabilité de l'appelant (mesh.dart), qui seul sait où en est l'état du cliquet.
Future<MeshEnvelope> meshEncryptWithKey({
  required Uint8List messageKey,
  required int chainCounter,
  required Uint8List senderPublicKey,
  required Uint8List recipientHint,
  required String plaintext,
}) async {
  // Générés ICI, avant le chiffrement, plutôt que dans le constructeur de MeshEnvelope plus bas :
  // l'AAD doit porter sur les valeurs réellement authentifiées, pas sur des valeurs regénérées
  // séparément après coup (qui ne correspondraient plus à ce que [id]/[createdAt] finissent par
  // être sur l'enveloppe envoyée).
  final id = randomBytes(16);
  final createdAt = DateTime.now();
  final nonce = randomBytes(12);
  final algo = AesGcm.with256bits();
  final box = await algo.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(messageKey),
    nonce: nonce,
    aad: _envelopeAad(
      id: id,
      senderPublicKey: senderPublicKey,
      recipientHint: recipientHint,
      chainCounter: chainCounter,
      createdAt: createdAt,
    ),
  );
  return MeshEnvelope(
    id: id,
    senderPublicKey: senderPublicKey,
    recipientHint: recipientHint,
    chainCounter: chainCounter,
    nonce: nonce,
    ciphertext: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
    ttl: MeshEnvelope.maxTtl,
    createdAt: createdAt,
  );
}

/// Déchiffre une enveloppe avec une clé de message déjà calculée par le cliquet (voir
/// [meshPlanRecvAdvance] et `Mesh._planRecvKey` dans mesh.dart). Fonction pure : c'est son succès
/// qui autorise l'appelant à appliquer le plan du cliquet, jamais l'inverse. Retourne null si l'authentification échoue (altération du texte
/// OU des champs d'enveloppe couverts par l'AAD — voir [_envelopeAad] — ou mauvaise clé).
Future<String?> meshDecryptWithKey({
  required Uint8List messageKey,
  required MeshEnvelope envelope,
}) async {
  try {
    final algo = AesGcm.with256bits();
    final clear = await algo.decrypt(
      SecretBox(envelope.ciphertext, nonce: envelope.nonce, mac: Mac(envelope.mac)),
      secretKey: SecretKey(messageKey),
      aad: _envelopeAad(
        id: envelope.id,
        senderPublicKey: envelope.senderPublicKey,
        recipientHint: envelope.recipientHint,
        chainCounter: envelope.chainCounter,
        createdAt: envelope.createdAt,
      ),
    );
    return utf8.decode(clear);
  } catch (_) {
    return null;
  }
}
