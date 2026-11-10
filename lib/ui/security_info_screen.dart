import 'package:flutter/material.dart';

/// Écran d'information « Ce que Murmure protège (et ne protège pas) ».
///
/// Texte rédigé d'après le comportement réel du code (lib/ et docs/) : chiffrement Matrix
/// Olm/Megolm, base SQLCipher, verrou PIN + code de contrainte, mode discret, Tor/proxy,
/// messages éphémères, relais Bluetooth expérimental. Aucun terme absolu : pas de promesse
/// d'invulnérabilité ni d'anonymat. Écran purement statique : aucune donnée lue, aucun log.
class SecurityInfoScreen extends StatelessWidget {
  const SecurityInfoScreen({super.key});

  static const _sections = <_Section>[
    _Section(
      icon: Icons.verified_user_outlined,
      title: 'Ce que Murmure protège',
      initiallyExpanded: true,
      items: [
        'Le contenu de vos messages, de vos photos et de vos appels est chiffré de bout en bout '
            '(protocoles Matrix Olm et Megolm) : le serveur ne peut pas le lire. Les réactions '
            '(emoji) ne le sont pas, voir ci-dessous.',
        'La base de données de votre téléphone est chiffrée ; sa clé est gardée dans le coffre '
            "sécurisé d'Android.",
        'Le verrou par code protège l\'accès à l\'appli. Le code de contrainte, s\'il est saisi, '
            'efface sur le téléphone les clés, les messages et les médias.',
        'Le mode discret affiche un écran d\'apparence calculatrice à l\'intérieur de l\'appli '
            "(l'icône et le nom restent « Murmure »). Il masque l'appli à un regard rapide ; "
            "ce n'est pas un chiffrement supplémentaire.",
        'Tor (via Orbot) ou un proxy SOCKS5 peuvent masquer votre adresse IP au serveur. '
            'Dans ces modes, Murmure refuse de se connecter en direct plutôt que de dévoiler '
            'votre vraie adresse.',
      ],
    ),
    _Section(
      icon: Icons.visibility_outlined,
      title: 'Ce que le serveur peut voir (métadonnées)',
      items: [
        'Qui parle avec qui, et à quels moments.',
        'La taille des messages et des fichiers envoyés.',
        'Les groupes dont vous faites partie, et leurs membres.',
        'Le réglage des messages éphémères d\'une conversation (la durée choisie, jamais le '
            'contenu).',
        'Les réactions (emoji, message visé, auteur) ne sont pas chiffrées : le serveur les voit. '
            'Elles sont désactivées dans les conversations à messages éphémères.',
        'Votre adresse IP en mode direct (sans Tor ni proxy).',
        'Pendant un appel, le relais TURN voit votre adresse IP ; il ne voit pas le contenu, '
            'qui reste chiffré.',
        'Jusqu\'où vous avez lu chaque conversation : un marqueur de lecture privé est toujours '
            'envoyé au serveur, nécessaire pour synchroniser vos non-lus.',
        'Si l\'indicateur de saisie ou les accusés de lecture sont activés, vos correspondants '
            'voient quand vous écrivez ou avez lu. Si les accusés sont désactivés : votre '
            'correspondant ne voit pas que vous avez lu. Le serveur reçoit toujours un marqueur '
            'de lecture privé, nécessaire pour synchroniser vos non-lus.',
      ],
    ),
    _Section(
      icon: Icons.warning_amber_outlined,
      title: 'Ce que Murmure ne protège pas',
      items: [
        'Un téléphone compromis (logiciel espion, application malveillante) : ce qui est lu à '
            'l\'écran ou saisi au clavier peut être vu par ce logiciel.',
        'Une capture d\'écran, une photo de l\'écran ou une copie faite par votre correspondant. '
            'Les messages éphémères ne l\'en empêchent pas : ils reposent sur les appareils de '
            'chacun.',
        'Un appareil non vérifié ajouté au compte d\'un contact : il pourrait lire vos futurs '
            'messages. Invitez vos contacts à vérifier leurs appareils (emojis ou empreinte).',
        'Quelqu\'un qui utilise votre téléphone une fois déverrouillé, ou qui connaît votre code.',
        'Le relais Bluetooth maillé, expérimental : les messages restent chiffrés, mais les '
            'appareils proches peuvent détecter des émissions radio. Il n\'offre aucun anonymat '
            'radio.',
        'Murmure est un projet indépendant, sans audit officiel ni certification : aucune '
            'application ne supprime tout risque.',
      ],
    ),
    _Section(
      icon: Icons.checklist_outlined,
      title: 'Bonnes pratiques',
      items: [
        'Vérifiez l\'appareil de vos contacts importants (emojis ou empreinte).',
        'Activez le verrou par code, et définissez un code de contrainte différent.',
        'Gardez Android et vos applications à jour ; n\'installez rien de douteux.',
        'Utilisez Tor ou un proxy si vous voulez cacher votre adresse IP au serveur.',
        'Pour les sujets sensibles, ne vous fiez pas aux seuls messages éphémères et '
            'méfiez-vous des captures d\'écran.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sécurité et limites')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'Ce que Murmure protège (et ne protège pas)',
              style: theme.textTheme.titleLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Murmure protège bien le contenu de vos échanges, mais aucun outil ne protège de '
              'tout. Voici, simplement, ce qui l\'est ou non.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          for (final s in _sections)
            ExpansionTile(
              leading: Icon(s.icon),
              title: Text(s.title),
              initiallyExpanded: s.initiallyExpanded,
              childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in s.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  '),
                        Expanded(child: Text(item, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Section {
  const _Section({
    required this.icon,
    required this.title,
    required this.items,
    this.initiallyExpanded = false,
  });
  final IconData icon;
  final String title;
  final List<String> items;
  final bool initiallyExpanded;
}
