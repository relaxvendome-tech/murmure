import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../lock.dart';

/// Écran de verrou déguisé en calculatrice (mode discret, optionnel).
///
/// - Calculatrice réelle : + − × ÷, priorités, décimales, moins unaire. Aucune dépendance externe.
/// - Déverrouillage : taper le code PIN de l'appli (4 à 8 chiffres) puis « = ». Le code n'est PAS
///   dans l'appli : il est comparé à l'empreinte PBKDF2 gardée dans le Keystore (voir [AppLock]).
/// - Code de contrainte : même geste, efface tout en silence ([onWipe]).
/// - Compteur d'échecs : SEULE une saisie ayant la FORME d'un code (4 à 8 chiffres, sans aucun
///   opérateur — `_pinShape`, voir `_equals()`) est même transmise à [AppLock] ; un vrai calcul
///   (« 12+34= », par ex.) n'y arrive jamais et ne consomme donc jamais de tentative. Trouvé en
///   audit interne (revue indépendante) : une saisie de cette forme était auparavant comparée via
///   [AppLock.classify], qui ne compte JAMAIS d'échec — un choix défendable tant que l'icône et le
///   nom affichés de l'appli se faisaient eux-mêmes passer pour une calculatrice (un tiers tombant
///   dessus n'avait aucune raison de soupçonner un verrou, donc aucune raison d'essayer des codes
///   à répétition). Ce n'est plus le cas (voir docs/UPDATES.md) : l'icône et le nom affichés
///   restent toujours honnêtement « Murmure », donc quiconque voit une calculatrice s'ouvrir sous
///   ce nom comprend immédiatement qu'il s'agit d'un verrou déguisé — ce qui transformait le
///   compteur désactivé en brute force illimitée sur un PIN à 4 chiffres (10 000 combinaisons),
///   le coût PBKDF2 seul (120 000 itérations, de l'ordre de la milliseconde sur un téléphone)
///   n'étant pas un frein suffisant à lui seul. Utilise maintenant [AppLock.check] (même méthode,
///   même compteur `pin_fails`, que l'écran de verrou classique), donc le même effacement après
///   [AppLock.maxFailures] échecs s'applique ici aussi.
/// - Le résultat du calcul s'affiche immédiatement ; la vérification du code tourne en arrière-plan,
///   donc aucun délai visible ne trahit qu'un code est testé.
class CalculatorLockScreen extends StatefulWidget {
  const CalculatorLockScreen({super.key, required this.onUnlocked, required this.onWipe});

  final VoidCallback onUnlocked;
  final Future<void> Function() onWipe;

  @override
  State<CalculatorLockScreen> createState() => _CalculatorLockScreenState();
}

class _CalculatorLockScreenState extends State<CalculatorLockScreen> {
  static final _pinShape = RegExp(r'^\d{4,8}$');
  static const _maxLength = 24;

  String _input = '';
  String _display = '0';
  bool _justEvaluated = false;
  bool _checking = false;

  /// Chiffres RÉELLEMENT tapés à la suite depuis le dernier opérateur, « = », « C », « ± » ou
  /// virgule. Trouvé en audit interne : sans cela, appuyer plusieurs fois sur « = » réévaluait le
  /// RÉSULTAT affiché (« 1234 = » → « 1234 », qui a la forme d'un code) et le retestait comme PIN
  /// à chaque appui — chaque appui consommait un essai via [AppLock.check], jusqu'à l'effacement
  /// total après [AppLock.maxFailures] appuis. Seule une saisie identique à ce champ est testée.
  String _typedDigits = '';

  /// Codes saisis pendant qu'une vérification était déjà en cours : testés ensuite, dans l'ordre
  /// (auparavant ignorés silencieusement — un vrai code tapé pendant un test n'ouvrait rien).
  final List<String> _pendingPins = [];

  // ---------------------------------------------------------------------------------------------
  // Saisie
  // ---------------------------------------------------------------------------------------------

