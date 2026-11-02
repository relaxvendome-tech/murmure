import 'package:flutter/material.dart';

/// Thème visuel de Murmure : sobre, lisible au soleil (manifestations, extérieur), et sans aucun
/// élément qui trahirait visuellement l'usage d'une messagerie chiffrée depuis l'écran verrouillé
/// (le mode calculatrice s'appuie sur ce même souci de discrétion).
ThemeData murmureTheme({required Brightness brightness}) {
  final dark = brightness == Brightness.dark;
  final seed = const Color(0xFF2C3E91);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    scaffoldBackgroundColor: dark ? const Color(0xFF0E0F13) : const Color(0xFFF7F7FA),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
