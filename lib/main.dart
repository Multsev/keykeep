import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:keykeep_passwords/data/vault_repository.dart';
import 'package:keykeep_passwords/ui/vault_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KeyKeepApp(repository: VaultRepository()));
}

class KeyKeepApp extends StatelessWidget {
  const KeyKeepApp({super.key, required this.repository});

  final VaultRepository repository;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'KeyKeep',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF2457A6),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF9CC1FF),
      brightness: Brightness.dark,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    themeMode: ThemeMode.system,
    home: VaultApp(repository: repository),
  );
}