  void _press(String key) {
    HapticFeedback.selectionClick(); // identique pour toutes les touches : ne trahit rien
    switch (key) {
      case '±':
        _typedDigits = '';
        _toggleSign();
      case 'C':
        _typedDigits = '';
        _set('', '0');
      case '⌫':
        if (_justEvaluated) {
          _typedDigits = '';
          return _set('', '0');
        }
        if (_typedDigits.isNotEmpty) {
          _typedDigits = _typedDigits.substring(0, _typedDigits.length - 1);
        }
        final s = _input.isEmpty ? '' : _input.substring(0, _input.length - 1);
        _set(s, s.isEmpty ? '0' : s);
      case '=':
        _equals();
      default:
        _append(key);
    }
  }

  void _append(String key) {
    final isOp = '+−×÷'.contains(key);
    final isDigit = '0123456789'.contains(key);
    var s = (_justEvaluated && !isOp) ? '' : _input;
    if (_display == 'Erreur') s = '';
    // Nouvelle saisie (après « = » ou « Erreur ») : la série de chiffres tapés repart de zéro.
    final fresh = s.isEmpty;
    if (s.length >= _maxLength) return;
    final last = s.isEmpty ? '' : s[s.length - 1];
    final negativeOperand = key == '−' && (last == '×' || last == '÷');
    if (isOp && !negativeOperand && last.isNotEmpty && '+−×÷'.contains(last)) {
      s = s.substring(0, s.length - 1); // remplace l'opérateur précédent
    }
    if (key == ',') {
      final lastNumber = s.split(RegExp('[+−×÷]')).last;
      if (lastNumber.contains(',')) return;
      if (lastNumber.isEmpty) s += '0';
    }
    if (isOp && s.isEmpty && key != '−') return;
    _justEvaluated = false;
    _typedDigits = isDigit ? (fresh ? key : _typedDigits + key) : '';
    _set(s + key, s + key);
  }

  /// Inverse le signe du dernier nombre saisi (ou du résultat affiché).
  void _toggleSign() {
    if (_input.isEmpty || _display == 'Erreur') return;
    final m = RegExp(r'(^|[+−×÷])(−?)([\d,]+)$').firstMatch(_input);
    if (m == null) return;
    final head = _input.substring(0, m.start) + m.group(1)!;
    final s = head + (m.group(2)!.isEmpty ? '−' : '') + m.group(3)!;
    _justEvaluated = false;
    _set(s, s);
  }

  void _equals() {
    final raw = _input;
    final typed = _typedDigits;
    _typedDigits = '';
    if (raw.isEmpty) return;

    // Toujours afficher un vrai résultat, y compris pour « 19842026 = » (qui vaut 19842026).
    final value = _Calc.evaluate(raw);
    final shown = value == null ? 'Erreur' : _Calc.format(value);
    _justEvaluated = true;
    // Le résultat sert de point de départ au calcul suivant (sauf notation scientifique).
    _set(value == null || shown.contains('e') ? '' : shown, shown);

    // Seuls des chiffres réellement tapés à la suite (pas un résultat réévalué) sont testés.
    if (_pinShape.hasMatch(raw) && raw == typed) unawaited(_tryPin(raw));
  }

  Future<void> _tryPin(String pin) async {
    if (_checking) {
      _pendingPins.add(pin); // testé dès la fin de la vérification en cours
      return;
    }
    _checking = true;
    try {
      String? next = pin;
      while (next != null) {
        // AppLock.check (pas classify) : compte cette tentative, voir le commentaire de classe.
        final r = await AppLock.check(next);
        if (!mounted) return;
        if (r == PinResult.ok) {
          _pendingPins.clear();
          _set('', '0');
          widget.onUnlocked();
          return;
        }
        if (r == PinResult.duress || r == PinResult.exhausted) {
          _pendingPins.clear();
          _set('', '0');
          await widget.onWipe();
          return;
        }
        // PinResult.wrong : rien, reste affiché comme un calcul normal (pas d'indice d'échec).
        next = _pendingPins.isEmpty ? null : _pendingPins.removeAt(0);
      }
    } catch (_) {
      // Keystore indisponible ([KeystoreUnavailable], levée par [AppLock.check] AVANT tout
      // comptage d'échec : aucune tentative consommée), etc. : la calculatrice reste une
      // calculatrice, sans aucun indice. Une relance complète de l'appli est nécessaire.
      _pendingPins.clear();
    } finally {
      _checking = false;
    }
  }

  void _set(String input, String display) => setState(() {
        _input = input;
        _display = display;
      });

