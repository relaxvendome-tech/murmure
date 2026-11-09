import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../biometric.dart';
import '../calls/services/call_manager.dart';
import '../calls/services/call_opsec_notifier.dart';
import '../config.dart';
import '../lock.dart';
import 'calculator_lock_screen.dart';
import 'network_settings_screen.dart';

/// Porte d'entrée de l'appli : affiche l'écran de verrou adapté (classique ou calculatrice selon
/// le réglage « mode discret ») tant que l'appli n'est pas déverrouillée, puis laisse passer vers
/// [child]. Reverrouille automatiquement après [Config.kRelockAfter] en arrière-plan.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child, required this.onWiped, required this.callManager});

  final Widget child;
  final Future<void> Function() onWiped;

  /// Trouvé en audit interne (revue croisée à 5 IA, demandée explicitement par l'utilisateur sur
  /// ce point précis — question ouverte restée en suspens après le correctif de
  /// [AppLock.isUnlocked]) : un appel DÉJÀ décroché et affiché (micro ouvert) ne doit jamais être
  /// raccroché automatiquement par un reverrouillage qui survient pendant l'appel. Consensus unanime des 5
  /// IA consultées : ne jamais détruire une session d'appel en cours pour reverrouiller — un appel
  /// peut être exactement le canal par lequel un utilisateur en manifestation signale une
  /// interpellation ou demande de l'aide juridique ; le couper automatiquement serait pire que de
  /// retarder le verrou de quelques instants.
  final CallManager callManager;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  bool? _unlocked; // null = en cours de vérification du réglage « verrou activé »
  bool _calcMode = false;
  DateTime? _backgroundedAt;

  /// Dernier état connu « code PIN activé » (mémorisé par [_init]/[_relock]) : permet de masquer
  /// le contenu de façon SYNCHRONE au retour au premier plan, sans attendre la lecture Keystore de
  /// [_relock] — sinon la conversation ouverte restait brièvement visible avant le verrou.
  bool _pinEnabled = false;

  /// Échec de lecture du réglage au démarrage (Keystore indisponible…) : écran d'erreur avec
  /// bouton « Réessayer » plutôt qu'un splash bloqué indéfiniment.
  bool _initFailed = false;

  /// Vrai si un `didChangeAppLifecycleState(resumed)` a dépassé [kRelockAfter] PENDANT qu'un
  /// appel était actif (voir [_relock]) : le reverrouillage n'a donc pas été appliqué sur le
  /// moment, mais reste dû — [_onActiveCallChanged] le déclenche dès que l'appel se termine, sans
  /// attendre un prochain cycle arrière-plan/premier-plan qui pourrait ne jamais survenir si
  /// l'utilisateur reste simplement au premier plan jusqu'à la fin de l'appel.
  bool _relockPendingCallEnd = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.callManager.activeCallListenable.addListener(_onActiveCallChanged);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.callManager.activeCallListenable.removeListener(_onActiveCallChanged);
    super.dispose();
  }

  void _onActiveCallChanged() {
    if (_relockPendingCallEnd && !widget.callManager.activeCallListenable.value) {
      _relockPendingCallEnd = false;
      _lockSync();
      unawaited(_relock());
    }
  }

  Future<void> _init() async {
    if (_initFailed) setState(() => _initFailed = false);
    try {
      final enabled = await AppLock.enabled();
      final calc = await Account.read('calc_mode');
      if (!mounted) return;
      _pinEnabled = enabled;
      setState(() {
        _calcMode = calc == '1';
        _unlocked = !enabled;
      });
      AppLock.isUnlocked = !enabled;
    } catch (_) {
      // Échec fermé : l'appli reste verrouillée (isUnlocked == false) et propose de réessayer.
      AppLock.isUnlocked = false;
      if (!mounted) return;
      setState(() => _initFailed = true);
    }
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
  //
  // Trouvé en audit interne (contournement du verrou par appel entrant) : l'instant de mise en
  // arrière-plan est maintenant AUSSI publié dans [AppLock.backgroundedAt], pour que
  // [AppLock.isUnlocked] devienne `false` dès [kRelockAfter] écoulé EN ARRIÈRE-PLAN — et non
  // seulement au retour au premier plan. Au `resumed`, l'horodatage est consommé (remis à
  // `null`) : un `resumed` sans `paused` préalable (volet de notifications, boîte de dialogue
  // système) ne peut donc jamais reverrouiller sur la base d'un ancien horodatage.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final now = DateTime.now();
      _backgroundedAt = now;
      AppLock.backgroundedAt = now;
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      AppLock.backgroundedAt = null;
      if (since == null || DateTime.now().difference(since) <= kRelockAfter) return;
      // Report du verrou UNIQUEMENT pour un appel réellement en cours (micro ouvert) et si
      // l'appli était déverrouillée : ne jamais raccrocher un appel décroché pour reverrouiller.
      // Un appel qui sonne seulement, ou une appli déjà verrouillée, ne retarde rien.
      if (_unlocked == true && widget.callManager.delegate.hasLiveCall) {
        _relockPendingCallEnd = true;
        return;
      }
      _lockSync();
      unawaited(_relock());
    }
  }

  /// Partie synchrone du reverrouillage : [AppLock.isUnlocked] passe à `false` immédiatement
  /// (fail closed pour tout code hors widgets, voir [_relock]) et, si un code est connu comme
  /// activé, le contenu est masqué dès cette frame (routes empilées refermées, écran de verrou
  /// affiché) sans attendre la lecture Keystore de [_relock].
  void _lockSync() {
    AppLock.isUnlocked = false;
    if (!mounted || _unlocked != true) return;
    if (!(_pinEnabled || AppLock.lastKnownEnabled)) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.popUntil((route) => route.isFirst);
    setState(() => _unlocked = false);
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
  ///
  /// Trouvé en audit interne (revue croisée à 5 IA — ChatGPT, Gemini, Grok et Perplexity,
  /// consultés indépendamment, recommandent unanimement la même chose) : avant ce correctif, un
  /// appel DÉCROCHÉ et affiché (`CallSessionScreen`, micro ouvert) se trouvait sur la pile de
  /// navigation au même titre que n'importe quelle autre route — le `popUntil(isFirst)` ci-dessous
  /// le dépilait donc comme n'importe quel autre écran à cacher, déclenchant son `dispose()` qui
  /// raccroche sans condition (voir `calls/ui/call_session_screen.dart`, filet de sécurité
  /// volontaire contre le bouton retour, pas prévu pour ce cas). Un appel en cours peut être le
  /// canal par lequel l'utilisateur signale une interpellation ou demande de l'aide : le couper
  /// automatiquement au premier retour au premier plan après [kRelockAfter] était un risque
  /// opérationnel réel, pas seulement une gêne. On diffère donc intégralement le reverrouillage
  /// (sans toucher à `AppLock.isUnlocked`, qui reste `true` : l'appli n'affiche RIEN de verrouillé
  /// tant que l'appel dure) et on le rejoue dès que [CallManager.activeCallListenable] repasse à
  /// `false` (voir [_onActiveCallChanged]) — jamais en détruisant la session pour reverrouiller.
  ///
  /// Le report pendant un appel est désormais décidé par l'appelant
  /// ([didChangeAppLifecycleState], via `delegate.hasLiveCall`), pas ici : [_relock] verrouille
  /// toujours. Relit aussi `calc_mode` : le mode discret a pu être activé/désactivé depuis
  /// [_init], et l'écran de verrou affiché doit suivre le réglage courant.
  Future<void> _relock() async {
    AppLock.isUnlocked = false;
    bool enabled;
    String? calc;
    try {
      enabled = await AppLock.enabled();
      calc = await Account.read('calc_mode');
    } catch (_) {
      // Keystore illisible : on garde le dernier état connu (verrouillé si un code existait).
      enabled = _pinEnabled || AppLock.lastKnownEnabled;
      calc = _calcMode ? '1' : '0';
    }
    if (!mounted) return;
    _pinEnabled = enabled;
    if (!enabled) {
      AppLock.isUnlocked = true; // relock annulé : rien n'est verrouillé, on restaure l'état réel.
      if (_unlocked != true) setState(() => _unlocked = true);
      return;
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.popUntil((route) => route.isFirst);
    setState(() {
      _calcMode = calc == '1';
      _unlocked = false;
    });
  }

  Future<void> _wipe() async {
    await widget.onWiped();
  }

  /// Déverrouillage réussi : fait disparaître la notification d'appel manqué (camouflée ou non,
  /// voir `calls/services/call_opsec_notifier.dart`) AVANT d'afficher l'intérieur de l'appli —
  /// directive explicite de l'utilisateur, pour qu'elle ne reste pas visible dans la barre d'état
  /// une fois la calculatrice « ouverte ».
  ///
  /// Une fois déverrouillé, un appel entrant arrivé pendant le verrou (non affiché, voir
  /// `MurmureWebRTCDelegate.handleNewCall`) est présenté après la frame suivante.
  void _onUnlockSuccess() {
    if (!mounted) return;
    _relockPendingCallEnd = false;
    unawaited(CallOpsecNotifier.clear());
    AppLock.isUnlocked = true;
    setState(() => _unlocked = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.callManager.delegate.presentPendingCall());
  }

  @override
  Widget build(BuildContext context) {
    if (_initFailed) return _InitError(onRetry: () => unawaited(_init()));
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

class _InitError extends StatelessWidget {
  const _InitError({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Erreur, réessayez'),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ]),
        ),
      );
}

enum PinScreenMode { unlock, setPin, setDuress, confirm, confirmDuress }

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
  bool _bioOffered = false; // biométrie activée ET PIN existant : bouton + prompt au démarrage
  bool _bioRunning = false;

  @override
  void initState() {
    super.initState();
    if (widget.mode == PinScreenMode.unlock) {
      AppLock.remaining().then((r) {
        if (mounted) setState(() => _remaining = r);
      });
      unawaited(_initBiometric());
    }
  }

  /// Propose la biométrie au démarrage de l'écran de verrou NORMAL. Jamais appelé par
  /// [CalculatorLockScreen] (mode discret) : un prompt biométrique trahirait l'appli. Le PIN
  /// reste toujours utilisable ; la biométrie n'ouvre que l'UI (clé SQLCipher inchangée).
  Future<void> _initBiometric() async {
    // Jamais en mode discret, même si cet écran est affiché brièvement après un changement du
    // réglage (avant que [LockGate._relock] n'ait relu `calc_mode`) : le prompt trahirait l'appli.
    final bool offered;
    try {
      offered = (await Account.read('calc_mode')) != '1' &&
          await Biometric.enabled() &&
          await AppLock.enabled() &&
          await Biometric.available();
    } catch (_) {
      return;
    }
    if (!mounted || !offered) return;
    setState(() => _bioOffered = true);
    await _tryBiometric();
  }

  /// Biométrie toujours autorisée ? Revérifiée AVANT et APRÈS le prompt : après
  /// [AppLock.bioMaxPinFailures] échecs de PIN, `bio_enabled` est supprimé (voir [AppLock.check])
  /// et un succès biométrique ne doit alors plus rien déverrouiller, même si le bouton était
  /// encore affiché ou le prompt déjà ouvert.
  Future<bool> _bioStillAllowed() async {
    try {
      return await Biometric.enabled() && await AppLock.enabled();
    } catch (_) {
      return false;
    }
  }

  Future<void> _tryBiometric() async {
    if (_bioRunning || _busy || !mounted) return;
    _bioRunning = true;
    try {
      if (!await _bioStillAllowed()) {
        if (mounted) setState(() => _bioOffered = false);
        return;
      }
      final r = await Biometric.authenticate('Déverrouillez Murmure');
      if (!mounted) return;
      switch (r) {
        case BioResult.success:
          if (!await _bioStillAllowed()) {
            if (mounted) setState(() => _bioOffered = false);
            return;
          }
          if (!mounted || _busy) return;
          widget.onSuccess?.call();
        case BioResult.fallback:
          break; // retour silencieux au PIN
        case BioResult.lockedTemporarily:
          setState(() => _error = 'Biométrie verrouillée temporairement. Utilisez votre code.');
        case BioResult.lockedPermanently:
          setState(() => _error = 'Biométrie verrouillée par Android. Utilisez votre code.');
      }
    } finally {
      _bioRunning = false;
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
    if (_busy) return;
    if (_pin.length < AppLock.minLength) {
      setState(() => _error = 'Au moins ${AppLock.minLength} chiffres');
      return;
    }
    setState(() => _busy = true);
    try {
      await _handleSubmit();
    } catch (_) {
      // Keystore/isolat indisponible, etc. : ne jamais laisser l'écran bloqué en « occupé ».
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pin = '';
        _error = 'Erreur, réessayez';
      });
    }
  }

  Future<void> _handleSubmit() async {
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
            // Après AppLock.bioMaxPinFailures échecs, `bio_enabled` a été supprimé : on retire
            // aussi le bouton biométrique de cet écran.
            final bioStill = _bioOffered && await Biometric.enabled();
            if (!mounted) return;
            setState(() {
              _busy = false;
              _pin = '';
              _remaining = remaining;
              _error = 'Code incorrect';
              if (!bioStill) _bioOffered = false;
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
        // Trouvé en audit interne : le code de contrainte était enregistré dès la première
        // saisie, sans confirmation — une faute de frappe créait un code d'effacement inconnu de
        // l'utilisateur (et donc inutilisable le jour où il en a besoin). Comme pour le code
        // normal, une seconde saisie identique est maintenant exigée ([PinScreenMode.confirmDuress]).
        //
        // La vérification « différent du code normal » (voir [AppLock.trySetDuress] : une seule
        // dérivation PBKDF2, comparaison à l'empreinte stockée, jamais de code en clair à faire
        // transiter) est faite à la confirmation ; l'écran de confirmation renvoie `true` si le
        // code a été enregistré, `false` s'il est identique au code normal, `null` si abandon.
        final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => PinScreen(mode: PinScreenMode.confirmDuress, pendingPin: _pin),
        ));
        if (!mounted) return;
        if (saved == true) {
          Navigator.of(context).pop();
          return;
        }
        setState(() {
          _busy = false;
          _pin = '';
          _error = saved == false ? 'Doit différer du code normal' : null;
        });
      case PinScreenMode.confirmDuress:
        if (_pin != widget.pendingPin) {
          setState(() {
            _busy = false;
            _pin = '';
            _error = 'Les codes ne correspondent pas';
          });
          return;
        }
        final ok = await AppLock.trySetDuress(_pin);
        if (!mounted) return;
        Navigator.of(context).pop(ok);
    }
  }

  String get _title => switch (widget.mode) {
        PinScreenMode.unlock => 'Murmure',
        PinScreenMode.setPin => 'Choisir un code',
        PinScreenMode.confirm => 'Confirmer le code',
        PinScreenMode.setDuress => 'Code de contrainte',
        PinScreenMode.confirmDuress => 'Confirmer le code de contrainte',
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
            if (_bioOffered)
              IconButton(
                tooltip: 'Empreinte ou visage',
                icon: const Icon(Icons.fingerprint),
                iconSize: 36,
                onPressed: _busy ? null : _tryBiometric,
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
  const LockSettingsScreen({super.key, this.onDeleteAccount, this.client});

  /// Supprime le compte sur le serveur puis efface tout du téléphone (voir
  /// [Account.deleteEverything]). Null si aucun compte n'est connecté (ne devrait pas arriver
  /// depuis RoomsScreen, mais LockSettingsScreen reste utilisable sans compte Matrix, en mode
  /// Bluetooth seul).
  final Future<void> Function()? onDeleteAccount;

  /// Trouvé en audit interne : sans ce paramètre, rien dans l'appli (une fois le compte créé)
  /// ne permettait plus jamais de changer de mode réseau (direct/Tor/proxy) — voir le commentaire
  /// de [NetworkSettingsScreen]. Null dans les mêmes cas que [onDeleteAccount] (pas de compte
  /// Matrix connecté) : le réglage réseau reste alors accessible uniquement depuis l'onboarding.
  final Client? client;

  @override
  State<LockSettingsScreen> createState() => _LockSettingsScreenState();
}

class _LockSettingsScreenState extends State<LockSettingsScreen> {
  bool _pinEnabled = false;
  bool _hasDuress = false;
  bool _calcMode = false;
  bool _bioEnabled = false;
  bool _bioAvailable = false;
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
    final bio = await Biometric.enabled();
    final bioAvail = enabled && await Biometric.available();
    if (!mounted) return;
    setState(() {
      _pinEnabled = enabled;
      _hasDuress = duress;
      _calcMode = calc == '1';
      _bioEnabled = bio && enabled;
      _bioAvailable = bioAvail;
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
              title: const Text('Déverrouiller avec l\'empreinte/le visage'),
              subtitle: Text(!_bioAvailable && !_bioEnabled
                  ? 'Indisponible : aucune empreinte ou visage enregistré sur cet appareil.'
                  : 'Ouvre l\'appli sans taper le code, qui reste toujours possible. '
                      'Ne permet pas d\'entrer le code de contrainte.'
                      '${_calcMode ? ' Inactif en mode discret.' : ''}'),
              value: _bioEnabled,
              onChanged: (_bioAvailable || _bioEnabled)
                  ? (v) async {
                      if (v) {
                        // Activation = authentification biométrique réussie d'abord.
                        final r = await Biometric.authenticate('Confirmez pour activer le déverrouillage biométrique');
                        if (!mounted) return;
                        if (r == BioResult.success) {
                          await Biometric.setEnabled(true);
                        } else if (r == BioResult.lockedTemporarily || r == BioResult.lockedPermanently) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Biométrie verrouillée par Android. Réessayez plus tard.')));
                        }
                      } else {
                        await Biometric.setEnabled(false);
                      }
                      if (!mounted) return;
                      await _load();
                    }
                  : null,
            ),
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
          if (widget.client != null) ...[
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.wifi_outlined),
              title: const Text('Réseau'),
              subtitle: const Text('Serveur, mode direct/Tor/proxy'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => NetworkSettingsScreen(client: widget.client!)),
              ),
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
