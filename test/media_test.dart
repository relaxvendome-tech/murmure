// Tests de lib/media.dart — stripExifAndReencode (fonction pure, pas d'I/O disque, pas de
// permissions) et MediaCache.wipe (I/O disque réelle sur fichiers temporaires, sans dépendance à
// un appareil Android : flutter_test exécute ces tests sur la VM Dart hôte).
//
// stripExifAndReencode : vérifie les deux garanties que le threat model documenté en tête de
// media.dart exige : (1) toute entrée illisible est rejetée plutôt qu'envoyée telle quelle, (2) la
// sortie repart systématiquement d'un ExifData neuf et vide — jamais d'un clear() partiel dont la
// portée serait incertaine.
//
// MediaCache.wipe : trouvé en audit interne (cette session) — `ChatScreen._pickAndSendImage`
// (lib/ui/rooms_screen.dart) appelait `File(picked.path).delete()` sur la copie en clair laissée
// par `image_picker` (avant tout retrait d'EXIF), un simple `delete()` ne faisant que désindexer
// le fichier sans effacer son contenu de la mémoire flash — exactement le threat model documenté
// ci-dessous (écrasement à zéro avant suppression) que [wipe] existe déjà pour couvrir, mais
// n'était jusqu'ici appliqué qu'aux fichiers du répertoire `murmure_media`. Corrigé en appelant
// [wipe] à la place. [wipe] supprimant toujours le fichier en fin de traitement, son contenu
// post-écrasement n'est pas observable depuis l'extérieur ; ces tests vérifient plutôt que
// l'écrasement par blocs de 64 Ko ne lève jamais et supprime bien le fichier, y compris aux
// tailles limites de son découpage, et qu'il ne lève pas non plus sur un fichier déjà absent
// (chemin "best-effort" documenté à l'appel).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:murmure/media.dart';
import 'package:path/path.dart' as p;

void main() {
  group('stripExifAndReencode', () {
    test('lève FormatException sur des octets qui ne sont pas une image', () {
      final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i));
      expect(() => stripExifAndReencode(garbage), throwsFormatException);
    });

    test('lève FormatException sur un buffer vide', () {
      expect(() => stripExifAndReencode(Uint8List(0)), throwsFormatException);
    });

    test('la sortie est un JPEG valide et redécodable, quel que soit le format d\'entrée', () {
      // Image source encodée en PNG (pas JPEG) : vérifie que stripExifAndReencode réencode
      // toujours en JPEG en sortie, conformément à sa documentation ("toujours réencodée en JPEG
      // quel que soit le format d'entrée reconnu").
      final source = img.Image(width: 20, height: 15);
      img.fill(source, color: img.ColorRgb8(10, 20, 30));
      final pngBytes = Uint8List.fromList(img.encodePng(source));

      final result = stripExifAndReencode(pngBytes);
      final redecoded = img.decodeJpg(result);

      expect(redecoded, isNotNull);
      expect(redecoded!.width, 20);
      expect(redecoded.height, 15);
    });

    test('la sortie a toujours un EXIF vide (ExifData neuf), que l\'entrée en ait eu ou non',
        () {
      final source = img.Image(width: 8, height: 8);
      img.fill(source, color: img.ColorRgb8(255, 0, 0));
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source));

      final result = stripExifAndReencode(jpegBytes);
      final redecoded = img.decodeJpg(result);

      expect(redecoded, isNotNull);
      expect(redecoded!.exif.isEmpty, isTrue);
    });

    test('préserve les dimensions et le contenu visuel (pas juste un fichier vide)', () {
      final source = img.Image(width: 50, height: 40);
      img.fill(source, color: img.ColorRgb8(5, 150, 5));
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source));

      final result = stripExifAndReencode(jpegBytes, quality: 95);
      final redecoded = img.decodeJpg(result);

      expect(redecoded, isNotNull);
      expect(redecoded!.width, 50);
      expect(redecoded.height, 40);
      // JPEG étant à pertes, on vérifie une couleur approximativement conservée plutôt qu'exacte.
      final pixel = redecoded.getPixel(25, 20);
      expect(pixel.r.toInt(), closeTo(5, 40));
      expect(pixel.g.toInt(), closeTo(150, 40));
      expect(pixel.b.toInt(), closeTo(5, 40));
    });

    test('un quality plus élevé produit un fichier au moins aussi volumineux sur une image '
        'avec du détail (sanity check sur le paramètre quality, pas une garantie stricte)', () {
      final source = img.Image(width: 60, height: 60);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 60; x++) {
          source.setPixelRgb(x, y, (x * 37) % 256, (y * 53) % 256, (x ^ y) % 256);
        }
      }
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source));

      final low = stripExifAndReencode(jpegBytes, quality: 20);
      final high = stripExifAndReencode(jpegBytes, quality: 95);

      expect(high.length, greaterThan(low.length));
    });
  });

  group('MediaCache.wipe', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('murmure_media_wipe_test_');
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    Future<File> writeFile(String name, int length) async {
      final file = File(p.join(tmpDir.path, name));
      // Octets non nuls partout, pour pouvoir distinguer sans ambiguïté un écrasement à zéro
      // d'un fichier qui serait resté intact.
      await file.writeAsBytes(List<int>.filled(length, 0xAB));
      return file;
    }

    // `wipe` supprime toujours le fichier en fin de traitement (son propre contenu post-
    // écrasement n'est donc plus observable depuis l'appelant, par construction — le vérifier
    // demanderait d'instrumenter l'implémentation elle-même). Ce que ces tests vérifient : que
    // l'écrasement par blocs de 64 Ko ne lève jamais et ne laisse jamais le fichier derrière lui,
    // y compris aux tailles limites de son découpage (0, strictement moins d'un bloc, exactement
    // un bloc, plusieurs blocs plus un reste) — une erreur de comptage dans cette boucle (boucle
    // infinie, ou exception sur `sublist`) se manifesterait ici par un test qui échoue ou qui ne
    // termine jamais, jamais par un faux positif silencieux.
    test('supprime un fichier plus petit qu\'un bloc (64 Ko)', () async {
      final file = await writeFile('small.bin', 100);
      await expectLater(MediaCache.wipe(file), completes);
      expect(await file.exists(), isFalse);
    });

    test('ne lève pas sur un fichier exactement à la taille d\'un bloc (64 Ko)', () async {
      final file = await writeFile('exact_chunk.bin', 64 * 1024);
      await expectLater(MediaCache.wipe(file), completes);
      expect(await file.exists(), isFalse);
    });

    test('ne lève pas sur un fichier à cheval sur plusieurs blocs', () async {
      final file = await writeFile('multi_chunk.bin', 64 * 1024 + 777);
      await expectLater(MediaCache.wipe(file), completes);
      expect(await file.exists(), isFalse);
    });

    test('ne lève pas sur un fichier vide', () async {
      final file = await writeFile('empty.bin', 0);
      await expectLater(MediaCache.wipe(file), completes);
      expect(await file.exists(), isFalse);
    });

    test('ne lève pas (best-effort) sur un fichier qui n\'existe pas', () async {
      final file = File(p.join(tmpDir.path, 'does_not_exist.bin'));
      expect(await file.exists(), isFalse);
      await expectLater(MediaCache.wipe(file), completes);
    });
  });
}
