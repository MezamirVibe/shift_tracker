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

  final _lastName = TextEditingController();
  final _firstName = TextEditingController();
  final _middleName = TextEditingController();

  final _employeesStorage = EmployeesStorage();
  final _structureStorage = StructureStorage();
  final AuthService _auth = AuthService.instance;

  bool _loadingLists = true;

  List<EmployeeModel> _employees = [];
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  String? _roleId = BuiltInRoleIds.worker;

  String? _departmentId;
  String? _groupId;
  String? _employeeId;

  bool _createEmployeeForSelfScope = true;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _loadLists();
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _login.dispose();
    _pass.dispose();
    _lastName.dispose();
    _firstName.dispose();
    _middleName.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;

    final roles = _auth.roles;
    final hasCurrentRole =
        _roleId != null && roles.any((r) => r.id == _roleId);

    if (!hasCurrentRole) {
      final fallbackRoleId = roles.isNotEmpty ? roles.first.id : null;
      setState(() {
        _roleId = fallbackRoleId;
        _departmentId = null;
        _groupId = null;
        _employeeId = null;
        _createEmployeeForSelfScope =
            _auth.roleById(_roleId)?.scopeKind == ScopeKind.self;
      });
      return;
    }

    setState(() {});
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _loadLists() async {
    if (mounted) {
      setState(() => _loadingLists = true);
    }

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

  AppRole? _selectedRole(AuthService auth) {
    if (_roleId == null) return null;
    return auth.roleById(_roleId);
  }

  void _resetBindingsForRole(AppRole? role) {
    _departmentId = null;
    _groupId = null;
    _employeeId = null;
    _createEmployeeForSelfScope = role?.scopeKind == ScopeKind.self;
  }

  List<GroupModel> _groupsForDepartment(String? depId) {
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  DepartmentModel? _findDepartment(String? depId) {
    if (depId == null) return null;
    for (final d in _departments) {
      if (d.id == depId) return d;
    }
    return null;
  }

  GroupModel? _findGroup(String? groupId) {
    if (groupId == null) return null;
    for (final g in _groups) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  EmployeeModel? _findEmployee(String? employeeId) {
    if (employeeId == null) return null;
    for (final e in _employees) {
      if (e.id == employeeId) return e;
    }
    return null;
  }

  String _bindingSummaryForUser(
    String? depId,
    String? groupId,
    String? empId,
    AppRole? role,
  ) {
    if (role == null) return 'Роль не найдена';

    switch (role.scopeKind) {
      case ScopeKind.all:
        return 'Привязка не требуется';

      case ScopeKind.department:
        final dep = _findDepartment(depId);
        return 'Подразделение: ${dep?.name ?? '—'}';

      case ScopeKind.group:
        final group = _findGroup(groupId);
        final dep = _findDepartment(group?.departmentId);
        if (group == null) return 'Группа: —';
        return dep == null
            ? 'Группа: ${group.name}'
            : 'Группа: ${group.name} • ${dep.name}';

      case ScopeKind.self:
        final employee = _findEmployee(empId);
        return 'Сотрудник: ${employee?.fullName ?? '—'}';
    }
  }

  String _normalizeFullName(
    String lastName,
    String firstName,
    String middleName,
  ) {
    return [lastName.trim(), firstName.trim(), middleName.trim()]
        .where((x) => x.isNotEmpty)
        .join(' ');
  }

  bool _validateCreate(AuthService auth) {
    final login = _login.text.trim();
    final pass = _pass.text;
    final lastName = _lastName.text.trim();
    final firstName = _firstName.text.trim();
    final role = _selectedRole(auth);

    if (role == null) {
      _snack('Выбери роль');
      return false;
    }

    if (login.isEmpty) {
      _snack('Логин пустой');
      return false;
    }

    if (pass.length < 4) {
      _snack('Пароль минимум 4 символа');
      return false;
    }

    if (lastName.isEmpty || firstName.isEmpty) {
      _snack('Заполни минимум фамилию и имя');
      return false;
    }

    switch (role.scopeKind) {
      case ScopeKind.all:
        return true;

      case ScopeKind.department:
        if (_departmentId == null || _departmentId!.isEmpty) {
          _snack(auth.requiredBindingHintByRoleId(role.id));
          return false;
        }
        return true;

      case ScopeKind.group:
        if (_groupId == null || _groupId!.isEmpty) {
          _snack(auth.requiredBindingHintByRoleId(role.id));
          return false;
        }
        return true;

      case ScopeKind.self:
        if (_createEmployeeForSelfScope) {
          if (_departmentId == null ||
              _departmentId!.isEmpty ||
              _groupId == null ||
              _groupId!.isEmpty) {
            _snack(
              'Для нового сотрудника укажи подразделение и группу. Тогда он сразу появится в списке сотрудников.',
            );
            return false;
          }
        } else {
          if (_employeeId == null || _employeeId!.isEmpty) {
            _snack(auth.requiredBindingHintByRoleId(role.id));
            return false;
          }
        }
        return true;
    }
  }

  Future<void> _create() async {
    final auth = _auth;
    final role = _selectedRole(auth);
    if (role == null) {
      _snack('Роль не выбрана');
      return;
    }

    if (!_validateCreate(auth)) return;

    final ok = await auth.createUser(
      login: _login.text.trim(),
      password: _pass.text,
      roleId: role.id,
      lastName: _lastName.text.trim(),
      firstName: _firstName.text.trim(),
      middleName: _middleName.text.trim(),
      departmentId: (role.scopeKind == ScopeKind.department ||
              (role.scopeKind == ScopeKind.self && _createEmployeeForSelfScope))
          ? _departmentId
          : null,
      groupId: (role.scopeKind == ScopeKind.group ||
              (role.scopeKind == ScopeKind.self && _createEmployeeForSelfScope))
          ? _groupId
          : null,
      employeeId:
          (role.scopeKind == ScopeKind.self && !_createEmployeeForSelfScope)
              ? _employeeId
              : null,
      createEmployeeForWorker:
          role.scopeKind == ScopeKind.self && _createEmployeeForSelfScope,
      employeePosition: role.name,
      employeeSalary: 0,
      employeeBonus: 0,
      employeeScheduleType: ScheduleType.twoTwo,
      employeeScheduleStartDate: DateTime.now(),
      employeeShiftHours: 12,
      employeeBreakHours: 1,
    );

    if (!mounted) return;

    if (!ok) {
      _snack('Не удалось создать пользователя');
      return;
    }

    _login.clear();
    _pass.clear();
    _lastName.clear();
    _firstName.clear();
    _middleName.clear();

    final fallbackWorkerRole = auth.roleById(BuiltInRoleIds.worker);
    final firstRoleId = auth.roles.isNotEmpty ? auth.roles.first.id : null;

    setState(() {
      _roleId = fallbackWorkerRole?.id ?? firstRoleId;
      _departmentId = null;
      _groupId = null;
      _employeeId = null;
      _createEmployeeForSelfScope = true;
    });

    await _loadLists();

    if (!mounted) return;
    _snack('Пользователь создан');
  }

  Future<void> _deleteUser(String userId, String login) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить пользователя?'),
        content: Text('Удалить "$login"?'),
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

    if (ok != true) return;

    final deleted = await _auth.deleteUser(userId);

    if (!mounted) return;

    if (!deleted) {
      _snack('Нельзя удалить этого пользователя');
      return;
    }

    _snack('Удалено');
  }

  Future<void> _editUserDialog(String userId) async {
    final auth = _auth;
    final user = auth.users.where((x) => x.id == userId).firstOrNull;
    if (user == null) return;

    String roleId = user.roleId;
    String? depId = user.departmentId;
    String? groupId = user.groupId;
    String? empId = user.employeeId;

    String lastName = user.lastName;
    String firstName = user.firstName;
    String middleName = user.middleName;

    final lastNameCtrl = TextEditingController(text: lastName);
    final firstNameCtrl = TextEditingController(text: firstName);
    final middleNameCtrl = TextEditingController(text: middleName);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            final currentRole = auth.roleById(roleId);
            final groupsForDep = _groupsForDepartment(depId);

            Widget bindingEditor() {
              if (currentRole == null) {
                return const Text('Роль не найдена');
              }

              switch (currentRole.scopeKind) {
                case ScopeKind.all:
                  return const Text('Для этой роли привязка не требуется');

                case ScopeKind.department:
                  return DropdownButtonFormField<String?>(
                    initialValue: depId,
                    decoration: const InputDecoration(
                      labelText: 'Подразделение',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('— выбери подразделение —'),
                      ),
                      ..._departments.map(
                        (d) => DropdownMenuItem<String?>(
                          value: d.id,
                          child: Text(d.name),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setLocal(() {
                        depId = value;
                      });
                    },
                  );

                case ScopeKind.group:
                  return Column(
                    children: [
                      DropdownButtonFormField<String?>(
                        initialValue: depId,
                        decoration: const InputDecoration(
                          labelText: 'Подразделение',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('— выбери подразделение —'),
                          ),
                          ..._departments.map(
                            (d) => DropdownMenuItem<String?>(
                              value: d.id,
                              child: Text(d.name),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setLocal(() {
                            depId = value;
                            groupId = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String?>(
                        initialValue: groupId,
                        decoration: const InputDecoration(
                          labelText: 'Группа',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('— выбери группу —'),
                          ),
                          ...groupsForDep.map(
                            (g) => DropdownMenuItem<String?>(
                              value: g.id,
                              child: Text(g.name),
                            ),
                          ),
                        ],
                        onChanged: depId == null
                            ? null
                            : (value) {
                                setLocal(() {
                                  groupId = value;
                                });
                              },
                      ),
                    ],
                  );

                case ScopeKind.self:
                  return DropdownButtonFormField<String?>(
                    initialValue: empId,
                    decoration: const InputDecoration(
                      labelText: 'Сотрудник',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('— выбери сотрудника —'),
                      ),
                      ..._employees.map(
                        (e) => DropdownMenuItem<String?>(
                          value: e.id,
                          child: Text('${e.fullName} • ${e.position}'),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setLocal(() {
                        empId = value;
                      });
                    },
                  );
              }
            }

            return AlertDialog(
              title: Text('Пользователь: ${user.login}'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: lastNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Фамилия',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: firstNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Имя',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: middleNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Отчество',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: roleId,
                        decoration: const InputDecoration(
                          labelText: 'Роль',
                          border: OutlineInputBorder(),
                        ),
                        items: auth.roles
                            .map(
                              (r) => DropdownMenuItem<String>(
                                value: r.id,
                                child: Text(r.name),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;

                          setLocal(() {
                            roleId = value;
                            depId = null;
                            groupId = null;
                            empId = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      bindingEditor(),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          auth.requiredBindingHintByRoleId(roleId),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    lastName = lastNameCtrl.text.trim();
                    firstName = firstNameCtrl.text.trim();
                    middleName = middleNameCtrl.text.trim();

                    final selectedRole = auth.roleById(roleId);
                    if (selectedRole == null) {
                      _snack('Роль не найдена');
                      return;
                    }

                    if (lastName.isEmpty || firstName.isEmpty) {
                      _snack('Заполни минимум фамилию и имя');
                      return;
                    }

                    switch (selectedRole.scopeKind) {
                      case ScopeKind.all:
                        break;
                      case ScopeKind.department:
                        if (depId == null || depId!.isEmpty) {
                          _snack(auth.requiredBindingHintByRoleId(roleId));
                          return;
                        }
                        break;
                      case ScopeKind.group:
                        if (groupId == null || groupId!.isEmpty) {
                          _snack(auth.requiredBindingHintByRoleId(roleId));
                          return;
                        }
                        break;
                      case ScopeKind.self:
                        if (empId == null || empId!.isEmpty) {
                          _snack(auth.requiredBindingHintByRoleId(roleId));
                          return;
                        }
                        break;
                    }

                    Navigator.pop(context, true);
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    lastNameCtrl.dispose();
    firstNameCtrl.dispose();
    middleNameCtrl.dispose();

    if (ok != true) return;

    final selectedRole = auth.roleById(roleId);
    if (selectedRole == null) {
      _snack('Роль не найдена');
      return;
    }

    final saved = await auth.updateUserAccess(
      userId: userId,
      roleId: roleId,
      lastName: lastName,
      firstName: firstName,
      middleName: middleName,
      departmentId:
          selectedRole.scopeKind == ScopeKind.department ? depId : null,
      groupId: selectedRole.scopeKind == ScopeKind.group ? groupId : null,
      employeeId: selectedRole.scopeKind == ScopeKind.self ? empId : null,
    );

    if (!mounted) return;

    if (!saved) {
      _snack('Не удалось сохранить');
      return;
    }

    _snack('Сохранено');
  }

  Widget _selfScopeCreateMode(AppRole role) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Сразу создать сотрудника'),
              subtitle: const Text(
                'Рекомендуется: пользователь появится и в системе доступа, и в списке сотрудников.',
              ),
              value: _createEmployeeForSelfScope,
              onChanged: (value) {
                setState(() {
                  _createEmployeeForSelfScope = value;
                  _departmentId = null;
                  _groupId = null;
                  _employeeId = null;
                });
              },
            ),
            const SizedBox(height: 8),
            if (_createEmployeeForSelfScope) ...[
              DropdownButtonFormField<String?>(
                initialValue: _departmentId,
                decoration: const InputDecoration(
                  labelText: 'Подразделение нового сотрудника',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— выбери подразделение —'),
                  ),
                  ..._departments.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d.id,
                      child: Text(d.name),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _departmentId = value;
                  _groupId = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _groupId,
                decoration: const InputDecoration(
                  labelText: 'Группа нового сотрудника',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— выбери группу —'),
                  ),
                  ..._groupsForDepartment(_departmentId).map(
                    (g) => DropdownMenuItem<String?>(
                      value: g.id,
                      child: Text(g.name),
                    ),
                  ),
                ],
                onChanged: _departmentId == null
                    ? null
                    : (value) => setState(() => _groupId = value),
              ),
            ] else ...[
              DropdownButtonFormField<String?>(
                initialValue: _employeeId,
                decoration: const InputDecoration(
                  labelText: 'Привязать к существующему сотруднику',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— выбери сотрудника —'),
                  ),
                  ..._employees.map(
                    (e) => DropdownMenuItem<String?>(
                      value: e.id,
                      child: Text('${e.fullName} • ${e.position}'),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _employeeId = value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bindingEditorForCreate() {
    final auth = _auth;
    final role = _selectedRole(auth);

    if (_loadingLists) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }

    if (role == null) {
      return const Text('Выбери роль');
    }

    switch (role.scopeKind) {
      case ScopeKind.all:
        return const Text('Для этой роли привязка не требуется');

      case ScopeKind.department:
        return DropdownButtonFormField<String?>(
          initialValue: _departmentId,
          decoration: const InputDecoration(
            labelText: 'Подразделение',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('— выбери подразделение —'),
            ),
            ..._departments.map(
              (d) => DropdownMenuItem<String?>(
                value: d.id,
                child: Text(d.name),
              ),
            ),
          ],
          onChanged: (value) => setState(() => _departmentId = value),
        );

      case ScopeKind.group:
        final groups = _groupsForDepartment(_departmentId);

        return Column(
          children: [
            DropdownButtonFormField<String?>(
              initialValue: _departmentId,
              decoration: const InputDecoration(
                labelText: 'Подразделение',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('— выбери подразделение —'),
                ),
                ..._departments.map(
                  (d) => DropdownMenuItem<String?>(
                    value: d.id,
                    child: Text(d.name),
                  ),
                ),
              ],
              onChanged: (value) => setState(() {
                _departmentId = value;
                _groupId = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _groupId,
              decoration: const InputDecoration(
                labelText: 'Группа',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('— выбери группу —'),
                ),
                ...groups.map(
                  (g) => DropdownMenuItem<String?>(
                    value: g.id,
                    child: Text(g.name),
                  ),
                ),
              ],
              onChanged: _departmentId == null
                  ? null
                  : (value) => setState(() => _groupId = value),
            ),
          ],
        );

      case ScopeKind.self:
        return _selfScopeCreateMode(role);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = _auth;
    final roles = auth.roles.toList()..sort((a, b) => a.name.compareTo(b.name));

    if (_roleId != null && roles.every((r) => r.id != _roleId)) {
      _roleId = roles.isNotEmpty ? roles.first.id : null;
      _resetBindingsForRole(auth.roleById(_roleId));
    }

    final users = auth.users.toList()
      ..sort((a, b) {
        final byName = a.fullName.compareTo(b.fullName);
        if (byName != 0) return byName;
        return a.login.compareTo(b.login);
      });

    final selectedRole = _selectedRole(auth);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Создать пользователя',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _lastName,
                  decoration: const InputDecoration(
                    labelText: 'Фамилия',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _firstName,
                  decoration: const InputDecoration(
                    labelText: 'Имя',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _middleName,
                  decoration: const InputDecoration(
                    labelText: 'Отчество',
                    border: OutlineInputBorder(),
                  ),
                ),
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
                DropdownButtonFormField<String>(
                  initialValue: _roleId,
                  decoration: const InputDecoration(
                    labelText: 'Роль',
                    border: OutlineInputBorder(),
                  ),
                  items: roles
                      .map(
                        (r) => DropdownMenuItem<String>(
                          value: r.id,
                          child: Text(r.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _roleId = value;
                      _resetBindingsForRole(auth.roleById(value));
                    });
                  },
                ),
                const SizedBox(height: 12),
                _bindingEditorForCreate(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    selectedRole?.scopeKind == ScopeKind.self &&
                            _createEmployeeForSelfScope
                        ? 'Для роли "${selectedRole?.name ?? ''}" будет автоматически создан сотрудник: "${_normalizeFullName(_lastName.text, _firstName.text, _middleName.text)}".'
                        : auth.requiredBindingHintByRoleId(_roleId),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _create,
                      child: const Text('Создать'),
                    ),
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
        Text(
          'Пользователи',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (users.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Пользователей пока нет'),
            ),
          )
        else
          ...users.map((u) {
            final isMe = auth.currentUser?.id == u.id;
            final role = auth.roleById(u.roleId);
            final binding = _bindingSummaryForUser(
              u.departmentId,
              u.groupId,
              u.employeeId,
              role,
            );

            return Card(
              child: ListTile(
                title: Text(u.fullName),
                subtitle: Text(
                  '${u.login} • ${role?.name ?? u.roleId}\n$binding',
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Роль и привязка',
                      icon: const Icon(Icons.manage_accounts_outlined),
                      onPressed: () => _editUserDialog(u.id),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: (u.roleId == BuiltInRoleIds.superAdmin || isMe)
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}