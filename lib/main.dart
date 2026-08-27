import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:keykeep_passwords/data/vault_repository.dart';
import 'package:keykeep_passwords/ui/vault_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KeyKeepApp(repository: VaultRepository()));
}

class KeyKeepApp extends StatefulWidget {
  const KeyKeepApp({super.key, required this.repository});

  final VaultRepository repository;

  @override
  State<KeyKeepApp> createState() => _KeyKeepAppState();
}

class _KeyKeepAppState extends State<KeyKeepApp> {
  static const _invertedColorsKey = 'ui_inverted_colors';
  final _storage = const FlutterSecureStorage();
  var _invertedColors = false;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    final value = await _storage.read(key: _invertedColorsKey);
    if (mounted) setState(() => _invertedColors = value == 'true');
  }

  Future<void> _setInvertedColors(bool enabled) async {
    await _storage.write(key: _invertedColorsKey, value: enabled.toString());
    if (mounted) setState(() => _invertedColors = enabled);
  }

  static const _accent = Color(0xFF2D6CDF);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'KeyKeep',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: _invertedColors ? ThemeMode.dark : ThemeMode.light,
    home: VaultApp(
      repository: widget.repository,
      invertedColors: _invertedColors,
      onSetInvertedColors: _setInvertedColors,
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: _accent,
      onPrimary: Colors.white,
      primaryContainer: dark
          ? const Color(0xFF17233B)
          : const Color(0xFFEAF0FF),
      onPrimaryContainer: dark
          ? const Color(0xFFDCE7FF)
          : const Color(0xFF0D306D),
      secondary: dark ? const Color(0xFFD7D7D7) : const Color(0xFF3E3E3E),
      onSecondary: dark ? Colors.black : Colors.white,
      error: const Color(0xFFB3261E),
      onError: Colors.white,
      surface: dark ? const Color(0xFF121212) : Colors.white,
      onSurface: dark ? const Color(0xFFE8E8E8) : const Color(0xFF171717),
      outline: dark ? const Color(0xFF777777) : const Color(0xFFB5B5B5),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF1A1A1A) : const Color(0xFFF7F7F7),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline.withValues(alpha: 0.28),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _accent, width: 2),
        ),
      ),
    );
  }
}
