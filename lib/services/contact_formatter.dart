/// Normalizes common contact values without changing unrelated usernames.
class ContactFormatter {
  const ContactFormatter();

  String username(String source) {
    final value = source.trim();
    if (_email.hasMatch(value)) return value.toLowerCase();
    return phone(value) ?? value;
  }

  String? phone(String source) {
    final digits = source.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 11 &&
        (digits.startsWith('7') || digits.startsWith('8'))) {
      final local = digits.substring(1);
      return '+7 (${local.substring(0, 3)}) ${local.substring(3, 6)}-${local.substring(6, 8)}-${local.substring(8)}';
    }
    if (digits.length == 10) {
      return '+7 (${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6, 8)}-${digits.substring(8)}';
    }
    return null;
  }

  String website(String source) {
    final value = source.trim();
    if (value.isEmpty || value.contains(RegExp(r'\s'))) return value;
    if (_url.hasMatch(value) && !value.contains('://')) return 'https://$value';
    return value;
  }

  String? websiteInText(String source) {
    final match = RegExp(
      r'(?:(?:https?://)|(?:www\.))(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[^\s<]*)?',
      caseSensitive: false,
    ).firstMatch(source);
    return match == null ? null : website(match.group(0)!);
  }

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _url = RegExp(
    r'^(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/?#].*)?$',
    caseSensitive: false,
  );
}
