import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

class RolesEditorPage extends StatefulWidget {
  const RolesEditorPage({super.key});

  @override
  State<RolesEditorPage> createState() => _RolesEditorPageState();
}

class _RolesEditorPageState extends State<RolesEditorPage> {
  UserRole _selected = UserRole.manager;

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    // нельзя редактировать superAdmin
    final editableRoles = UserRole.values.where((r) => r != UserRole.superAdmin).toList();

    if (!editableRoles.contains(_selected)) {
      _selected = editableRoles.first;
    }

    final policy = auth.policies[_selected] ??
        RolePolicy(role: _selected, permissions: const <AppPermission>{});

    final perms = AppPermission.values.toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Выбери роль', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  initialValue: _selected,
                  decoration: const InputDecoration(
                    labelText: 'Роль',
                    border: OutlineInputBorder(),
                  ),
                  items: editableRoles.map((r) {
                    return DropdownMenuItem(value: r, child: Text(roleLabel(r)));
                  }).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selected = v);
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Включай/выключай права. Изменения сохраняются сразу.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: perms.map((p) {
              final enabled = policy.permissions.contains(p);
              return SwitchListTile(
                title: Text(permLabel(p)),
                value: enabled,
                onChanged: (v) async {
                  final next = Set<AppPermission>.from(policy.permissions);
                  if (v) {
                    next.add(p);
                  } else {
                    next.remove(p);
                  }

                  final ok = await auth.setRolePolicy(role: _selected, permissions: next);
                  if (!mounted) return;
                  if (!ok) {
                    _snack('Не удалось сохранить');
                    return;
                  }
                  setState(() {});
                },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
