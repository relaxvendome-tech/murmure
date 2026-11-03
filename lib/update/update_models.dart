/// Manifeste de mise à jour, servi en JSON par l'infrastructure de CHAQUE déploiement de Murmure
/// (self-hosted, voir docs/UPDATES.md — aucune URL n'est codée en dur dans l'appli, voir
/// `NetConfig.updateManifestUrl`).
///
/// Format attendu (toutes les clés sont obligatoires sauf `notes` et `minSupportedVersionCode`) :
/// ```json
/// {
///   "versionCode": 8,
///   "versionName": "3.1.0",
///   "apkUrl": "https://exemple.invalid/updates/murmure-3.1.0.apk",
///   "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
///   "minSupportedVersionCode": 6,
///   "notes": "Correctif de sécurité : voir CHANGELOG."
/// }
/// ```
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.sha256,
    this.minSupportedVersionCode,
    this.notes,
  });

  final int versionCode;
  final String versionName;
  final Uri apkUrl;

  /// Empreinte SHA-256 de l'APK, en hexadécimal minuscule — vérifiée côté client AVANT de
  /// proposer l'installation (voir UpdateChecker.download). Ne remplace PAS la vérification de
  /// signature qu'Android fait lui-même à l'installation (seule vraie protection contre un APK
  /// signé par une clé différente) : protège contre un téléchargement corrompu ou modifié en
  /// transit AVANT même d'arriver à cette étape-là.
  final String sha256;

  /// Si renseigné et strictement supérieur au `versionCode` actuellement installé, la mise à
  /// jour est présentée comme obligatoire (voir UpdateCheckResult.mandatory) plutôt que
  /// facultative — utile pour forcer une mise à jour de sécurité critique.
  final int? minSupportedVersionCode;

  final String? notes;

  /// Lève [FormatException] avec un message précis plutôt que de laisser une exception de
  /// cast Dart peu lisible remonter jusqu'à l'utilisateur — un manifeste malformé (serveur mal
  /// configuré, ou ayant changé de format) doit produire un message exploitable, pas un crash.
  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final versionCode = json['versionCode'];
    if (versionCode is! int) {
      throw const FormatException('"versionCode" manquant ou non entier dans le manifeste');
    }
    final versionName = json['versionName'];
    if (versionName is! String || versionName.isEmpty) {
      throw const FormatException('"versionName" manquant dans le manifeste');
    }
    final apkUrlStr = json['apkUrl'];
    final apkUrl = apkUrlStr is String ? Uri.tryParse(apkUrlStr) : null;
    if (apkUrl == null || !apkUrl.hasScheme || apkUrl.scheme != 'https') {
      throw const FormatException('"apkUrl" manquant, invalide, ou pas en https:// dans le manifeste');
    }
    final sha256 = json['sha256'];
    if (sha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('"sha256" manquant ou mal formé (attendu : 64 caractères hex) dans le manifeste');
    }
    final minSupported = json['minSupportedVersionCode'];
    if (minSupported != null && minSupported is! int) {
      throw const FormatException('"minSupportedVersionCode" doit être un entier si présent');
    }
    final notes = json['notes'];
    if (notes != null && notes is! String) {
      throw const FormatException('"notes" doit être une chaîne si présent');
    }
    return UpdateManifest(
      versionCode: versionCode,
      versionName: versionName,
      apkUrl: apkUrl,
      sha256: sha256.toLowerCase(),
      minSupportedVersionCode: minSupported as int?,
      notes: notes as String?,
    );
  }
}

/// Résultat d'une vérification ayant trouvé une mise à jour disponible (voir UpdateChecker.check,
/// qui retourne `null` quand l'appli est déjà à jour).
class UpdateCheckResult {
  const UpdateCheckResult({required this.manifest, required this.mandatory});
  final UpdateManifest manifest;

  /// Vrai si `manifest.minSupportedVersionCode` dépasse la version actuellement installée —
  /// l'UI (voir ui/update_screen.dart) doit alors présenter la mise à jour comme nécessaire,
  /// jamais comme optionnelle, sans pour autant forcer quoi que ce soit automatiquement (Murmure
  /// ne télécharge et n'installe jamais sans une action explicite de l'utilisateur, voir
  /// docs/UPDATES.md).
  final bool mandatory;
}

/// Erreur de vérification/téléchargement de mise à jour, distincte d'une exception générique pour
/// que l'UI puisse afficher un message utilisateur direct plutôt qu'une trace technique.
class UpdateError implements Exception {
  const UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}
