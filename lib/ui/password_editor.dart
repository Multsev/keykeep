import 'package:flutter/material.dart';
import 'package:keykeep_passwords/domain/password_entry.dart';
import 'package:keykeep_passwords/services/password_generator.dart';

class PasswordEditor extends StatefulWidget {
  const PasswordEditor({super.key, this.entry});

  final PasswordEntry? entry;

  @override
  State<PasswordEditor> createState() => _PasswordEditorState();
}

class _PasswordEditorState extends State<PasswordEditor> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _website = TextEditingController();
  final _note = TextEditingController();
  var _obscure = true;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    if (entry != null) {
      _title.text = entry.title;
      _username.text = entry.username;
      _password.text = entry.password;
      _website.text = entry.website;
      _note.text = entry.note;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _username.dispose();
    _password.dispose();
    _website.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final current = widget.entry;
    final entry = current == null
        ? PasswordEntry(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            title: _title.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
            website: _website.text.trim(),
            note: _note.text.trim(),
            updatedAt: DateTime.now(),
          )
        : current.copyWith(
            title: _title.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
            website: _website.text.trim(),
            note: _note.text.trim(),
          );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.entry == null ? 'Новая запись' : 'Изменить запись'),
      actions: [TextButton(onPressed: _save, child: const Text('Сохранить'))],
    ),
    body: SafeArea(
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Например, Рабочая почта',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Укажите название'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Логин или e-mail'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Укажите логин'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Пароль',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.casino_outlined),
                      tooltip: 'Сгенерировать',
                      onPressed: () => setState(
                        () => _password.text = const PasswordGenerator()
                            .generate(),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
              ),
              validator: (value) =>
                  value == null || value.isEmpty ? 'Укажите пароль' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _website,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Сайт (необязательно)',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Заметка (необязательно)',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
