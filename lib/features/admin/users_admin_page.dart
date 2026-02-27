import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../structure/structure_storage.dart';

class UsersAdminPage extends StatefulWidget {
  const UsersAdminPage({super.key});

  @override
  State<UsersAdminPage> createState() => _UsersAdminPageState();
}

class _UsersAdminPageState extends State<UsersAdminPage> {
  final _login = TextEditingController();
  final _pass = TextEditingController();

  final _employeesStorage = EmployeesStorage();
  final _structureStorage = StructureStorage();

  bool _loadingLists = true;

  List<EmployeeModel> _employees = [];
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  UserRole _role = UserRole.worker;

  String? _departmentId;
  String? _groupId;
  String? _employeeId;

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _loadLists() async {
    setState(() => _loadingLists = true);

    final employees = await _employeesStorage.load();
    final deps = await _structureStorage.loadDepartments();
    final groups = await _structureStorage.loadGroups();

    employees.sort((a, b) => a.fullName.compareTo(b.fullName));
    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    if (!mounted) return;
    setState(() {
      _employees = employees;
      _departments = deps;
      _groups = groups;
      _loadingLists = false;
    });
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _resetBindingsForRole(UserRole r) {
    // обнуляем "не свои" поля
    setState(() {
      switch (r) {
        case UserRole.manager:
          _groupId = null;
          _employeeId = null;
          break;
        case UserRole.master:
          _departmentId = null;
          _employeeId = null;
          break;
        case UserRole.worker:
          _departmentId = null;
          _groupId = null;
          break;
        case UserRole.superAdmin:
          _departmentId = null;
          _groupId = null;
          _employeeId = null;
          break;
      }
    });
  }

  List<GroupModel> _groupsForDep(String? depId) {
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  String _bindingSummaryForUser(AuthService auth, String? depId, String? groupId, String? empId, UserRole role) {
    if (role == UserRole.superAdmin) return 'Привязка не требуется';

    switch (role) {
      case UserRole.manager:
        final d = _departments.where((x) => x.id == depId).cast<DepartmentModel?>().firstOrNull;
        return 'Подразделение: ${d?.name ?? '—'}';
      case UserRole.master:
        final g = _groups.where((x) => x.id == groupId).cast<GroupModel?>().firstOrNull;
        return 'Группа: ${g?.name ?? '—'}';
      case UserRole.worker:
        final e = _employees.where((x) => x.id == empId).cast<EmployeeModel?>().firstOrNull;
        return 'Сотрудник: ${e?.fullName ?? '—'}';
      case UserRole.superAdmin:
        return 'Привязка не требуется';
    }
  }

  bool _isBindingValidForRole(UserRole r, {String? depId, String? groupId, String? empId}) {
    switch (r) {
      case UserRole.manager:
        return depId != null;
      case UserRole.master:
        return groupId != null;
      case UserRole.worker:
        return empId != null;
      case UserRole.superAdmin:
        return true;
    }
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

    if (!_isBindingValidForRole(_role, depId: _departmentId, groupId: _groupId, empId: _employeeId)) {
      _snack(AuthService.instance.requiredBindingHint(_role));
      return;
    }

    final ok = await auth.createUser(
      login: login,
      password: pass,
      role: _role,
      departmentId: _role == UserRole.manager ? _departmentId : null,
      groupId: _role == UserRole.master ? _groupId : null,
      employeeId: _role == UserRole.worker ? _employeeId : null,
    );

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

  Future<void> _editUserDialog(String userId) async {
    final auth = AuthService.instance;
    final u = auth.users.where((x) => x.id == userId).cast<dynamic>().firstOrNull;
    if (u == null) return;

    UserRole role = (u.role as UserRole);

    String? depId = u.departmentId as String?;
    String? groupId = u.groupId as String?;
    String? empId = u.employeeId as String?;

    // нормализация
    if (role == UserRole.manager) {
      groupId = null;
      empId = null;
    } else if (role == UserRole.master) {
      depId = null;
      empId = null;
    } else if (role == UserRole.worker) {
      depId = null;
      groupId = null;
    } else {
      depId = null;
      groupId = null;
      empId = null;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        List<GroupModel> groupsForDep = _groupsForDep(depId);

        Widget bindingWidget() {
          if (role == UserRole.manager) {
            return DropdownButtonFormField<String?>(
              initialValue: depId,
              decoration: const InputDecoration(labelText: 'Подразделение', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('— выбери подразделение —')),
                ..._departments.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
              ],
              onChanged: (v) => depId = v,
            );
          }

          if (role == UserRole.master) {
            return Column(
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: depId,
                  decoration: const InputDecoration(
                    labelText: 'Подразделение (для выбора групп)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— выбери подразделение —')),
                    ..._departments.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
                  ],
                  onChanged: (v) {
                    depId = v;
                    groupId = null;
                    groupsForDep = _groupsForDep(depId);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: groupId,
                  decoration: const InputDecoration(labelText: 'Группа', border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— выбери группу —')),
                    ...groupsForDep.map((g) => DropdownMenuItem<String?>(value: g.id, child: Text(g.name))),
                  ],
                  onChanged: (v) => groupId = v,
                ),
              ],
            );
          }

          if (role == UserRole.worker) {
            return DropdownButtonFormField<String?>(
              initialValue: empId,
              decoration: const InputDecoration(labelText: 'Сотрудник', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('— выбери сотрудника —')),
                ..._employees.map((e) => DropdownMenuItem<String?>(value: e.id, child: Text(e.fullName))),
              ],
              onChanged: (v) => empId = v,
            );
          }

          return const Text('Суперадмин: привязка не требуется');
        }

        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Доступ пользователя'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<UserRole>(
                    initialValue: role,
                    decoration: const InputDecoration(labelText: 'Роль', border: OutlineInputBorder()),
                    items: UserRole.values
                        .map((r) => DropdownMenuItem<UserRole>(value: r, child: Text(roleLabel(r))))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      role = v;