  // ---------------------------------------------------------------------------------------------
  // Interface
  // ---------------------------------------------------------------------------------------------

  static const _bg = Color(0xFF17171C);
  static const _key = Color(0xFF2C2C2E);
  static const _accent = Color(0xFFFF9F0A);

  Widget _button(String label, {Color fg = Colors.white, Color bg = _key, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(40),
            child: InkWell(
              borderRadius: BorderRadius.circular(40),
              onTap: () => _press(label),
              child: SizedBox(
                height: 72,
                child: Center(
                  child: Text(label, style: TextStyle(fontSize: 28, color: fg, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(List<Widget> children) => Row(children: children);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              alignment: Alignment.bottomRight,
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomRight,
                child: Text(
                  _display,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 64, color: Colors.white, fontWeight: FontWeight.w300),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(children: [
              _row([
                _button('C', fg: Colors.black, bg: const Color(0xFFA5A5A5)),
                _button('⌫', fg: Colors.black, bg: const Color(0xFFA5A5A5)),
                _button('±', fg: Colors.black, bg: const Color(0xFFA5A5A5)),
                _button('÷', bg: _accent),
              ]),
              _row([_button('7'), _button('8'), _button('9'), _button('×', bg: _accent)]),
              _row([_button('4'), _button('5'), _button('6'), _button('−', bg: _accent)]),
              _row([_button('1'), _button('2'), _button('3'), _button('+', bg: _accent)]),
              _row([_button('0', flex: 2), _button(','), _button('=', bg: _accent)]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Évaluateur arithmétique minimal (shunting-yard). Retourne null si l'expression est invalide
/// ou si le résultat n'est pas fini (division par zéro…).
class _Calc {
  static double? evaluate(String src) {
    final tokens = _tokenize(src);
    if (tokens == null || tokens.isEmpty) return null;

    const prec = {'+': 1, '−': 1, '×': 2, '÷': 2, 'neg': 3};
    final out = <Object>[];
    final ops = <String>[];
    for (final t in tokens) {
      if (t is double) {
        out.add(t);
      } else {
        final op = t as String;
        while (ops.isNotEmpty && op != 'neg' && prec[ops.last]! >= prec[op]!) {
          out.add(ops.removeLast());
        }
        ops.add(op);
      }
    }
    while (ops.isNotEmpty) {
      out.add(ops.removeLast());
    }

    final st = <double>[];
    for (final t in out) {
      if (t is double) {
        st.add(t);
        continue;
      }
      if (t == 'neg') {
        if (st.isEmpty) return null;
        st.add(-st.removeLast());
        continue;
      }
      if (st.length < 2) return null;
      final b = st.removeLast(), a = st.removeLast();
      st.add(switch (t) {
        '+' => a + b,
        '−' => a - b,
        '×' => a * b,
        _ => a / b,
      });
    }
    if (st.length != 1 || !st.single.isFinite) return null;
    return st.single;
  }

  static List<Object>? _tokenize(String s) {
    final tokens = <Object>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if ('0123456789,'.contains(c)) {
        final start = i;
        while (i < s.length && '0123456789,'.contains(s[i])) {
          i++;
        }
        final n = double.tryParse(s.substring(start, i).replaceAll(',', '.'));
        if (n == null) return null;
        tokens.add(n);
        continue;
      }
      if ('+−×÷'.contains(c)) {
        final unary = tokens.isEmpty || tokens.last is String;
        if (unary) {
          if (c != '−') return null;
          tokens.add('neg');
        } else {
          tokens.add(c);
        }
        i++;
        continue;
      }
      return null;
    }
    if (tokens.isEmpty || tokens.last is String) return null; // « 5+ » incomplet
    return tokens;
  }

  /// Format français : virgule décimale, 10 chiffres significatifs, notation scientifique au-delà.
  static String format(double v) {
    if (v == 0) return '0'; // évite « -0 »
    if (v == v.truncateToDouble() && v.abs() < 1e15) {
      return v.toStringAsFixed(0).replaceFirst('-', '−');
    }
    var s = v.abs() >= 1e15 || v.abs() < 1e-9 ? v.toStringAsExponential(6) : v.toStringAsPrecision(10);
    if (s.contains('.') && !s.contains('e')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s.replaceAll('.', ',').replaceFirst('-', '−');
  }
}
