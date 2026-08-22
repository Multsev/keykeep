import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keykeep_passwords/data/vault_repository.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/domain/vault_folder.dart';
import 'package:keykeep_passwords/services/kdbx_vault_codec.dart';
import 'package:keykeep_passwords/ui/password_editor.dart';

class VaultApp extends StatefulWidget {
  const VaultApp({super.key, required this.repository});

  final VaultRepository repository;

  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> with WidgetsBindingObserver {
  bool? _hasMasterPin;
  var _unlocked = false;
  List<PasswordEntry> _entries = [];
  List<VaultFolder> _folders = const [];
  String _query = '';
  String _folderId = 'root';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && mounted) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _load() async {
    final hasPin = await widget.repository.hasMasterPin();
    if (!mounted) return;
    setState(() {
      _hasMasterPin = hasPin;
      _unlocked = false;
    });
  }

  Future<void> _unlock(String pin) async {
    if (!await widget.repository.unlock(pin)) {
      throw StateError('Неверный PIN');
    }
    final entries = await widget.repository.loadEntries();
    final folders = await widget.repository.loadFolders();
    if (mounted) {
      setState(() {
        _entries = entries;
        _folders = folders;
        _unlocked = true;
      });
    }
  }

  Future<void> _save(PasswordEntry entry) async {
    final index = _entries.indexWhere((item) => item.id == entry.id);
    setState(() {
      if (index < 0) {
        _entries = [..._entries, entry];
      } else {
        _entries = [..._entries]..[index] = entry;
      }
    });
    await widget.repository.saveEntries(_entries);
  }

  Future<void> _edit([PasswordEntry? entry]) async {
    final saved = await Navigator.push<PasswordEntry>(
      context,
      MaterialPageRoute(
        builder: (_) => PasswordEditor(folders: _folders, entry: entry),
      ),
    );
    if (saved != null) await _save(saved);
  }

