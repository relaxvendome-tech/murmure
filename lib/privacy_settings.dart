import 'account.dart';

/// Réglages de minimisation des métadonnées, stockés via [Account] comme les autres réglages.
/// Les deux sont DÉSACTIVÉS par défaut (absence de valeur = désactivé ; seule '1' active).
class PrivacySettings {
  PrivacySettings._();

  static const _readReceiptsKey = 'send_read_receipts';
  static const _typingKey = 'send_typing';

  static Future<bool> sendReadReceipts() async => await Account.read(_readReceiptsKey) == '1';
  static Future<void> setSendReadReceipts(bool v) =>
      Account.write(_readReceiptsKey, v ? '1' : '0');

  static Future<bool> sendTyping() async => await Account.read(_typingKey) == '1';
  static Future<void> setSendTyping(bool v) => Account.write(_typingKey, v ? '1' : '0');
}