                      // сброс привязок при смене роли
                      if (role == UserRole.manager) {
                        groupId = null;
                        empId = null;
                      } else if (role == UserRole.master) {
                        empId = null;
                        // depId оставим как выбор-основание, groupId сбросим
                        groupId = null;
                      } else if (role == UserRole.worker) {
                        depId = null;
                        groupId = null;
                      } else {
                        depId = null;
                        groupId = null;
                        empId = null;
                      }

                      groupsForDep = _groupsForDep(depId);
                      setLocal(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  bindingWidget(),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      AuthService.instance.requiredBindingHint(role),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
              FilledButton(
                onPressed: () {
                  if (!_isBindingValidForRole(role, depId: depId, groupId: groupId, empId: empId)) {
                    _snack(AuthService.instance.requiredBindingHint(role));
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
      },
    );

    if (ok != true) return;

    final saved = await auth.updateUserAccess(
      userId: userId,
      role: role,
      departmentId: role == UserRole.manager ? depId : null,
      groupId: role == UserRole.master ? groupId : null,
      employeeId: role == UserRole.worker ? empId : null,
    );

    if (!mounted) return;

    if (!saved) {
      _snack('Не удалось сохранить');
      return;
    }
    _snack('Сохранено');
    setState(() {});
  }

  Widget _bindingEditorForCreate() {
    if (_loadingLists) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }

    if (_role == UserRole.manager) {
      return DropdownButtonFormField<String?>(
        initialValue: _departmentId,
        decoration: const InputDecoration(labelText: 'Подразделение', border: OutlineInputBorder()),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('— выбери подразделение —')),
          ..._departments.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
        ],
        onChanged: (v) => setState(() => _departmentId = v),
      );
    }

    if (_role == UserRole.master) {
      final groups = _groupsForDep(_departmentId);
      return Column(
        children: [
          DropdownButtonFormField<String?>(
            initialValue: _departmentId,
            decoration: const InputDecoration(
              labelText: 'Подразделение (для выбора групп)',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('— выбери подразделение —')),
              ..._departments.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
            ],
            onChanged: (v) => setState(() {
              _departmentId = v;
              _groupId = null;
            }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _groupId,
            decoration: const InputDecoration(labelText: 'Группа', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('— выбери группу —')),
              ...groups.map((g) => DropdownMenuItem<String?>(value: g.id, child: Text(g.name))),
            ],
            onChanged: (_departmentId == null) ? null : (v) => setState(() => _groupId = v),
          ),
        ],
      );
    }

    if (_role == UserRole.worker) {
      return DropdownButtonFormField<String?>(
        initialValue: _employeeId,
        decoration: const InputDecoration(labelText: 'Сотрудник', border: OutlineInputBorder()),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('— выбери сотрудника —')),
          ..._employees.map((e) => DropdownMenuItem<String?>(value: e.id, child: Text(e.fullName))),
        ],
        onChanged: (v) => setState(() => _employeeId = v),
      );
    }

    return const Text('Суперадмин: привязка не требуется');
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
                  decoration: const InputDecoration(labelText: 'Логин', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: 'Роль', border: OutlineInputBorder()),
                  items: UserRole.values.map((r) => DropdownMenuItem(value: r, child: Text(roleLabel(r)))).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _role = v);
                    _resetBindingsForRole(v);
                  },
                ),
                const SizedBox(height: 12),
                _bindingEditorForCreate(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(onPressed: _create, child: const Text('Создать')),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _loadLists,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить списки'),
                    ),
                  ],
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

          final binding = _bindingSummaryForUser(auth, u.departmentId, u.groupId, u.employeeId, u.role);

          return Card(
            child: ListTile(
              title: Text(u.login),
              subtitle: Text('${roleLabel(u.role)} • $binding'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Роль/привязка',
                    icon: const Icon(Icons.manage_accounts_outlined),
                    onPressed: () => _editUserDialog(u.id),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: (u.role == UserRole.superAdmin || isMe) ? null : () => _deleteUser(u.id, u.login),
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}