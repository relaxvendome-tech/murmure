import 'package:flutter/material.dart';

import '../network.dart';
import '../update/update_checker.dart';
import '../update/update_models.dart';

/// Vérification/téléchargement/installation des mises à jour (voir lib/update/update_checker.dart
/// et docs/UPDATES.md pour l'architecture complète) — et réglage de l'URL du manifeste, qui n'a
/// pas d'autre écran pour l'instant (voir le commentaire de [NetConfig.updateManifestUrl]).
///
/// LIMITE HONNÊTE, à ne jamais présenter autrement à l'utilisateur : aucune signature n'est
/// vérifiée par Murmure lui-même avant de proposer l'installation — seule l'empreinte SHA-256
/// (contre la corruption/modification en transit) est vérifiée ici. La protection contre un APK
/// malveillant signé par une clé différente vient d'Android, au moment de l'installation
/// elle-même, pas de cet écran.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

enum _Phase { idle, checking, upToDate, found, downloading, downloaded, error }

class _UpdateScreenState extends State<UpdateScreen> {
  final _urlCtrl = TextEditingController();
  bool _loadingUrl = true;
  bool _savingUrl = false;
  String? _urlSavedMessage;

  _Phase _phase = _Phase.idle;
  UpdateCheckResult? _result;
  double _progress = 0;
  String? _error;
  int? _currentVersionCode;

  @override
  void initState() {
    super.initState();
    _loadUrl();
    _loadCurrentVersion();
  }

  Future<void> _loadUrl() async {
    final net = await NetConfig.load();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = net.updateManifestUrl ?? '';
      _loadingUrl = false;
    });
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final v = await UpdateChecker.currentVersionCode();
      if (mounted) setState(() => _currentVersionCode = v);
    } catch (_) {
      // Non bloquant : affiché seulement si disponible, voir build().
    }
  }

  Future<void> _saveUrl() async {
    setState(() {
      _savingUrl = true;
      _urlSavedMessage = null;
    });
    final text = _urlCtrl.text.trim();
    if (text.isNotEmpty) {
      final uri = Uri.tryParse(text);
      if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
        setState(() {
          _savingUrl = false;
          _urlSavedMessage = null;
          _error = 'L\'URL doit commencer par https://';
          _phase = _Phase.error;
        });
        return;
      }
    }
    final net = await NetConfig.load();
    await net.copyWith(updateManifestUrl: text).save();
    if (!mounted) return;
    setState(() {
      _savingUrl = false;
      _urlSavedMessage = text.isEmpty
          ? 'Vérification des mises à jour désactivée'
          : 'Adresse de mise à jour enregistrée';
    });
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = result == null ? _Phase.upToDate : _Phase.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final result = _result;
    if (result == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await UpdateChecker.download(
        result.manifest,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.downloaded);
      await UpdateChecker.install(file);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.error;
      });
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mises à jour')),
      body: _loadingUrl
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_currentVersionCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Version actuellement installée : code $_currentVersionCode',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    'La vérification et le téléchargement passent par le même mode réseau que le '
                    'reste de Murmure (direct, Tor ou proxy — voir vos réglages réseau) : jamais '
                    'un trafic séparé qui révélerait votre IP réelle. Rien ne se télécharge ni ne '
                    's\'installe sans que vous ne l\'ayez explicitement demandé ci-dessous.',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Adresse du manifeste de mise à jour', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    hintText: 'https://exemple.invalid/updates/manifest.json',
                    helperText: 'Laissez vide pour désactiver la vérification des mises à jour.',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _savingUrl ? null : _saveUrl,
                    child: _savingUrl
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Enregistrer l\'adresse'),
                  ),
                ),
                if (_urlSavedMessage != null)
                  Text(_urlSavedMessage!, style: TextStyle(color: scheme.primary, fontSize: 13)),
                const Divider(height: 32),
                _buildStatus(scheme),
              ],
            ),
    );
  }

  Widget _buildStatus(ColorScheme scheme) {
    switch (_phase) {
      case _Phase.idle:
      case _Phase.upToDate:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_phase == _Phase.upToDate)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    const Text('Murmure est déjà à jour.'),
                  ],
                ),
              ),
            FilledButton(onPressed: _check, child: const Text('Vérifier les mises à jour')),
          ],
        );

      case _Phase.checking:
        return const Center(child: CircularProgressIndicator());

      case _Phase.found:
        final m = _result!.manifest;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _result!.mandatory ? Icons.warning_amber_outlined : Icons.system_update_outlined,
                  color: _result!.mandatory ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _result!.mandatory
                        ? 'Mise à jour nécessaire : ${m.versionName}'
                        : 'Mise à jour disponible : ${m.versionName}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (m.notes != null) ...[
              const SizedBox(height: 8),
              Text(m.notes!, style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _downloadAndInstall,
              child: const Text('Télécharger et installer'),
            ),
          ],
        );

      case _Phase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text(
              'Téléchargement… ${(_progress * 100).toStringAsFixed(0)} %',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case _Phase.downloaded:
        return Text(
          'Téléchargement vérifié. L\'écran d\'installation d\'Android devrait s\'ouvrir — s\'il ne '
          's\'affiche pas, vérifiez que Murmure est autorisé à installer des applis dans les '
          'réglages Android.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        );

      case _Phase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_error ?? 'Erreur inconnue', style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _check, child: const Text('Réessayer')),
          ],
        );
    }
  }
}
