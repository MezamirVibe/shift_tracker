import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

class RolesEditorPage extends StatefulWidget {
  const RolesEditorPage({super.key});

  @override
  State<RolesEditorPage> createState() => _RolesEditorPageState();
}

class _RolesEditorPageState extends State<RolesEditorPage> {
  String? _selectedRoleId;

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final roles = auth.roles.toList()..sort((a, b) => a.name.compareTo(b.name));

    if (roles.isNotEmpty &&
        (_selectedRoleId == null ||
            roles.every((r) => r.id != _selectedRoleId))) {
      _selectedRoleId = roles.first.id;
    }

    final selected = auth.roleById(_selectedRoleId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320,
          child: Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Роли'),
                  subtitle: const Text('Все роли можно редактировать'),
                  trailing: IconButton(
                    tooltip: 'Новая роль',
                    icon: const Icon(Icons.add),
                    onPressed: () => _showCreateRoleDialog(context),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: roles.isEmpty
                      ? const Center(child: Text('Ролей пока нет'))
                      : ListView(
                          children: roles.map((r) {
                            final isCurrentUsersRole =
                                auth.currentUser?.roleId == r.id;

                            return ListTile(
                              selected: r.id == _selectedRoleId,
                              title: Text(r.name),
                              subtitle: Text(
                                isCurrentUsersRole
                                    ? '${scopeKindLabel(r.scopeKind)} • ваша роль'
                                    : scopeKindLabel(r.scopeKind),
                              ),
                              onTap: () => setState(() {
                                _selectedRoleId = r.id;
                              }),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: selected == null
              ? const Card(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Выбери роль слева'),
                    ),
                  ),
                )
              : _RoleDetails(
                  key: ValueKey(selected.id),
                  role: selected,
                  onChanged: () {
                    if (!mounted) return;
                    setState(() {});
                  },
                  onDelete: () async {
                    final auth = AuthService.instance;
                    final isCurrentUsersRole =
                        auth.currentUser?.roleId == selected.id;

                    if (isCurrentUsersRole) {
                      _snack('Нельзя удалить роль, которая назначена вам сейчас');
                      return;
                    }

                    final ok = await _confirmDeleteRole(selected);
                    if (!mounted || ok != true) return;

                    final deleted = await auth.deleteRole(selected.id);
                    if (!mounted) return;

                    if (!deleted) {
                      _snack(
                        'Нельзя удалить роль. Возможно, она уже используется пользователями.',
                      );
                      return;
                    }

                    final rest = auth.roles.toList()
                      ..sort((a, b) => a.name.compareTo(b.name));

                    setState(() {
                      _selectedRoleId = rest.isEmpty ? null : rest.first.id;
                    });

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _snack('Роль удалена');
                    });
                  },
                ),
        ),
      ],
    );
  }

  Future<bool?> _confirmDeleteRole(AppRole role) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить роль?'),
        content: Text('Удалить роль "${role.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateRoleDialog(BuildContext context) async {
    final auth = AuthService.instance;
    final nameCtrl = TextEditingController();
    ScopeKind scope = ScopeKind.self;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setLocal) {
            return AlertDialog(
              title: const Text('Новая роль'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Название роли',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ScopeKind>(
                      initialValue: scope,
                      decoration: const InputDecoration(
                        labelText: 'Scope',
                        border: OutlineInputBorder(),
                      ),
                      items: ScopeKind.values
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(scopeKindLabel(s)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setLocal(() => scope = value);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Создать'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) {
      nameCtrl.dispose();
      return;
    }

    final roleName = nameCtrl.text.trim();
    nameCtrl.dispose();

    final createdRoleId = await auth.createRole(
      name: roleName,
      scopeKind: scope,
    );

    if (!mounted) return;

    if (createdRoleId == null) {
      _snack('Не удалось создать роль');
      return;
    }

    setState(() {
      _selectedRoleId = createdRoleId;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _snack('Роль создана');
    });
  }
}

class _RoleDetails extends StatefulWidget {
  final AppRole role;
  final VoidCallback onChanged;
  final Future<void> Function() onDelete;

  const _RoleDetails({
    super.key,
    required this.role,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_RoleDetails> createState() => _RoleDetailsState();
}

class _RoleDetailsState extends State<_RoleDetails> {
  late final TextEditingController _nameCtrl;
  late ScopeKind _scopeKind;
  late Set<AppPermission> _permissions;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.role.name);
    _scopeKind = widget.role.scopeKind;
    _permissions = Set<AppPermission>.from(widget.role.permissions);
  }

  @override
  void didUpdateWidget(covariant _RoleDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role.id != widget.role.id) {
      _nameCtrl.text = widget.role.name;
      _scopeKind = widget.role.scopeKind;
      _permissions = Set<AppPermission>.from(widget.role.permissions);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    if (_saving) return;

    final auth = AuthService.instance;
    final isCurrentUsersRole = auth.currentUser?.roleId == widget.role.id;

    if (isCurrentUsersRole) {
      _snack('Свою текущую роль пока редактировать нельзя');
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    final roleId = widget.role.id;
    final roleName = _nameCtrl.text.trim();
    final scopeKind = _scopeKind;
    final permissions = Set<AppPermission>.from(_permissions);

    setState(() {
      _saving = true;
    });

    final ok = await auth.updateRole(
      id: roleId,
      name: roleName,
      scopeKind: scopeKind,
      permissions: permissions,
    );

    if (!mounted) return;

    setState(() {
      _saving = false;
    });

    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить роль')),
      );
      return;
    }

    widget.onChanged();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      messenger?.showSnackBar(
        const SnackBar(content: Text('Сохранено')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final isCurrentUsersRole = auth.currentUser?.roleId == widget.role.id;

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Роль', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ScopeKind>(
                  initialValue: _scopeKind,
                  decoration: const InputDecoration(
                    labelText: 'Scope',
                    border: OutlineInputBorder(),
                  ),
                  items: ScopeKind.values
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(scopeKindLabel(s)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _scopeKind = value);
                  },
                ),
                if (isCurrentUsersRole) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Это ваша текущая роль. Чтобы избежать сбоев, её редактирование временно запрещено.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      onPressed:
                          (_saving || isCurrentUsersRole) ? null : _save,
                      child: Text(_saving ? 'Сохраняем...' : 'Сохранить'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: (_saving || isCurrentUsersRole)
                          ? null
                          : widget.onDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Удалить роль'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: AppPermission.values.map((p) {
              final enabled = _permissions.contains(p);

              return SwitchListTile(
                title: Text(permLabel(p)),
                value: enabled,
                onChanged: (_saving || isCurrentUsersRole)
                    ? null
                    : (v) {
                        setState(() {
                          if (v) {
                            _permissions.add(p);
                          } else {
                            _permissions.remove(p);
                          }
                        });
                      },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}