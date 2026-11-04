import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

/// Scanne un QR code (contact Murmure) et renvoie le texte lu via [Navigator.pop].
class QrScanScreen extends StatelessWidget {
  const QrScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Trouvé par Grok (revue croisée IA), vérifié ensuite contre le comportement documenté et
    // l'exemple officiel de flutter_zxing (`scanDelaySuccess` : « délai entre deux scans quand un
    // code est détecté » — implique que la lecture continue après succès, juste espacée ; et leur
    // propre exemple ne fait jamais de Navigator.pop() nu dans onScan, il remplace plutôt le
    // widget affiché). La caméra reste active et continue de lire pendant l'animation de
    // transition qui suit un premier Navigator.pop() ; un second appel sur cette même route déjà
    // en train de se dépiler lève une exception Navigator. `_popped` garantit un seul pop, même si
    // onScan est déclenché plusieurs fois pour le même code tenu trop longtemps dans le cadre.
    var popped = false;
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un code')),
      body: ReaderWidget(
        codeFormat: Format.qrCode,
        showGallery: true,
        showFlashlight: true,
        showToggleCamera: true,
        onScan: (Code code) {
          if (popped) return;
          final text = code.text;
          if (text != null && text.isNotEmpty) {
            popped = true;
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

  // Trouvé en audit interne (revue indépendante), confirmé contre le code source réel de
  // flutter_zxing : `WriterWidget` n'affiche JAMAIS l'image du code généré — son `build()` ne
  // rend qu'un formulaire (champ de texte, menus format/ECC, champs largeur/hauteur/marge,
  // bouton « Créer ») ; l'image (bytes PNG) n'est livrée QUE via son callback `onSuccess`,
  // déclenché seulement quand on presse ce bouton. Cet écran ne branchait pas `onSuccess` : «
  // Mon code » n'affichait donc jamais de QR code à faire scanner — seulement un formulaire
  // d'édition de l'identifiant, avec l'ID par erreur modifiable dans un champ de texte. On
  // appelle directement l'API bas niveau que `WriterWidget.createBarcode()` utilise en interne
  // (`zx.encodeBarcode` + `pngFromBytes`, toutes les deux exportées par le paquet) pour générer
  // l'image une fois, statiquement, sans formulaire ni bouton — il n'y a rien à choisir ici,
  // l'identifiant affiché ne doit pas être modifiable.
  Widget _buildQrImage() {
    const size = 260;
    final result = zx.encodeBarcode(
      contents: shareableId,
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
    // `Encode` n'expose pas de getters `width`/`height` à la version réellement résolue ici
    // (flutter_zxing 2.2.1, confirmé par l'échec de `flutter analyze` en CI — ajoutés seulement
    // dans une version ultérieure du paquet) : on repasse donc la taille demandée, comme le fait
    // `WriterWidget.createBarcode()` lui-même à cette version (il utilise les champs du
    // formulaire, jamais `result.width`/`height`).
    final bytes = pngFromBytes(result.data!, size, size);
    return Image.memory(bytes, width: size.toDouble(), height: size.toDouble());
  }

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
                  child: _buildQrImage(),
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
