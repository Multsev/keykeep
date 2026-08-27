import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/services/contact_formatter.dart';

void main() {
  const formatter = ContactFormatter();

  test('formats Russian phone numbers and normalizes email', () {
    expect(formatter.username('8 999 123 45 67'), '+7 (999) 123-45-67');
    expect(formatter.username('USER@EXAMPLE.TEST '), 'user@example.test');
    expect(formatter.username('admin'), 'admin');
  });

  test('adds HTTPS to a bare website but keeps free text unchanged', () {
    expect(formatter.website('example.test/path'), 'https://example.test/path');
    expect(
      formatter.website('text with example.test'),
      'text with example.test',
    );
    expect(
      formatter.websiteInText('Документация: www.example.test/help'),
      'https://www.example.test/help',
    );
  });
}
