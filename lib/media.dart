import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Gestion des fichiers temporaires de médias (images, vidéos déchiffrés pour lecture).
///
/// Threat model « saisie de téléphone » : un média déchiffré ne doit jamais rester en clair plus
/// longtemps que nécessaire, et jamais dans la galerie ou les Téléchargements. Chaque fichier est
/// écrasé avant suppression (la suppression seule laisse les données sur le disque flash jusqu'à
/// réécriture par le système — l'écrasement réduit la fenêtre d'exposition, sans garantie absolue
/// sur SSD avec wear-leveling, ce qu'aucune appli ne peut garantir).
///
/// À NE PAS OUBLIER quand l'envoi de médias sera implémenté (constaté en audit interne : aucun
/// sélecteur de photo/caméra n'existe encore dans ce dépôt — `lib/ui/rooms_screen.dart` n'envoie
/// que du texte, donc rien à corriger ici pour l'instant, mais ce point structurera cette
/// fonctionnalité dès sa conception plutôt qu'en correctif après coup) : une photo prise par
/// l'appareil embarque typiquement des métadonnées EXIF (coordonnées GPS, horodatage précis,
/// modèle de l'appareil) qui survivraient au chiffrement de bout en bout — le destinataire, ou
/// quiconque récupère le fichier déchiffré ensuite, les verrait en clair même si le transport est
/// chiffré. Toute fonctionnalité d'envoi de média devra dépouiller ces métadonnées AVANT
/// chiffrement/envoi, jamais s'appuyer sur le serveur ou le destinataire pour le faire.
class MediaCache {
  static Future<Directory> _dir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'murmure_media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Écrit des octets déchiffrés dans un fichier temporaire et retourne son chemin.
  /// L'appelant DOIT appeler [wipe] dès que la lecture est terminée.
  static Future<File> writeTemp(List<int> bytes, {required String extension}) async {
    final dir = await _dir();
    final name = '${DateTime.now().microsecondsSinceEpoch}.$extension';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Écrase puis supprime un fichier temporaire.
  static Future<void> wipe(File file) async {
    try {
      final len = await file.length();
      final sink = file.openWrite(mode: FileMode.write);
      const chunk = 64 * 1024;
      var remaining = len;
      final zeros = List<int>.filled(chunk, 0);
      while (remaining > 0) {
        final n = remaining < chunk ? remaining : chunk;
        sink.add(n == chunk ? zeros : zeros.sublist(0, n));
        remaining -= n;
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Le fichier peut déjà avoir disparu ; la suppression ci-dessous est la garantie finale.
    }
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Purge tout le cache média : appelée au démarrage (restes d'une lecture interrompue) et lors
  /// de l'effacement d'urgence (panic / contrainte / trop d'erreurs de PIN).
  static Future<void> purgeAll() async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) await wipe(entity);
    }
  }
}

/// Alias pour compatibilité avec le nom utilisé dans main.dart (`purgeMediaCache`).
Future<void> purgeMediaCache() => MediaCache.purgeAll();
