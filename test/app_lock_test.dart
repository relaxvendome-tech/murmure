// Tests des parties pures de lib/lock.dart (AppLock.valid et constantes).
//
// NON testable sans modifier lib/ : setPin/classify/check/trySetDuress/remaining dépendent de
// `Account` (flutter_secure_storage, statique) ; la dérivation PBKDF2 (`_hash`), la comparaison en
// temps constant (`_same`) et `_duressActive` sont privées.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/lock.dart';

void main() {
  group('AppLock.valid', () {
    test('accepte 4 à 8 chiffres', () {
      for (var n = 4; n <= 8; n++) {
        expect(AppLock.valid('1' * n), isTrue, reason: '$n chiffres');
      }
      expect(AppLock.valid('0000'), isTrue);
    });

    test('refuse trop court ou trop long', () {
      expect(AppLock.valid(''), isFalse);
      expect(AppLock.valid('123'), isFalse);
      expect(AppLock.valid('123456789'), isFalse);
    });

    test('refuse tout caractère non numérique, espaces et retours à la ligne compris', () {
      expect(AppLock.valid('12a4'), isFalse);
      expect(AppLock.valid('12 34'), isFalse);
      expect(AppLock.valid('1234\n'), isFalse);
      expect(AppLock.valid('\n1234'), isFalse);
      expect(AppLock.valid('-1234'), isFalse);
      expect(AppLock.valid('１２３４'), isFalse); // chiffres pleine largeur
      expect(AppLock.valid('١٢٣٤'), isFalse); // chiffres arabo-indiens
    });
  });

  group('constantes', () {
    test('bornes cohérentes avec valid()', () {
      expect(AppLock.minLength, 4);
      expect(AppLock.maxLength, 8);
      expect(AppLock.valid('1' * AppLock.minLength), isTrue);
      expect(AppLock.valid('1' * (AppLock.minLength - 1)), isFalse);
      expect(AppLock.valid('1' * AppLock.maxLength), isTrue);
      expect(AppLock.valid('1' * (AppLock.maxLength + 1)), isFalse);
    });

    test('plafond d\'échecs strictement positif', () {
      expect(AppLock.maxFailures, 10);
    });

    test('isUnlocked vaut false par défaut (fail-closed)', () {
      expect(AppLock.isUnlocked, isFalse);
    });
  });

  group('PinResult', () {
    test('quatre issues distinctes', () {
      expect(PinResult.values.toSet(),
          {PinResult.ok, PinResult.duress, PinResult.wrong, PinResult.exhausted});
    });
  });
}
