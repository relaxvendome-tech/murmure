import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

/// Affiche en QR le code de contact Bluetooth (clé publique X25519, base64url) pour qu'un
/// contact le scanne hors réseau. Ne contient que la clé publique : aucun secret.
class MeshQrScreen extends StatelessWidget {
  const MeshQrScreen({super.key, required this.code});
  final String code;

  Widget _buildQrImage() {
    const size = 260;
    final result = zx.encodeBarcode(
      contents: code,
      params: EncodeParams(
        format: Format.qrCode,
        width: size,
        height: size,
        margin: 0,
        eccLevel: EccLevel.medium,
      ),
    );
    if (!result.isValid || result.data == null) {
      return const Text('Impossible de générer le code QR.');
    }
    final bytes = pngFromBytes(result.data!, size, size);
    return Image.memory(bytes, width: size.toDouble(), height: size.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon code Bluetooth')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Faites scanner ce code à votre contact (Ajouter un contact > Scanner un code).',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(padding: const EdgeInsets.all(16), child: _buildQrImage()),
              ),
              const SizedBox(height: 16),
              SelectableText(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
