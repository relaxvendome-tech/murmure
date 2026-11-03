import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

/// Scanne un QR code (contact Murmure) et renvoie le texte lu via [Navigator.pop].
class QrScanScreen extends StatelessWidget {
  const QrScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un code')),
      body: ReaderWidget(
        codeFormat: Format.qrCode,
        showGallery: true,
        showFlashlight: true,
        showToggleCamera: true,
        onScan: (Code code) {
          final text = code.text;
          if (text != null && text.isNotEmpty) {
            Navigator.of(context).pop(text);
          }
        },
      ),
    );
  }
}

/// Affiche le QR code de l'identifiant Murmure de l'utilisateur, à faire scanner par un contact.
/// Ce code ne contient que l'identifiant Matrix public (@xxx:serveur) — jamais de secret, jamais
/// de clé : on ajoute un contact comme on échange un numéro, pas comme on partage un mot de passe.
class MyQrScreen extends StatelessWidget {
  const MyQrScreen({super.key, required this.shareableId});
  final String shareableId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon code')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Faites scanner ce code à un contact pour qu\'il puisse démarrer une '
                'conversation chiffrée avec vous.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: WriterWidget(
                    text: shareableId,
                    format: Format.qrCode,
                    height: 260,
                    margin: 0,
                    eccLevel: EccLevel.medium,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Trouvé en audit interne (demande de simplicité comparable à Signal/Telegram) :
              // partager son code sans scan en face à face (par un autre canal déjà de confiance,
              // par exemple un appel vidéo authentifié) exigeait de sélectionner le texte à la
              // main lettre par lettre — un `SelectableText` seul n'offre qu'une poignée de
              // sélection, pas une action de copie directe. Un bouton « Copier » fait ce que fait
              // déjà Signal/Telegram pour leur propre identifiant, sans rien changer à la donnée
              // copiée (le même `murmure:@xxx:serveur` que le QR encode, toujours uniquement
              // l'identifiant Matrix public, jamais un secret).
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SelectableText(
                      shareableId,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copier',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: shareableId));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Code copié')));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
