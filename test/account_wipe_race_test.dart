// Tests de lib/account.dart : Account.wipeGeneration / Account.wipedSince.
//
// Couvre le correctif pour la course documentée dans le commentaire de `Account.dbKey` : un appel
// à `CallOpsecStore.insert()`/`CrashLogStore.record()` déjà en vol au moment d'un effacement
// (`Account.wipeLocal`, panique ou suppression de compte) peut rester bloqué dans `Account.dbKey`
// pendant toute la durée de l'effacement, puis reprendre une fois celui-ci terminé et recréer la
// base avec la ligne qu'il s'apprêtait à écrire — alors que l'effacement est censé l'avoir fait
// disparaître. `Account.wipeGeneration` (capturé AVANT d'écrire) et `Account.wipedSince` (comparé
// APRÈS) détectent exactement cette situation ; voir ces deux fichiers pour l'usage réel.
//
// Testé ici directement contre `Account.wipeLocal` (pas un double) : chaque étape de cette
// méthode est déjà isolée dans son propre try/catch (voir son propre commentaire), donc elle se
// termine sans lever même sans aucun plugin disponible (path_provider, flutter_secure_storage…
// absents dans flutter_test) — seul l'incrément de génération, purement synchrone, nous
// intéresse ici. `Mesh._database`/`Mesh._resetGen` (mesh.dart) utilise déjà exactement le même
// principe pour une course voisine ; ce test couvre la version Account-level de ce même patron.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/account.dart';

void main() {
  group('Account.wipeGeneration / wipedSince', () {
    test('un effacement incrémente la génération d\'exactement 1', () async {
      final before = Account.wipeGeneration;
      await Account.wipeLocal(null);
      expect(Account.wipeGeneration, before + 1);
    });

    test('aucun effacement entre deux lectures : pas périmée', () {
      final gen = Account.wipeGeneration;
      // Rien d'autre ne tourne entre les deux lectures : la génération n'a aucune raison de
      // changer toute seule.
      expect(Account.wipedSince(gen), isFalse);
    });

    test('un effacement a eu lieu depuis la capture : périmée', () async {
      final gen = Account.wipeGeneration;
      await Account.wipeLocal(null);
      expect(Account.wipedSince(gen), isTrue);
    });

    test(
        'scénario de la course documentée : écriture qui capture AVANT un effacement qui '
        'survient PENDANT, détectée après coup',
        () async {
      // Reproduit l'ordre réel de CallOpsecStore.insert()/CrashLogStore.record() : capturer la
      // génération avant d'écrire, effectuer l'écriture (ici simulée par un simple travail async
      // sans rapport), puis comparer après. Dans le vrai code, l'effacement a lieu PENDANT
      // l'attente de `Account.dbKey()` (l'appel reste bloqué jusqu'à la fin de wipeLocal) — ce
      // test n'a pas besoin de reproduire ce blocage précis pour vérifier le mécanisme de
      // détection lui-même : seul l'ORDRE (capture, puis effacement, puis comparaison) compte.
      final capturedBeforeWrite = Account.wipeGeneration;
      await Future<void>.delayed(Duration.zero); // laisse une chance à un effacement concurrent
      await Account.wipeLocal(null); // l'effacement qui chevauche l'écriture en cours
      final stillStale = Account.wipedSince(capturedBeforeWrite);
      expect(stillStale, isTrue,
          reason: 'la ligne écrite par cette opération ne doit pas être considérée comme valide '
              'après un effacement qui a eu lieu pendant son exécution');
    });

    test('deux effacements successifs : chaque génération capturée avant devient périmée', () async {
      final gen0 = Account.wipeGeneration;
      await Account.wipeLocal(null);
      final gen1 = Account.wipeGeneration;
      expect(gen1, gen0 + 1);
      await Account.wipeLocal(null);
      final gen2 = Account.wipeGeneration;
      expect(gen2, gen1 + 1);
      expect(Account.wipedSince(gen0), isTrue);
      expect(Account.wipedSince(gen1), isTrue);
      expect(Account.wipedSince(gen2), isFalse);
    });
  });
}
