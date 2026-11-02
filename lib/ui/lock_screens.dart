import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account.dart';
import '../lock.dart';
import 'calculator_lock_screen.dart';

/// Porte d'entrée de l'appli : affiche l'écran de verrou adapté (classique ou calculatrice selon
/// le réglage « mode discret ») tant que l'appli n'est pas déverrouillée, puis laisse passer vers
/// [child]. Reverrouille automatiquement après [Config.kRelockAfter] en arrière-plan.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child, required this.onWiped});

  final Widget child;
  final Future<void> Function() onWiped;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  bool? _unlocked; // null = en cours de vérification du réglage « verrou activé »
  bool _calcMode = false;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    final enabled = await AppLock.enabled();
    final calc = await Account.read('calc_mode');
    if (!mounted) return;
    setState(() {
      _calcMode = calc == '1';
      _unlocked = !enabled;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      if (since != null && DateTime.now().difference(since) > const Duration(seconds: 30)) {
        setState(() => _unlocked = false);
      }
    }
  }

  Future<void> _wipe() async {
    await widget.onWiped();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked == null) return const _Splash();
    if (_unlocked == true) return widget.child;
    if (_calcMode) {
      return CalculatorLockScreen(
        onUnlocked: () => setState(() => _unlocked = true),
        onWipe: _wipe,
      );
    }
    return PinScreen(
      mode: PinScreenMode.unlock,
      onSuccess: () => setState(() => _unlocked = true),
      onWipe: _wipe,
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

enum PinScreenMode { unlock, setPin, setDuress, confirm }

/// Écran de saisie de code, réutilisé pour déverrouiller, définir le code normal, définir le code
/// de contrainte, ou confirmer un nouveau code avant de l'enregistrer.
class PinScreen extends StatefulWidget {
  const PinScreen({
    super.key,
    required this.mode,
    this.onSuccess,
    this.onWipe,
    this.pendingPin,
    this.excludePin,
  });

  final PinScreenMode mode;
  final VoidCallback? onSuccess;
  final Future<void> Function()? onWipe;

  /// En mode [PinScreenMode.confirm] : le code saisi au premier écran, à comparer.
  final String? pendingPin;

  /// En mode [PinScreenMode.setDuress] : le code normal, que le code de contrainte ne doit pas égaler.
  final String? excludePin;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String? _error;
  bool _busy = false;
  int? _remaining;

  @override
  void initState() {
    super.initState();
    if (widget.mode == PinScreenMode.unlock) {
      AppLock.remaining().then((r) {
        if (mounted) setState(() => _remaining = r);
      });
    }
  }

  void _digit(String d) {
    if (_busy || _pin.length >= AppLock.maxLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < AppLock.minLength) {
      setState(() => _error = 'Au moins ${AppLock.minLength} chiffres');
      return;
    }
    setState(() => _busy = true);

    switch (widget.mode) {
      case PinScreenMode.unlock:
        final r = await AppLock.check(_pin);
        if (!mounted) return;
        switch (r) {
          case PinResult.ok:
            widget.onSuccess?.call();
          case PinResult.duress:
            await widget.onWipe?.call();
          case PinResult.wrong:
            final remaining = await AppLock.remaining();
            setState(() {
              _busy = false;
              _pin = '';
              _remaining = remaining;
              _error = 'Code incorrect';
            });
          case PinResult.exhausted:
            await widget.onWipe?.call();
        }
      case PinScreenMode.setPin:
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PinScreen(mode: PinScreenMode.confirm, pendingPin: _pin, onSuccess: widget.onSuccess),
        ));
        setState(() => _busy = false);
      case PinScreenMode.confirm:
        if (_pin != widget.pendingPin) {
          setState(() {
            _busy = false;
            _pin = '';
            _error = 'Les codes ne correspondent pas';
          });
          return;
        }
        await AppLock.setPin(_pin);
        if (!mounted) return;
        // Deux écrans à dépiler : "confirmer le code" (celui-ci) puis "choisir un code".
        Navigator.of(context).pop();
        Navigator.of(context).pop();
        widget.onSuccess?.call();
      case PinScreenMode.setDuress:
        if (_pin == widget.excludePin) {
          setState(() {
            _busy = false;
            _pin = '';
            _error = 'Doit différer du code normal';
          });
          return;
        }
        await AppLock.setDuress(_pin);
        if (!mounted) return;
        Navigator.of(context).pop();
    }
  }

  String get _title => switch (widget.mode) {
        PinScreenMode.unlock => 'Murmure',
        PinScreenMode.setPin => 'Choisir un code',
        PinScreenMode.confirm => 'Confirmer le code',
        PinScreenMode.setDuress => 'Code de contrainte',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(AppLock.maxLength, (i) {
                final filled = i < _pin.length;
                return Container(
                  margin: const EdgeInsets.all(5),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? Theme.of(context).colorScheme.primary : Colors.transparent,
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_remaining != null && _remaining! < AppLock.maxFailures)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('$_remaining tentative(s) restante(s)',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 32),
            SizedBox(
              width: 280,
              child: GridView.count(
                shrinkWrap: true,
                crossAxisCount: 3,
                children: [
                  for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                    _Key(label: d, onTap: () => _digit(d)),
                  const SizedBox(),
                  _Key(label: '0', onTap: () => _digit('0')),
                  _Key(icon: Icons.backspace_outlined, onTap: _backspace),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, required this.onTap});
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        shape: const CircleBorder(),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
            child: label != null
                ? Text(label!, style: const TextStyle(fontSize: 22))
                : Icon(icon, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Réglages du verrou : activer/désactiver le code, définir un code de contrainte, et basculer
/// le « mode discret » (apparence calculatrice sur l'icône et l'écran de verrou).
class LockSettingsScreen extends StatefulWidget {
  const LockSettingsScreen({super.key, required this.onToggleCalcMode, this.onDeleteAccount});

  /// Appelé après le changement du réglage, avec la nouvelle valeur — pour que l'appelant
  /// bascule l'icône de lancement via le MethodChannel natif (voir MainActivity.kt).
  final Future<void> Function(bool enabled) onToggleCalcMode;

  /// Supprime le compte sur le serveur puis efface tout du téléphone (voir
  /// [Account.deleteEverything]). Null si aucun compte n'est connecté (ne devrait pas arriver
  /// depuis RoomsScreen, mais LockSettingsScreen reste utilisable sans compte Matrix, en mode
  /// Bluetooth seul).
  final Future<void> Function()? onDeleteAccount;

  @override
  State<LockSettingsScreen> createState() => _LockSettingsScreenState();
}

class _LockSettingsScreenState extends State<LockSettingsScreen> {
  bool _pinEnabled = false;
  bool _hasDuress = false;
  bool _calcMode = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppLock.enabled();
    final duress = await AppLock.hasDuress();
    final calc = await Account.read('calc_mode');
    if (!mounted) return;
    setState(() {
      _pinEnabled = enabled;
      _hasDuress = duress;
      _calcMode = calc == '1';
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Splash();
    return Scaffold(
      appBar: AppBar(title: const Text('Verrouillage')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Code PIN'),
            subtitle: const Text('Verrouille l\'appli ; jamais stocké en clair'),
            value: _pinEnabled,
            onChanged: (v) async {
              if (v) {
                final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => PinScreen(mode: PinScreenMode.setPin, onSuccess: () {}),
                ));
                await _load();
                if (ok != null) {}
              } else {
                await AppLock.disable();
                await _load();
              }
            },
          ),
          if (_pinEnabled) ...[
            SwitchListTile(
              title: const Text('Code de contrainte'),
              subtitle: const Text('Un second code qui efface tout, en silence, ouvre une appli vierge'),
              value: _hasDuress,
              onChanged: (v) async {
                if (v) {
                  final pinHash = await Account.read('pin_hash');
                  if (pinHash == null) return;
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PinScreen(mode: PinScreenMode.setDuress),
                  ));
                } else {
                  await AppLock.removeDuress();
                }
                await _load();
              },
            ),
            SwitchListTile(
              title: const Text('Mode discret'),
              subtitle: const Text(
                  'L\'icône et l\'écran de verrou deviennent une calculatrice. Le même code ouvre Murmure.'),
              value: _calcMode,
              onChanged: (v) async {
                await Account.write('calc_mode', v ? '1' : '0');
                await widget.onToggleCalcMode(v);
                await _load();
              },
            ),
          ],
          if (widget.onDeleteAccount != null) ...[
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Zone dangereuse',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
              title: Text('Supprimer mon compte',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: const Text(
                  'Supprime le compte sur le serveur et efface tout de ce téléphone. Irréversible.'),
              onTap: () => _confirmDeleteAccount(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer définitivement ce compte ?'),
        content: const Text(
          'Votre compte sera supprimé du serveur et toutes les données locales (messages, clés, '
          'contacts) seront effacées de ce téléphone. Cette action est irréversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onDeleteAccount?.call();
    }
  }
}
