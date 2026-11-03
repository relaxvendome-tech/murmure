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
/// (ECDH) avec un contact ajouté par QR. Distincte de l'identité Matrix (Ed25519/Curve25519
/// gérée par vodozemac) : le mode Bluetooth fonctionne même sans compte Matrix.
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

/// Trouvé en audit interne : seul le TEXTE du message passait par l'AES-GCM — l'identifiant,
/// l'expéditeur, le [recipientHint], le rang de cliquet et l'horodatage voyageaient à côté, en
/// clair et SANS AUCUNE protection d'intégrité (le tag GCM n'authentifie que ce qu'on lui donne à
/// chiffrer, pas le reste de l'enveloppe). Un relais malveillant ne peut toujours pas lire ni
/// forger un message (il n'a pas la clé de message), mais pouvait altérer ces champs en clair sans
/// que personne ne s'en aperçoive. Le cas le plus sérieux : réécrire [MeshEnvelope.chainCounter]
/// avant de relayer. Le destinataire légitime calcule alors la clé de déchiffrement pour CE rang
/// falsifié (voir `_recvKeyFor` dans mesh.dart) — l'authentification GCM échoue bien et le message
/// ne se déchiffre pas (pas de fuite de contenu), mais `_recvKeyFor` a quand même, au passage, fait
/// avancer et mis au rebut l'état du cliquet de réception jusqu'à ce rang falsifié. Un relais sur
/// le chemin d'un contact donné pouvait ainsi, sans jamais casser le chiffrement, pousser le
/// cliquet de réception du destinataire bien au-delà des messages réellement envoyés — rendant
/// irrécupérables (`counter < next`, « clé perdue pour de bon ») les prochains messages légitimes
/// de cet expéditeur dès qu'ils arriveraient par un chemin intact. Un déni de service ciblé sur la
/// confidentialité persistante elle-même, pas sur le contenu.
///
/// Corrigé en liant ces champs à l'enveloppe via l'« Associated Data » (AAD) du GCM : [id],
/// [senderPublicKey], [recipientHint], [chainCounter] et [createdAt] sont maintenant authentifiés
/// (toute altération fait échouer le déchiffrement, comme une altération du texte lui-même) —
/// SAUF [MeshEnvelope.ttl], volontairement exclu : il DOIT rester modifiable par chaque relais
/// (décrémenté à chaque saut, voir [MeshEnvelope.relayed]), l'inclure casserait l'authentification
/// dès le premier relais légitime. Falsifier le ttl reste possible (effet borné : raccourcir ou
/// prolonger la propagation d'un message déjà vu, jamais lire ni forger son contenu, ni désynchroniser
/// le cliquet d'un tiers), un compromis assumé plutôt qu'un oubli.
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

/// Déchiffre une enveloppe avec une clé de message déjà retrouvée par le cliquet (voir
/// mesh.dart:_MeshRatchetStore). Retourne null si l'authentification échoue (altération du texte
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
