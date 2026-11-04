import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account.dart';
import '../calls/services/call_opsec_notifier.dart';
import '../config.dart';
import '../lock.dart';
import 'calculator_lock_screen.dart';
import 'update_screen.dart';

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
    AppLock.isUnlocked = _unlocked!;
  }

  /// Trouvé en audit interne : comparait auparavant à un `Duration(seconds: 30)` codé en dur ici
  /// même, au lieu de [kRelockAfter] — alors que le commentaire de tête de [LockGate] prétendait
  /// déjà utiliser cette constante. Les deux valaient 30 s, donc le comportement observé était
  /// correct par coïncidence ; changer `kRelockAfter` dans `config.dart` n'aurait silencieusement
  /// rien changé ici. Utilise maintenant [kRelockAfter] directement, source unique de vérité.
  // Trouvé en audit interne (revue indépendante), confirmé contre la documentation officielle de
  // `AppLifecycleState` (règle de synthèse des états) : au retour au premier plan, Flutter
  // traverse `paused -> hidden -> inactive -> resumed` — `inactive` est donc aussi émis À LA
  // REMONTÉE, juste avant `resumed`, pas seulement en descendant vers l'arrière-plan. En
  // écoutant `inactive` ici pour horodater la mise en arrière-plan, ce code écrasait
  // systématiquement `_backgroundedAt` avec « maintenant » juste avant que la branche `resumed`
  // ne calcule l'écart — rendant le relock automatique après [kRelockAfter] inopérant en
  // pratique dans le cas courant (l'app revient au premier plan normalement, pas tuée puis
  // relancée) : l'écart mesuré était quasiment toujours ~0, jamais supérieur à [kRelockAfter].
  // `paused` seul (Android : `Activity.onStop`, l'appli n'est plus du tout visible — pas la perte
  // de focus transitoire d'un volet de notifications ou d'un appel entrant que couvre `inactive`)
  // est le signal fiable d'un VRAI passage en arrière-plan : il n'est, lui, traversé qu'en
  // descendant, jamais en remontant vers `resumed`.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      if (since != null && DateTime.now().difference(since) > kRelockAfter) {
        unawaited(_relock());
      }
    }
  }

  /// Trouvé en audit interne (revue indépendante), deux bugs réels dans l'ancien code inline :
  ///
  /// 1. [LockGate] n'est que le `home:` de `MaterialApp` — PAS une frontière de navigation (voir
  ///    le commentaire de classe de [AppLock.isUnlocked] dans `lock.dart`). Une conversation, les
  ///    réglages ou le profil ouverts via `Navigator.of(context).push` depuis [RoomsScreen]
  ///    s'empilent sur le MÊME navigateur racine, PAR-DESSUS la route de [LockGate]. L'ancien code
  ///    se contentait de `setState(() => _unlocked = false)` : cela changeait bien l'état interne,
  ///    mais [LockGate] restait enterré sous la route ouverte, dont le contenu continuait de
  ///    s'afficher normalement — téléphone saisi en veille puis rallumé, conversation lisible,
  ///    l'écran PIN existant seulement en dessous, invisible. `popUntil((route) => route.isFirst)`
  ///    referme explicitement tout ce qui a été empilé par-dessus avant de reverrouiller, pour que
  ///    la route la plus basse (celle de [LockGate] lui-même) redevienne effectivement visible.
  /// 2. Le relock s'appliquait même quand [AppLock.enabled] est faux (aucun code PIN défini) :
  ///    `_unlocked` repassait à `false` sans condition, et [build] affiche alors un [PinScreen]
  ///    qu'aucun code ne peut jamais déverrouiller ([AppLock.check] reçoit `pinHash == null`, donc
  ///    CHAQUE tentative compte comme un échec) — jusqu'à [PinResult.exhausted] et un effacement
  ///    total non voulu par un utilisateur qui n'avait simplement jamais activé de verrou. On
  ///    revérifie donc [AppLock.enabled] ici, pas seulement dans [_init], avant de reverrouiller.
  ///
  /// Trouvé en audit interne (revue croisée IA, confirmée en relisant [CallManager.handleNewCall]
  /// dans `calls/services/call_manager.dart`) : régression introduite par le correctif ci-dessus.
  /// `AppLock.isUnlocked` n'était mis à `false` qu'à LA FIN de cette méthode, après le `await
  /// AppLock.enabled()`. [CallManager.handleNewCall] décide de pousser (ou non) `CallSessionScreen`
  /// sur `murmureNavigatorKey` en lisant `AppLock.isUnlocked` de façon purement synchrone, sans
  /// attendre ce correctif. Un appel natif arrivant PENDANT cet `await` (fenêtre asynchrone réelle
  /// : lecture Keystore) voyait donc encore `isUnlocked == true`, poussait l'écran d'appel entrant
  /// — puis le `popUntil(isFirst)` qui suivait la reprise de cette méthode le refermait aussitôt en
  /// le prenant pour un écran pérîmé à cacher, supprimant un appel entrant légitime au lieu de
  /// masquer une conversation. `isUnlocked` passe maintenant à `false` en premier, de façon
  /// synchrone, AVANT tout `await` : toute la fenêtre asynchrone qui suit voit donc l'état verrouillé
  /// dès le départ (fail closed, cohérent avec le choix de [AppLock.isUnlocked] lui-même). Si le
  /// relock est finalement annulé (pas de PIN configuré), la valeur est restaurée explicitement
  /// avant de sortir — l'appli reste alors affichée normalement, sans rien de verrouillé.
  Future<void> _relock() async {
    AppLock.isUnlocked = false;
    final enabled = await AppLock.enabled();
    if (!mounted || !enabled) {
      AppLock.isUnlocked = true; // relock annulé : rien n'est verrouillé, on restaure l'état réel.
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    setState(() => _unlocked = false);
  }

  Future<void> _wipe() async {
    await widget.onWiped();
  }

  /// Déverrouillage réussi : fait disparaître la notification d'appel manqué (camouflée ou non,
  /// voir `calls/services/call_opsec_notifier.dart`) AVANT d'afficher l'intérieur de l'appli —
  /// directive explicite de l'utilisateur, pour qu'elle ne reste pas visible dans la barre d'état
  /// une fois la calculatrice « ouverte ».
  void _onUnlockSuccess() {
    unawaited(CallOpsecNotifier.clear());
    setState(() => _unlocked = true);
    AppLock.isUnlocked = true;
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked == null) return const _Splash();
    if (_unlocked == true) return widget.child;
    if (_calcMode) {
      return CalculatorLockScreen(
        onUnlocked: _onUnlockSuccess,
        onWipe: _wipe,
      );
    }
    return PinScreen(
      mode: PinScreenMode.unlock,
      onSuccess: _onUnlockSuccess,
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
  });

  final PinScreenMode mode;
  final VoidCallback? onSuccess;
  final Future<void> Function()? onWipe;

  /// En mode [PinScreenMode.confirm] : le code saisi au premier écran, à comparer.
  final String? pendingPin;

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
            // Trouvé en audit interne (lecture directe, confirmé indépendamment par recherche
            // croisée) : le "if (!mounted) return" ci-dessus ne protège que le premier await
            // (AppLock.check). Un second await (AppLock.remaining(), lui aussi asynchrone) suit
            // juste en dessous, et pouvait laisser passer un setState() après démontage du widget
            // si l'app repasse en arrière-plan assez longtemps pendant la vérification pour que
            // LockGate relock (voir didChangeAppLifecycleState) remplace cet écran entre les deux
            // await — "setState() called after dispose()" côté testeurs humains. Revérifié ici.
            final remaining = await AppLock.remaining();
            if (!mounted) return;
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
        // Trouvé en audit interne : cette vérification comparait auparavant `_pin` à un champ
        // `excludePin` censé porter le code normal en clair — jamais réellement transmis par
        // l'appelant (LockSettingsScreen construisait ce PinScreen sans ce paramètre), et de
        // toute façon structurellement impossible à y faire transiter proprement : le code normal
        // n'est JAMAIS gardé en clair une fois défini (seule son empreinte PBKDF2 est persistée,
        // voir [AppLock]), donc aucun appelant arrivant depuis les réglages ne peut jamais le
        // connaître. Conséquence réelle : rien n'empêchait de définir un code de contrainte
        // identique au code normal. Comme [AppLock.check] teste la contrainte EN PREMIER, cela
        // aurait transformé chaque déverrouillage normal en effacement total — un PIN qui
        // fonctionnait au moment du réglage se serait mis à tout détruire au prochain usage normal,
        // sans aucun signal d'alerte pour l'utilisateur. Corrigé en comparant directement à
        // l'empreinte déjà en stockage via [AppLock.classify], qui n'a besoin que du PIN candidat
        // tout juste saisi — jamais de code en clair à faire transiter.
        //
        // Trouvé en audit interne (optimisation réelle, pas de principe) : cette vérification et
        // l'écriture qui suivait faisaient chacune leur propre dérivation PBKDF2-SHA256 à 120 000
        // itérations pour le même PIN/sel — deux calculs délibérément coûteux pour une seule
        // action utilisateur. `AppLock.trySetDuress` fait maintenant les deux en un seul calcul.
        if (!await AppLock.trySetDuress(_pin)) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _pin = '';
            _error = 'Doit différer du code normal';
          });
          return;
        }
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
/// le « mode discret » (l'écran de verrou devient une calculatrice ; l'icône de l'appli, elle,
/// reste toujours « Murmure » — voir docs/UPDATES.md pour pourquoi aucun changement d'icône de
/// lancement n'est fait : Google Play interdit qu'une appli change son icône/nom affichés pour se
/// faire passer pour une autre, voir la policy « Impersonation »).
class LockSettingsScreen extends StatefulWidget {
  const LockSettingsScreen({super.key, this.onDeleteAccount});

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
                // Trouvé en audit interne : désactiver le PIN sans aussi désactiver le mode
                // discret laissait une incohérence dangereuse — l'écran de verrou calculatrice
                // était configuré pour s'afficher (voir LockGate._init(), qui lit calc_mode) alors
                // que l'appli, elle, s'ouvrait désormais directement sur Murmure sans aucun verrou
                // (LockGate._init() lit aussi AppLock.enabled(), qui redevient false ici).
                // Quelqu'un qui compte sur l'écran calculatrice pour dissimuler l'appli se
                // retrouverait donc à exposer la messagerie en clair au premier appui, sans le
                // savoir. On efface donc calc_mode AVANT de supprimer le code.
                if (_calcMode) {
                  await Account.write('calc_mode', '0');
                }
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
                  // Trouvé en audit interne : BuildContext utilisé juste en dessous
                  // (Navigator.of(context)) après cet await, sans revérifier mounted. L'écran de
                  // réglages reste normalement ouvert tout du long, mais Account.read passe par le
                  // Keystore (flutter_secure_storage) — un démontage pendant cette lecture (retour
                  // arrière rapide de l'utilisateur, par exemple) ferait planter l'appli au lieu de
                  // simplement abandonner l'action.
                  if (!mounted) return;
                  if (pinHash == null) return;
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PinScreen(mode: PinScreenMode.setDuress),
                  ));
                } else {
                  await AppLock.removeDuress();
                }
                if (!mounted) return;
                await _load();
              },
            ),
            SwitchListTile(
              title: const Text('Mode discret'),
              subtitle: const Text(
                  'L\'écran de verrou devient une calculatrice. Le même code ouvre Murmure. '
                  'L\'icône de l\'appli reste toujours « Murmure ».'),
              value: _calcMode,
              onChanged: (v) async {
                await Account.write('calc_mode', v ? '1' : '0');
                await _load();
              },
            ),
          ],
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Mises à jour'),
            subtitle: const Text('Vérifier et installer une nouvelle version de Murmure'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const UpdateScreen()),
            ),
          ),
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
