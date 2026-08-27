import 'package:flutter_test/flutter_test.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';

void main() {
  test('keeps all editable values in an immutable revision', () {
    final original = PasswordEntry(
      id: '1',
      title: 'Mail',
      username: 'old@example.test',
      password: 'old-password',
      website: 'old.example.test',
      note: 'old note',
      updatedAt: DateTime(2026),
      customFields: const [
        CustomField(name: 'Account', value: '42', type: CustomFieldType.text),
      ],
    );

    final changed = original.copyWith(
      username: 'new@example.test',
      password: 'new-password',
      note: 'new note',
    );

    expect(changed.history, hasLength(1));
    expect(changed.history.single.values['title'], 'Mail');
    expect(changed.history.single.values['username'], 'old@example.test');
    expect(changed.history.single.password, 'old-password');
    expect(changed.history.single.values['website'], 'old.example.test');
    expect(changed.history.single.values['note'], 'old note');
    expect(changed.history.single.values['customFields'], isNotEmpty);
  });
}
