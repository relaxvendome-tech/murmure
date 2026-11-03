import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network.dart';
import 'update_models.dart';

/// Vérification, téléchargement et installation des mises à jour — voir docs/UPDATES.md pour le
/// format du manifeste et la façon de déployer son propre serveur de mise à jour.
///
/// Trois garanties structurelles, toutes délibérées :
/// 1. Chaque requête réseau (manifeste ET APK) passe par `NetConfig.httpClient()` — exactement le
///    même client que le trafic Matrix, donc le même mode choisi par l'utilisateur (direct, Tor,
///    proxy SOCKS5). Une mise à jour ne doit jamais devenir le seul trafic de l'appli qui ignore
///    ce choix et révèle l'IP réelle.
/// 2. Rien ne se télécharge ni ne s'installe sans un appel explicite depuis l'UI (voir
///    ui/update_screen.dart) : pas de vérification silencieuse en arrière-plan, pas de téléchargement
///    automatique. Dans le contexte visé (téléphone pouvant être saisi), une mise à jour qui
///    déclenche seule du trafic réseau ou un écran d'installation serait une fuite d'OPSEC.
/// 3. L'APK téléchargé est vérifié par SHA-256 contre le manifeste AVANT d'être proposé à
///    l'installeur système — en plus de la vérification de signature qu'Android fait lui-même à
///    l'installation (seule protection réelle contre un APK signé par une clé différente de celle
///    déjà installée ; voir [install] et le commentaire de [UpdateManifest.sha256]).
class UpdateChecker {
  static const _channel = MethodChannel('fr.lansight.murmure/update');

  /// Lu côté natif (`PackageInfo.getLongVersionCode`/`versionCode`) plutôt que codé en dur côté
  /// Dart : c'est la seule source qui ne peut pas diverger de ce qui est réellement installé.
  static Future<int> currentVersionCode() async {
    final v = await _channel.invokeMethod<int>('currentVersionCode');
    if (v == null) {
      throw const UpdateError('Impossible de lire la version actuellement installée');
    }
    return v;
  }

  /// Retourne `null` si aucune mise à jour n'est configurée ([NetConfig.updateManifestUrl] vide)
  /// ou si l'appli est déjà à jour — jamais une erreur dans ces deux cas, qui sont des états
  /// normaux, pas des échecs.
  static Future<UpdateCheckResult?> check() async {
    final net = await NetConfig.load();
    final urlStr = net.updateManifestUrl;
    if (urlStr == null || urlStr.isEmpty) return null;
    final uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
      throw const UpdateError('URL de mise à jour invalide (doit être en https://)');
    }
    final client = await net.httpClient();
    try {
      final resp = await client.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw UpdateError('Le serveur de mise à jour a répondu ${resp.statusCode}');
      }
      Map<String, dynamic> json;
      try {
        json = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        throw const UpdateError('Réponse du serveur de mise à jour illisible (pas du JSON)');
      }
      final manifest = UpdateManifest.fromJson(json);
      final current = await currentVersionCode();
      if (manifest.versionCode <= current) return null; // déjà à jour
      final mandatory = manifest.minSupportedVersionCode != null && current < manifest.minSupportedVersionCode!;
      return UpdateCheckResult(manifest: manifest, mandatory: mandatory);
    } on FormatException catch (e) {
      throw UpdateError('Manifeste de mise à jour invalide : ${e.message}');
    } finally {
      client.close();
    }
  }

  /// Télécharge l'APK annoncé par [manifest] (via le même client réseau que [check]), vérifie son
  /// empreinte SHA-256, puis seulement si elle correspond, écrit le fichier à son emplacement
  /// final et le retourne. En cas d'empreinte différente, le fichier temporaire est supprimé et
  /// [UpdateError] est levée — ne laisse jamais un APK non vérifié en place, même pour inspection.
  static Future<File> download(UpdateManifest manifest, {void Function(double progress)? onProgress}) async {
    final net = await NetConfig.load();
    final client = await net.httpClient();
    try {
      final req = http.Request('GET', manifest.apkUrl);
      final streamed = await client.send(req);
      if (streamed.statusCode != 200) {
        throw UpdateError('Téléchargement de la mise à jour échoué (${streamed.statusCode})');
      }
      final total = streamed.contentLength;
      final received = <int>[];
      var sum = 0;
      await for (final chunk in streamed.stream) {
        received.addAll(chunk);
        sum += chunk.length;
        if (total != null && total > 0 && onProgress != null) {
          onProgress(sum / total);
        }
      }
      final bytes = received;
      final digest = await Sha256().hash(bytes);
      final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (hex != manifest.sha256) {
        throw UpdateError(
          'Empreinte de l\'APK téléchargé incorrecte (attendu ${manifest.sha256}, obtenu $hex) — '
          'téléchargement corrompu ou manifeste erroné. Installation refusée.',
        );
      }
      final dir = await getApplicationSupportDirectory();
      final updatesDir = Directory(p.join(dir.path, 'updates'));
      await updatesDir.create(recursive: true);
      final file = File(p.join(updatesDir.path, 'murmure-${manifest.versionCode}.apk'));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      client.close();
    }
  }

  /// Lance l'installeur système Android pour [apk] (voir MainActivity.kt : `FileProvider` +
  /// `Intent.ACTION_VIEW`). C'est Android, pas ce code, qui refuse l'installation si la signature
  /// de cet APK ne correspond pas à celle déjà installée — la vraie protection de dernier
  /// recours, indépendante de la vérification SHA-256 faite dans [download].
  static Future<void> install(File apk) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apk.path});
    } on PlatformException catch (e) {
      throw UpdateError('Impossible de lancer l\'installation : ${e.message}');
    }
  }
}
