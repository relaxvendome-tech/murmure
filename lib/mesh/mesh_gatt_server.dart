import 'dart:async';

import 'package:flutter/services.dart';

/// Pont vers le serveur GATT natif (android/.../MeshGattServer.kt) qui donne à CE téléphone le
/// rôle "périphérique" BLE : annoncer le service du maillage et répondre aux lectures/écritures
/// d'autres téléphones Murmure, en plus du rôle "central" (scan) déjà géré par `flutter_blue_plus`
/// dans mesh.dart. Comme les autres ponts natifs best-effort de ce dépôt, ce pont échoue silencieusement sur les
/// plateformes sans ce canal (iOS, desktop, web) : le maillage y reste limité au rôle central.
class MeshGattServerBridge {
  static const _method = MethodChannel('fr.lansight.murmure/mesh_gatt');
  static const _incoming = EventChannel('fr.lansight.murmure/mesh_gatt_incoming');

  /// Démarre l'annonce BLE et le serveur GATT natif. Ne lève jamais : sur une plateforme sans ce
  /// canal, ou si le Bluetooth est indisponible/désactivé sur l'appareil, le rôle périphérique est
  /// simplement absent et le maillage continue avec le seul rôle central.
  static Future<bool> start() async {
    try {
      final ok = await _method.invokeMethod<bool>('start');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {
      // Rien à faire.
    }
  }

  /// Change ce que le serveur renvoie à la prochaine lecture par un autre téléphone. mesh.dart
  /// fait tourner cette valeur parmi sa file d'enveloppes en attente (voir sa propre doc).
  static Future<void> setReadValue(Uint8List bytes) async {
    try {
      await _method.invokeMethod<void>('setReadValue', {'bytes': bytes});
    } catch (_) {
      // Rien à faire.
    }
  }

  /// Flux des enveloppes reçues par écriture d'un autre téléphone sur notre caractéristique.
  /// Chaque élément est une enveloppe binaire opaque (voir mesh_crypto.dart), jamais déchiffrée
  /// côté natif.
  static Stream<Uint8List> incoming() {
    return _incoming.receiveBroadcastStream().map((event) {
      if (event is Uint8List) return event;
      if (event is List<int>) return Uint8List.fromList(event);
      return Uint8List(0);
    }).where((bytes) => bytes.isNotEmpty);
  }
}
