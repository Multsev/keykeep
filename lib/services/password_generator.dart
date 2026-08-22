import 'dart:math';

class PasswordGenerator {
  const PasswordGenerator({this.random});

  final Random? random;
  static const _letters = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
  static const _digits = '23456789';
  static const _symbols = '!@#%&*+-_=';

  String generate({int length = 18, bool symbols = true}) {
    if (length < 8) {
      throw ArgumentError.value(length, 'length', 'Must be at least 8');
    }
    final random = this.random ?? Random.secure();
    final groups = [_letters, _digits, if (symbols) _symbols];
    final characters = <String>[
      for (final group in groups) group[random.nextInt(group.length)],
      for (var i = groups.length; i < length; i++)
        (symbols ? _letters + _digits + _symbols : _letters + _digits)[random
            .nextInt(
              symbols
                  ? _letters.length + _digits.length + _symbols.length
                  : _letters.length + _digits.length,
            )],
    ];
    characters.shuffle(random);
    return characters.join();
  }
}
