import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

class UsersAdminPage extends StatefulWidget {
  const UsersAdminPage({super.key});

  @override
  State<UsersAdminPage> createState() => _UsersAdminPageState();
}

class _UsersAdminPageState extends State<UsersAdminPage> {
  final _login = TextEditingController();
  final _pass = TextEditingController();
  UserRole _role = UserRole.worker;

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final auth = AuthService.instance;
    final login = _login.text.trim();
    final pass = _pass.text;

    if (login.isEmpty) {
      _snack('Логин пустой');
      return;
    }
    if (pass.length < 4) {
      _snack('Пароль минимум 4 символа');
      return;
    }

    final ok = await auth.createUser(login: login, password: pass, role: _role);
    if (!mounted) return;

    if (!ok) {
      _snack('Не удалось создать (возможно логин уже есть или нет прав)');
      return;
    }

    _login.clear();
    _pass.clear();
    _snack('Пользователь создан');
    setState(() {});
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _changeRole(String userId, UserRole role) async {
    final auth = AuthService.instance;
    final ok = await auth.setUserRole(userId: userId, role: role);
    if (!mounted) return;
    if (!ok) {
      _snack('Не удалось сменить роль');
      return;
    }
    setState(() {});
  }

  Future<void> _deleteUser(String userId, String login) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить пользователя?'),
        content: Text('Удалить "$login"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );

    if (ok != true) return;

    final auth = AuthService.instance;
    final deleted = await auth.deleteUser(userId);
    if (!mounted) return;
    if (!deleted) {
      _snack('Нельзя удалить этого пользователя');
      return;
    }
    _snack('Удалено');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final users = auth.users;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Создать пользователя', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _login,
                  decoration: const InputDecoration(
                    labelText: 'Логин',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  value: _role,
                  decoration: const InputDecoration(
                    labelText: 'Роль',
                    border: OutlineInputBorder(),
                  ),
                  items: UserRole.values.map((r) {
                    return DropdownMenuItem(value: r, child: Text(roleLabel(r)));
                  }).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _role = v);
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _create,
                    child: const Text('Создать'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Пользователи', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...users.map((u) {
          final isMe = auth.currentUser?.id == u.id;
          return Card(
            child: ListTile(
              title: Text(u.login),
              subtitle: Text(roleLabel(u.role)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<UserRole>(
                    value: u.role,
                    onChanged: (v) => v == null ? null : _changeRole(u.id, v),
                    items: UserRole.values.map((r) {
                      return DropdownMenuItem(value: r, child: Text(roleLabel(r)));
                    }).toList(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Удалить',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: (u.role == UserRole.superAdmin || isMe)
                        ? null
                        : () => _deleteUser(u.id, u.login),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
