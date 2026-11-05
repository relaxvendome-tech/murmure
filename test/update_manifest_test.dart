// Tests de UpdateManifest.fromJson (lib/update/update_models.dart) — fonction pure (aucune
// requête réseau, aucune I/O disque) qui valide le manifeste JSON servi par l'infrastructure de
// mise à jour self-hosted de CHAQUE déploiement (voir docs/UPDATES.md). Choisie comme deuxième
// zone de code pur à couvrir (après le cliquet mesh et l'EXIF, voir test/mesh_crypto_test.dart et
// test/media_test.dart) : ce fichier a déjà connu un vrai incident en production (4bebfb5 : champs
// texte du manifeste non échappés, JSON invalide) et reste le seul rempart avant que
// UpdateChecker.download() ne traite un fichier comme un APK fiable à installer — chaque règle de
// validation testée ici correspond à une garantie documentée dans le commentaire de classe de
// UpdateManifest.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/update/update_models.dart';

Map<String, dynamic> _validJson() => {
      'versionCode': 8,
      'versionName': '3.1.0',
      'apkUrl': 'https://exemple.invalid/updates/murmure-3.1.0.apk',
      'sha256': '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      'minSupportedVersionCode': 6,
      'notes': 'Correctif de sécurité : voir CHANGELOG.',
    };

void main() {
  group('UpdateManifest.fromJson — manifeste valide', () {
    test('accepte un manifeste complet et reporte tous les champs', () {
      final m = UpdateManifest.fromJson(_validJson());
      expect(m.versionCode, 8);
      expect(m.versionName, '3.1.0');
      expect(m.apkUrl, Uri.parse('https://exemple.invalid/updates/murmure-3.1.0.apk'));
      expect(m.sha256, '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08');
      expect(m.minSupportedVersionCode, 6);
      expect(m.notes, 'Correctif de sécurité : voir CHANGELOG.');
    });

    test('accepte un manifeste minimal sans les champs optionnels', () {
      final json = _validJson()
        ..remove('minSupportedVersionCode')
        ..remove('notes');
      final m = UpdateManifest.fromJson(json);
      expect(m.minSupportedVersionCode, isNull);
      expect(m.notes, isNull);
    });
  });

  group('UpdateManifest.fromJson — versionCode', () {
    test('rejette un versionCode absent', () {
      final json = _validJson()..remove('versionCode');
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette un versionCode qui n\'est pas un entier (ex. chaîne)', () {
      final json = _validJson()..['versionCode'] = '8';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });
  });

  group('UpdateManifest.fromJson — versionName', () {
    test('rejette un versionName absent', () {
      final json = _validJson()..remove('versionName');
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette un versionName vide', () {
      final json = _validJson()..['versionName'] = '';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });
  });

  group('UpdateManifest.fromJson — apkUrl', () {
    test('rejette une apkUrl absente', () {
      final json = _validJson()..remove('apkUrl');
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette une apkUrl en http:// (non chiffrée)', () {
      final json = _validJson()..['apkUrl'] = 'http://exemple.invalid/murmure.apk';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette une apkUrl sans schéma', () {
      final json = _validJson()..['apkUrl'] = 'exemple.invalid/murmure.apk';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });
  });

  group('UpdateManifest.fromJson — sha256', () {
    test('rejette un sha256 absent', () {
      final json = _validJson()..remove('sha256');
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette un sha256 trop court', () {
      final json = _validJson()..['sha256'] = '9f86d081';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette un sha256 contenant des caractères non hexadécimaux', () {
      // 64 caractères (la bonne longueur), mais 'g' n'est pas un chiffre hexadécimal.
      final json = _validJson()..['sha256'] = List.filled(64, 'g').join();
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('rejette un sha256 en majuscules (la regex n\'accepte que [0-9a-f])', () {
      final json = _validJson()
        ..['sha256'] = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'.toUpperCase();
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });
  });

  group('UpdateManifest.fromJson — champs optionnels mal typés', () {
    test('rejette un minSupportedVersionCode non entier quand présent', () {
      final json = _validJson()..['minSupportedVersionCode'] = '6';
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('accepte minSupportedVersionCode null explicite', () {
      final json = _validJson()..['minSupportedVersionCode'] = null;
      final m = UpdateManifest.fromJson(json);
      expect(m.minSupportedVersionCode, isNull);
    });

    test('rejette des notes non-chaîne quand présentes', () {
      final json = _validJson()..['notes'] = 42;
      expect(() => UpdateManifest.fromJson(json), throwsFormatException);
    });

    test('accepte des notes null explicites', () {
      final json = _validJson()..['notes'] = null;
      final m = UpdateManifest.fromJson(json);
      expect(m.notes, isNull);
    });
  });
}
