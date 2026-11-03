import 'package:flutter/material.dart';

/// Thème visuel de Murmure : sobre, lisible au soleil (manifestations, extérieur), et sans aucun
/// élément qui trahirait visuellement l'usage d'une messagerie chiffrée depuis l'écran verrouillé
/// (le mode calculatrice s'appuie sur ce même souci de discrétion).
///
/// Trouvé en audit interne en préparant cette passe visuelle : le thème définissait
/// `elevatedButtonTheme`, mais aucun écran de l'appli n'utilise `ElevatedButton` — tous utilisent
/// `FilledButton` (`lock_screens.dart`, `rooms_screen.dart`, `group_screen.dart`,
/// `onboarding_screen.dart`, `main.dart`). Ce réglage n'avait donc jamais eu le moindre effet
/// visible : chaque bouton principal de l'appli s'affichait avec le style par défaut de Material 3,
/// pas avec le padding/rayon voulus ici. Remplacé par `filledButtonTheme`, qui s'applique
/// réellement partout où l'appli en a besoin.
ThemeData murmureTheme({required Brightness brightness}) {
  final dark = brightness == Brightness.dark;
  final seed = const Color(0xFF2C3E91);
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final background = dark ? const Color(0xFF0E0F13) : const Color(0xFFF7F7FA);
  final radius = BorderRadius.circular(16);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,

    // Barre d'appli plate, fondue dans le fond plutôt que teintée par Material 3 au défilement —
    // plus sobre, et surtout plus cohérente avec le mode calculatrice (aucune barre colorée qui
    // distinguerait visuellement une appli « normale » d'une appli « discrète »).
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),

    textTheme: const TextTheme().apply(
      fontSizeFactor: 1.0,
      bodyColor: dark ? const Color(0xFFE7E7EC) : const Color(0xFF1A1A1F),
      displayColor: dark ? const Color(0xFFE7E7EC) : const Color(0xFF1A1A1F),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1C1D24) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        minimumSize: const Size(0, 52),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        minimumSize: const Size(0, 52),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF17181E) : Colors.white,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.3 : 0.6)),
      ),
    ),

    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),

    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.8),
      thickness: 1,
      space: 1,
    ),

    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest,
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xFF2A2B33) : const Color(0xFF1A1A1F),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF17181E) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF17181E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
  );
}

/// Palette dérivée d'un identifiant (utilisateur, salon) pour donner un avatar coloré stable sans
/// jamais stocker de couleur nulle part : la même entrée produit toujours la même couleur. Choisie
/// pour rester lisible (contraste texte blanc) dans les deux thèmes, clair et sombre.
Color murmureAvatarColor(String id) {
  const palette = [
    Color(0xFF2C3E91), // indigo (couleur de départ du thème)
    Color(0xFF8E24AA), // violet
    Color(0xFF00897B), // sarcelle
    Color(0xFFD81B60), // framboise
    Color(0xFF3949AB), // bleu profond
    Color(0xFF6D4C41), // brun
    Color(0xFF43A047), // vert
    Color(0xFF546E7A), // bleu-gris
  ];
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}
