import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'auth_service.dart';

class BootstrapAdminPage extends StatefulWidget {
  const BootstrapAdminPage({super.key});

  @override
  State<BootstrapAdminPage> createState() => _BootstrapAdminPageState();
}

class _BootstrapAdminPageState extends State<BootstrapAdminPage> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();

  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    final login = _login.text.trim();
    final p1 = _password.text;
    final p2 = _password2.text;

    if (login.isEmpty) {
      setState(() => _error = 'Логин не может быть пустым');
      return;
    }
    if (p1.length < 4) {
      setState(() => _error = 'Пароль слишком короткий (минимум 4 символа)');
      return;
    }
    if (p1 != p2) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final id =
        await AuthService.instance.createFirstAdmin(login: login, password: p1);

    if (!mounted) return;

    setState(() => _busy = false);

    if (id == null) {
      // значит уже кто-то есть — отправим на логин
      context.go('/login');
      return;
    }

    context.go('/');
  }

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _password2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Первый запуск')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Создай суперадмина. Этот пользователь сможет добавлять остальных.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _login,
                  decoration: const InputDecoration(
                    labelText: 'Логин суперадмина',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password2,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Повтори пароль',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _busy ? null : _create(),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _create,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Создать и войти'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