  Future<void> _delete(PasswordEntry entry) async {
    setState(
      () => _entries = _entries.where((item) => item.id != entry.id).toList(),
    );
    await widget.repository.saveEntries(_entries);
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новая папка'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final folder = VaultFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
    );
    setState(() => _folders = [..._folders, folder]);
    await widget.repository.saveFolders(_folders);
  }

  Future<String?> _askKdbxPassword(String title) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Пароль базы KeePass'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return password?.isEmpty ?? true ? null : password;
  }

  Future<void> _exportKdbx() async {
    final password = await _askKdbxPassword('Экспорт KeePass (.kdbx)');
    if (password == null) return;
    try {
      final bytes = await KdbxVaultCodec().export(
        folders: _folders,
        entries: _entries,
        password: password,
      );
      await FilePicker.saveFile(
        dialogTitle: 'Сохранить KeePass-базу',
        fileName: 'KeyKeep.kdbx',
        type: FileType.custom,
        allowedExtensions: const ['kdbx'],
        bytes: bytes,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось экспортировать KDBX.')),
        );
      }
    }
  }

  Future<void> _importKdbx() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['kdbx'],
    );
    if (picked == null) return;
    final password = await _askKdbxPassword('Открыть KeePass (.kdbx)');
    if (password == null) return;
    try {
      final snapshot = await KdbxVaultCodec().import(
        Uint8List.fromList(await picked.readAsBytes()),
        password,
      );
      setState(() {
        _folders = snapshot.folders;
        _entries = snapshot.entries;
        _folderId = 'root';
      });
      await widget.repository.saveFolders(_folders);
      await widget.repository.saveEntries(_entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('KeePass-база импортирована.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть KDBX: проверьте пароль и файл.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPin = _hasMasterPin;
    if (hasPin == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!hasPin) {
      return _CreatePinScreen(
        onCreated: (pin) async {
          await widget.repository.createMasterPin(pin);
          if (mounted) await _load();
        },
      );
    }
    return _unlocked ? _vault(context) : _UnlockScreen(onUnlock: _unlock);
  }

  Widget _vault(BuildContext context) {
    final visible = _entries.where((entry) {
      final searchable = '${entry.title} ${entry.username} ${entry.website}';
      return (_folderId == 'root' || entry.folderId == _folderId) &&
          searchable.toLowerCase().contains(_query.toLowerCase());
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('KeyKeep'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'import') _importKdbx();
              if (value == 'export') _exportKdbx();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'import',
                child: Text('Импорт KeePass (.kdbx)'),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text('Экспорт KeePass (.kdbx)'),
              ),
            ],
          ),
          IconButton(
            onPressed: () => setState(() => _unlocked = false),
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Заблокировать',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('Запись'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              leading: const Icon(Icons.search),
              hintText: 'Поиск в хранилище',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final folder in _folders)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(folder.name),
                      selected: _folderId == folder.id,
                      onSelected: (_) => setState(() => _folderId = folder.id),
                    ),
                  ),
                IconButton(
                  onPressed: _addFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: 'Новая папка',
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _entries.isEmpty
                          ? 'Хранилище пока пустое\nДобавьте первую учётную запись.'
                          : 'Ничего не найдено',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) => _EntryTile(
                      entry: visible[index],
                      onEdit: () => _edit(visible[index]),
                      onDelete: () => _delete(visible[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _UnlockScreen extends StatefulWidget {
  const _UnlockScreen({required this.onUnlock});
  final Future<void> Function(String) onUnlock;
  @override
  State<_UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<_UnlockScreen> {
  final _pin = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onUnlock(_pin.text);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Gate(
    title: 'Хранилище заблокировано',
    subtitle: 'Введите мастер‑PIN, чтобы открыть записи.',
    controller: _pin,
    action: _submit,
    busy: _busy,
    error: _error,
    label: 'Открыть',
  );
}

class _CreatePinScreen extends StatefulWidget {
  const _CreatePinScreen({required this.onCreated});
  final Future<void> Function(String) onCreated;
  @override
  State<_CreatePinScreen> createState() => _CreatePinScreenState();
}

class _CreatePinScreenState extends State<_CreatePinScreen> {
  final _pin = TextEditingController();
  final _confirmation = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    if (pin.length < 6 || pin != _confirmation.text) {
      setState(
        () => _error = pin.length < 6
            ? 'PIN должен содержать не менее 6 символов.'
            : 'PIN-коды не совпадают.',
      );
      return;
    }
    setState(() => _busy = true);
    await widget.onCreated(pin);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => _Gate(
    title: 'Создайте мастер‑PIN',
    subtitle: 'Он защищает доступ к вашему локальному хранилищу. Восстановить его нельзя.',
    controller: _pin,
    confirmation: _confirmation,
    action: _submit,
    busy: _busy,
    error: _error,
    label: 'Создать хранилище',
  );
}

class _Gate extends StatelessWidget {
  const _Gate({
    required this.title,
    required this.subtitle,
    required this.controller,
    this.confirmation,
    required this.action,
    required this.busy,
    required this.error,
    required this.label,
  });
  final String title, subtitle, label;
  final TextEditingController controller;
  final TextEditingController? confirmation;
  final Future<void> Function() action;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield_outlined, size: 64),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(subtitle, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: confirmation == null
                        ? 'Мастер‑PIN'
                        : 'Новый мастер‑PIN',
                    errorText: error,
                  ),
                ),
                if (confirmation != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmation,
                    obscureText: true,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: const InputDecoration(
                      labelText: 'Повторите PIN',
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: busy ? null : action,
                  child: busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _EntryTile extends StatefulWidget {
  const _EntryTile({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });
  final PasswordEntry entry;
  final VoidCallback onEdit, onDelete;
  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  var _revealed = false;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(
      child: Text(
        widget.entry.title.isEmpty ? '?' : widget.entry.title[0].toUpperCase(),
      ),
    ),
    title: Text(widget.entry.title),
    subtitle: Text(_revealed ? widget.entry.password : widget.entry.username),
    onTap: widget.onEdit,
    trailing: Wrap(
      spacing: -8,
      children: [
        IconButton(
          onPressed: () => setState(() => _revealed = !_revealed),
          icon: Icon(
            _revealed
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
        ),
        IconButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.entry.password));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Пароль скопирован')));
          },
          icon: const Icon(Icons.copy_outlined),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'delete') widget.onDelete();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
      ],
    ),
  );
}
