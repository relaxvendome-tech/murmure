// Tests de lib/media.dart::stripExifAndReencode — fonction pure (pas d'I/O disque, pas de
// permissions) ajoutée cette session pour l'envoi de photos. Vérifie les deux garanties que le
// threat model documenté en tête de media.dart exige : (1) toute entrée illisible est rejetée
// plutôt qu'envoyée telle quelle, (2) la sortie repart systématiquement d'un ExifData neuf et vide
// — jamais d'un clear() partiel dont la portée serait incertaine.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:murmure/media.dart';

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
}
