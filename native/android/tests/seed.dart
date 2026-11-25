import 'package:flutter/widgets.dart';
import 'package:keykeep_passwords/data/vault_repository.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = VaultRepository();
  if (await repo.hasMasterPin()) throw StateError('Fixture requires a clean emulator');
  await repo.createMasterPin('123456');
  await repo.saveFolders([VaultFolder(id:'root',name:'Все записи'),VaultFolder(id:'old-folder',name:'Migration folder')]);
  await repo.saveEntries([PasswordEntry(id:'old-id',folderId:'old-folder',title:'MigrationFixture',username:'fixture',password:'synthetic-only',website:'',note:'prior version',updatedAt:DateTime.utc(2026,1,1),customFields:[CustomField(name:'Private',value:'fixture-only',type:CustomFieldType.protected)],history:[PasswordRevision(password:'old',changedAt:DateTime.utc(2025,1,1))])]);
  runApp(const Directionality(textDirection:TextDirection.ltr,child:Text('Fixture ready')));
}
