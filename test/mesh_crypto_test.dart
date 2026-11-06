// Tests du cœur cryptographique du mode Bluetooth maillé (lib/mesh/mesh_crypto.dart).
//
// Choisi comme première pièce de code à tester (CI ne faisait tourner aucun test avant ce commit,
// voir .github/workflows/build.yml) car c'est du Dart pur et déterministe : aucun homeserver
// Matrix, aucun matériel Bluetooth réel, aucune I/O disque — tourne sans rien de plus que ce que
// `ubuntu-latest` fournit déjà pour `flutter analyze`. Les propriétés testées ici sont exactement
// celles dont dépend le threat model documenté en tête de mesh_crypto.dart : confidentialité
// persistante du cliquet, intégrité de l'enveloppe via l'AAD du GCM, et round-trip chiffrement/
// déchiffrement.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/mesh/mesh_crypto.dart';

/// Dart n'a pas d'opérateur `*` sur String (contrairement à Python) : on répète via `List.filled`.
String _repeat(String s, int n) => List.filled(n, s).join();

void main() {
  group('meshB64 / meshUnB64', () {
    test('round-trip préserve les octets exacts', () {
      final original = randomBytes(32);
      final encoded = meshB64(original);
      final decoded = meshUnB64(encoded);
      expect(decoded, equals(original));
    });

    test('ne produit jamais de padding "="', () {
      for (var len = 0; len < 8; len++) {
        final encoded = meshB64(randomBytes(len));
        expect(encoded.contains('='), isFalse);
      }
    });
  });

  group('randomBytes', () {
    test('retourne la longueur demandée', () {
      expect(randomBytes(16).length, 16);
      expect(randomBytes(32).length, 32);
      expect(randomBytes(0).length, 0);
    });

    test('deux appels successifs ne retournent pas la même chose', () {
      // Probabilité de collision sur 32 octets aléatoires : négligeable. Un échec ici indiquerait
      // un générateur cassé (ex: graine fixe), pas une malchance statistique.
      final a = randomBytes(32);
      final b = randomBytes(32);
      expect(a, isNot(equals(b)));
    });
  });

  group('meshRatchetStep', () {
    test('est déterministe : la même clé de chaîne produit toujours le même résultat', () async {
      final chainKey = randomBytes(32);
      final step1 = await meshRatchetStep(chainKey);
      final step2 = await meshRatchetStep(chainKey);
      expect(step1.messageKey, equals(step2.messageKey));
      expect(step1.nextChainKey, equals(step2.nextChainKey));
    });

    test('la clé de message et la clé de chaîne suivante sont distinctes', () async {
      final step = await meshRatchetStep(randomBytes(32));
      expect(step.messageKey, isNot(equals(step.nextChainKey)));
    });

    test('le cliquet avance réellement : deux crans successifs donnent des clés de message différentes',
        () async {
      final chainKey = randomBytes(32);
      final step1 = await meshRatchetStep(chainKey);
      final step2 = await meshRatchetStep(step1.nextChainKey);
      final step3 = await meshRatchetStep(step2.nextChainKey);
      expect(step1.messageKey, isNot(equals(step2.messageKey)));
      expect(step2.messageKey, isNot(equals(step3.messageKey)));
      expect(step1.messageKey, isNot(equals(step3.messageKey)));
    });
  });

  group('meshSendsOnChainA', () {
    test('est cohérent entre les deux points de vue : si A envoie sur la chaîne A face à B, '
        'alors B (vu de son propre point de vue) n\'envoie pas sur la chaîne A face à A', () {
      final keyLow = Uint8List.fromList([0x01, 0x02, 0x03]);
      final keyHigh = Uint8List.fromList([0x9, 0x02, 0x03]);
      final lowSendsOnA = meshSendsOnChainA(keyLow, keyHigh);
      final highSendsOnA = meshSendsOnChainA(keyHigh, keyLow);
      expect(lowSendsOnA, isTrue);
      expect(highSendsOnA, isFalse);
    });

    test('deux clés identiques (cas dégénéré) : résultat déterministe et stable', () {
      final key = randomBytes(32);
      expect(meshSendsOnChainA(key, key), meshSendsOnChainA(key, key));
    });

    test('compare par préfixe commun puis par longueur si l\'une est préfixe de l\'autre', () {
      final short = Uint8List.fromList([0x05, 0x05]);
      final long = Uint8List.fromList([0x05, 0x05, 0x01]);
      // Préfixe commun identique sur toute la longueur du plus court → la plus courte "gagne"
      // (myPublicKey.length <= peerPublicKey.length ⇒ true, voir meshSendsOnChainA).
      expect(meshSendsOnChainA(short, long), isTrue);
      expect(meshSendsOnChainA(long, short), isFalse);
    });
  });

  group('meshRecipientHint', () {
    test('est déterministe (SHA-256) et fait 32 octets', () async {
      final key = randomBytes(32);
      final hint1 = await meshRecipientHint(key);
      final hint2 = await meshRecipientHint(key);
      expect(hint1, equals(hint2));
      expect(hint1.length, 32);
    });

    test('deux clés différentes donnent des empreintes différentes', () async {
      final hintA = await meshRecipientHint(randomBytes(32));
      final hintB = await meshRecipientHint(randomBytes(32));
      expect(hintA, isNot(equals(hintB)));
    });
  });

  group('MeshEnvelope.serialize / deserialize', () {
    test('round-trip préserve tous les champs', () {
      final envelope = MeshEnvelope(
        id: randomBytes(16),
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        chainCounter: 42,
        nonce: randomBytes(12),
        ciphertext: Uint8List.fromList([1, 2, 3, 4, 5]),
        mac: randomBytes(16),
        ttl: 5,
        // Les secondes seulement : le format sérialisé tronque au niveau de la seconde
        // (_u32(createdAt.millisecondsSinceEpoch ~/ 1000)), donc on compare à la seconde près.
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000),
      );

      final bytes = envelope.serialize();
      final restored = MeshEnvelope.deserialize(bytes);

      expect(restored, isNotNull);
      expect(restored!.id, equals(envelope.id));
      expect(restored.senderPublicKey, equals(envelope.senderPublicKey));
      expect(restored.recipientHint, equals(envelope.recipientHint));
      expect(restored.chainCounter, envelope.chainCounter);
      expect(restored.nonce, equals(envelope.nonce));
      expect(restored.ciphertext, equals(envelope.ciphertext));
      expect(restored.mac, equals(envelope.mac));
      expect(restored.ttl, envelope.ttl);
      expect(restored.createdAt, equals(envelope.createdAt));
    });

    test('deserialize retourne null sur des octets tronqués plutôt que de planter', () {
      final envelope = MeshEnvelope(
        id: randomBytes(16),
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        chainCounter: 1,
        nonce: randomBytes(12),
        ciphertext: Uint8List.fromList([1, 2, 3]),
        mac: randomBytes(16),
        ttl: 3,
        createdAt: DateTime.now(),
      );
      final bytes = envelope.serialize();
      final truncated = bytes.sublist(0, bytes.length - 10);
      expect(MeshEnvelope.deserialize(truncated), isNull);
    });

    test('relayed() décrémente le ttl sans toucher au reste', () {
      final envelope = MeshEnvelope(
        id: randomBytes(16),
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        chainCounter: 7,
        nonce: randomBytes(12),
        ciphertext: Uint8List.fromList([9, 9]),
        mac: randomBytes(16),
        ttl: 4,
        createdAt: DateTime.now(),
      );
      final relayed = envelope.relayed();
      expect(relayed.ttl, 3);
      expect(relayed.id, equals(envelope.id));
      expect(relayed.chainCounter, envelope.chainCounter);
    });

    test('expired est vrai dès que ttl atteint 0', () {
      final envelope = MeshEnvelope(
        id: randomBytes(16),
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        chainCounter: 0,
        nonce: randomBytes(12),
        ciphertext: Uint8List.fromList([1]),
        mac: randomBytes(16),
        ttl: 0,
        createdAt: DateTime.now(),
      );
      expect(envelope.expired, isTrue);
    });

    test('expired est vrai au-delà de maxAgeHours même avec un ttl positif', () {
      final envelope = MeshEnvelope(
        id: randomBytes(16),
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        chainCounter: 0,
        nonce: randomBytes(12),
        ciphertext: Uint8List.fromList([1]),
        mac: randomBytes(16),
        ttl: 8,
        createdAt: DateTime.now().subtract(
            Duration(hours: MeshEnvelope.maxAgeHours + 1)),
      );
      expect(envelope.expired, isTrue);
    });
  });

  group('meshEncryptWithKey / meshDecryptWithKey', () {
    test('round-trip : déchiffre exactement le texte chiffré', () async {
      final messageKey = randomBytes(32);
      const plaintext = 'Rendez-vous place de la République, 18h.';

      final envelope = await meshEncryptWithKey(
        messageKey: messageKey,
        chainCounter: 3,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: plaintext,
      );

      final decrypted = await meshDecryptWithKey(messageKey: messageKey, envelope: envelope);
      expect(decrypted, plaintext);
    });

    test('échoue silencieusement (retourne null) avec la mauvaise clé', () async {
      final envelope = await meshEncryptWithKey(
        messageKey: randomBytes(32),
        chainCounter: 0,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: 'secret',
      );
      final decrypted =
          await meshDecryptWithKey(messageKey: randomBytes(32), envelope: envelope);
      expect(decrypted, isNull);
    });

    test(
        'un champ couvert par l\'AAD (chainCounter) altéré après chiffrement fait échouer le '
        'déchiffrement — c\'est la protection d\'intégrité documentée en tête de fichier '
        '(cas du relais malveillant réécrivant le compteur de cliquet)', () async {
      final messageKey = randomBytes(32);
      final envelope = await meshEncryptWithKey(
        messageKey: messageKey,
        chainCounter: 5,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: 'contenu sensible',
      );

      final tampered = MeshEnvelope(
        id: envelope.id,
        senderPublicKey: envelope.senderPublicKey,
        recipientHint: envelope.recipientHint,
        chainCounter: envelope.chainCounter + 1, // falsifié par un relais
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        mac: envelope.mac,
        ttl: envelope.ttl,
        createdAt: envelope.createdAt,
      );

      final decrypted = await meshDecryptWithKey(messageKey: messageKey, envelope: tampered);
      expect(decrypted, isNull);
    });

    test('un ciphertext altéré (texte modifié en transit) fait échouer le déchiffrement', () async {
      final messageKey = randomBytes(32);
      final envelope = await meshEncryptWithKey(
        messageKey: messageKey,
        chainCounter: 0,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: 'contenu original',
      );

      final flipped = Uint8List.fromList(envelope.ciphertext);
      flipped[0] ^= 0xFF;
      final tampered = MeshEnvelope(
        id: envelope.id,
        senderPublicKey: envelope.senderPublicKey,
        recipientHint: envelope.recipientHint,
        chainCounter: envelope.chainCounter,
        nonce: envelope.nonce,
        ciphertext: flipped,
        mac: envelope.mac,
        ttl: envelope.ttl,
        createdAt: envelope.createdAt,
      );

      final decrypted = await meshDecryptWithKey(messageKey: messageKey, envelope: tampered);
      expect(decrypted, isNull);
    });

    test('ttl n\'est volontairement PAS couvert par l\'AAD : le modifier ne casse pas le '
        'déchiffrement (compromis documenté : chaque relais doit pouvoir le décrémenter)',
        () async {
      final messageKey = randomBytes(32);
      const plaintext = 'message relayé plusieurs fois';
      final envelope = await meshEncryptWithKey(
        messageKey: messageKey,
        chainCounter: 0,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: plaintext,
      );

      final relayedTwice = envelope.relayed().relayed();
      expect(relayedTwice.ttl, envelope.ttl - 2);

      final decrypted = await meshDecryptWithKey(messageKey: messageKey, envelope: relayedTwice);
      expect(decrypted, plaintext);
    });
  });

  group('meshMaxPlaintextBytes / meshPlaintextFits', () {
    test('une enveloppe chiffrant exactement meshMaxPlaintextBytes tient dans '
        'meshMaxEnvelopeBytes une fois sérialisée', () async {
      final plaintext = _repeat('a', meshMaxPlaintextBytes);
      expect(utf8.encode(plaintext).length, meshMaxPlaintextBytes);
      expect(meshPlaintextFits(plaintext), isTrue);

      final envelope = await meshEncryptWithKey(
        messageKey: randomBytes(32),
        chainCounter: 0,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: plaintext,
      );
      expect(envelope.serialize().length, meshMaxEnvelopeBytes);
    });

    test('un seul octet de plus dépasse meshMaxEnvelopeBytes une fois sérialisée — exactement '
        'le cas que Mesh._tryExchange ignore silencieusement pour toujours (voir mesh.dart), '
        'd\'où la validation anticipée dans Mesh.queueMessage', () async {
      final plaintext = _repeat('a', meshMaxPlaintextBytes + 1);
      expect(meshPlaintextFits(plaintext), isFalse);

      final envelope = await meshEncryptWithKey(
        messageKey: randomBytes(32),
        chainCounter: 0,
        senderPublicKey: randomBytes(32),
        recipientHint: randomBytes(32),
        plaintext: plaintext,
      );
      expect(envelope.serialize().length, meshMaxEnvelopeBytes + 1);
    });

    test('compte les octets UTF-8, pas les caractères : un emoji multi-octets peut faire '
        'dépasser la limite avant même d\'atteindre meshMaxPlaintextBytes caractères', () {
      // '😀' (U+1F600) encode sur 4 octets en UTF-8 mais compte pour 2 "code units" UTF-16 /
      // caractères Dart — un comptage par caractère sous-estimerait la taille réelle transportée.
      final emojiOnly = _repeat('😀', meshMaxPlaintextBytes ~/ 4);
      expect(emojiOnly.length, lessThan(utf8.encode(emojiOnly).length));
      expect(meshPlaintextFits(emojiOnly), isTrue);
      expect(meshPlaintextFits('$emojiOnly😀😀😀😀'), isFalse);
    });
  });

  group('MeshIdentity + meshRatchetRoots (bout en bout ECDH)', () {
    test('deux identités dérivent le même secret partagé et les mêmes racines de cliquet,'
        ' chacune depuis son propre point de vue', () async {
      Future<List<int>> seedA(String _) async => randomBytes(32);
      Future<List<int>> seedB(String _) async => randomBytes(32);

      final alice = await MeshIdentity.loadOrCreate(seedA);
      final bob = await MeshIdentity.loadOrCreate(seedB);

      final sharedFromAlice = await alice.sharedSecretWith(bob.publicKeyBytes);
      final sharedFromBob = await bob.sharedSecretWith(alice.publicKeyBytes);

      final rootsFromAlice = await meshRatchetRoots(sharedFromAlice);
      final rootsFromBob = await meshRatchetRoots(sharedFromBob);

      expect(rootsFromAlice.$1, equals(rootsFromBob.$1));
      expect(rootsFromAlice.$2, equals(rootsFromBob.$2));
      expect(rootsFromAlice.$1, isNot(equals(rootsFromAlice.$2)));
    });
  });
}
