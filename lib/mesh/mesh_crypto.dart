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

  /// Calcule le secret partagé avec la clé publique d'un contact (ECDH X25519).
  Future<SecretKey> sharedSecretWith(Uint8List peerPublicKey) {
    final peer = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);
    return _algo.sharedSecretKey(keyPair: _keyPair, remotePublicKey: peer);
  }
}

/// Un message chiffré prêt à être relayé sur le maillage.
///
/// NOTE SUR LES MÉTADONNÉES EN CLAIR : [senderPublicKey] circule nécessairement en clair — le
/// destinataire en a besoin pour recalculer le secret ECDH avant même de pouvoir déchiffrer quoi
/// que ce soit. En revanche, la clé publique du DESTINATAIRE n'a plus besoin de voyager en clair :
/// on transmet [recipientHint] = SHA-256(clé publique du destinataire), que seul le téléphone
/// possédant cette clé peut reconnaître (en hachant la sienne et en comparant), exactement comme
/// avant, mais sans jamais révéler la clé elle-même à un relais ou à quelqu'un qui écoute le
/// Bluetooth en passant. Ça ne masque pas la liaison entre deux empreintes observées plusieurs
/// fois (toujours possible de recorréler « la même empreinte revient » dans le temps), mais ça
/// empêche de récupérer la clé publique réelle d'un destinataire juste en écoutant passivement —
/// utile si cette même clé est aussi montrée par QR à un moment ou un autre.
class MeshEnvelope {
  MeshEnvelope({
    required this.id,
    required this.senderPublicKey,
    required this.recipientHint,
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
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
        ttl: ttl - 1,
        createdAt: createdAt,
      );

  bool get expired =>
      ttl <= 0 || DateTime.now().difference(createdAt).inHours > maxAgeHours;
}

/// SHA-256 d'une clé publique, utilisé comme [MeshEnvelope.recipientHint] : permet à un téléphone
/// de reconnaître qu'une enveloppe lui est destinée (il hache sa propre clé et compare) sans que
/// la clé elle-même n'ait jamais à circuler en clair sur le canal Bluetooth.
Future<Uint8List> meshRecipientHint(Uint8List publicKey) async {
  final hash = await Sha256().hash(publicKey);
  return Uint8List.fromList(hash.bytes);
}

/// Chiffre un message en clair pour [recipientPublicKey], avec la clé privée de [identity].
Future<MeshEnvelope> meshEncrypt({
  required MeshIdentity identity,
  required Uint8List recipientPublicKey,
  required String plaintext,
}) async {
  final shared = await identity.sharedSecretWith(recipientPublicKey);
  final nonce = randomBytes(12);
  final algo = AesGcm.with256bits();
  final box = await algo.encrypt(
    utf8.encode(plaintext),
    secretKey: shared,
    nonce: nonce,
  );
  return MeshEnvelope(
    id: randomBytes(16),
    senderPublicKey: identity.publicKeyBytes,
    recipientHint: await meshRecipientHint(recipientPublicKey),
    nonce: nonce,
    ciphertext: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
    ttl: MeshEnvelope.maxTtl,
    createdAt: DateTime.now(),
  );
}

/// Tente de déchiffrer une enveloppe. Retourne null si elle n'est pas pour nous ou si
/// l'authentification échoue (altération, ou simplement adressée à un autre contact).
Future<String?> meshDecrypt({
  required MeshIdentity identity,
  required MeshEnvelope envelope,
}) async {
  try {
    final shared = await identity.sharedSecretWith(envelope.senderPublicKey);
    final algo = AesGcm.with256bits();
    final clear = await algo.decrypt(
      SecretBox(envelope.ciphertext, nonce: envelope.nonce, mac: Mac(envelope.mac)),
      secretKey: shared,
    );
    return utf8.decode(clear);
  } catch (_) {
    return null;
  }
}
