import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../auth/auth_storage.dart';
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
  final _searchCtrl = TextEditingController();

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
  String _search = '';
  bool _creatingEmployeeAccounts = false;
  int _accountCreationProgress = 0;
  int _accountCreationTotal = 0;
  String? _configuringVisibilityUserId;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _search = _searchCtrl.text.trim().toLowerCase();
      });
    });
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
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
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

  AppRole? _selectedRole() {
    if (_roleId == null) return null;
    return _auth.roleById(_roleId);
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

  Widget _roleHintCard(AppRole? role) {
    if (role == null) return const SizedBox.shrink();

    String text;
    switch (role.scopeKind) {
      case ScopeKind.all:
        text = 'Эта роль видит всё. Дополнительная привязка не требуется.';
        break;
      case ScopeKind.department:
        text =
            'Эта роль видит только одно подразделение. Нужно выбрать подразделение.';
        break;
      case ScopeKind.group:
        text =
            'Эта роль видит только одну группу. Нужно выбрать подразделение и группу.';
        break;
      case ScopeKind.self:
        text =
            'Эта роль видит только себя. Нужно выбрать существующего сотрудника или создать нового автоматически.';
        break;
    }

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  bool _validateCreate() {
    final login = _login.text.trim();
    final pass = _pass.text;
    final lastName = _lastName.text.trim();
    final firstName = _firstName.text.trim();
    final role = _selectedRole();

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
          _snack(_auth.requiredBindingHintByRoleId(role.id));
          return false;
        }
        return true;

      case ScopeKind.group:
        if (_groupId == null || _groupId!.isEmpty) {
          _snack(_auth.requiredBindingHintByRoleId(role.id));
          return false;
        }
        return true;

      case ScopeKind.self:
        if (_createEmployeeForSelfScope) {
          if (_departmentId == null ||
              _departmentId!.isEmpty ||
              _groupId == null ||
              _groupId!.isEmpty) {
            _snack('Для нового сотрудника укажи подразделение и группу.');
            return false;
          }
        } else {
          if (_employeeId == null || _employeeId!.isEmpty) {
            _snack(_auth.requiredBindingHintByRoleId(role.id));
            return false;
          }
        }
        return true;
    }
  }

  Future<void> _create() async {
    final role = _selectedRole();
    if (role == null) {
      _snack('Роль не выбрана');
      return;
    }

    if (!_validateCreate()) return;

    final ok = await _auth.createUser(
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

    setState(() {
      _roleId = BuiltInRoleIds.worker;
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
    setState(() {});
  }

  Future<void> _editUserDialog(String userId) async {
    final user = _auth.users.where((x) => x.id == userId).firstOrNull;
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
            final currentRole = _auth.roleById(roleId);
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
              title: Text('Редактирование: ${user.login}'),
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
                        items: _auth.roles
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
                          _auth.requiredBindingHintByRoleId(roleId),
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

                    final selectedRole = _auth.roleById(roleId);
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
                          _snack(_auth.requiredBindingHintByRoleId(roleId));
                          return;
                        }
                        break;
                      case ScopeKind.group:
                        if (groupId == null || groupId!.isEmpty) {
                          _snack(_auth.requiredBindingHintByRoleId(roleId));
                          return;
                        }
                        break;
                      case ScopeKind.self:
                        if (empId == null || empId!.isEmpty) {
                          _snack(_auth.requiredBindingHintByRoleId(roleId));
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

    final selectedRole = _auth.roleById(roleId);
    if (selectedRole == null) {
      _snack('Роль не найдена');
      return;
    }

    final saved = await _auth.updateUserAccess(
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
    setState(() {});
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
                'Удобный вариант: пользователь появится и в системе доступа, и в списке сотрудников.',
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
    final role = _selectedRole();

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

  List<UserAccount> _filteredUsers(List<UserAccount> users) {
    if (_search.isEmpty) return users;

    return users.where((u) {
      final role = _auth.roleById(u.roleId);
      final binding = _bindingSummaryForUser(
        u.departmentId,
        u.groupId,
        u.employeeId,
        role,
      );

      final haystack =
          '${u.fullName} ${u.login} ${role?.name ?? ''} $binding'.toLowerCase();

      return haystack.contains(_search);
    }).toList();
  }

  List<EmployeeModel> get _employeesWithoutAccounts {
    final linkedIds =
        _auth.users.map((user) => user.employeeId).whereType<String>().toSet();
    return _employees
        .where((employee) => !linkedIds.contains(employee.id))
        .toList()
      ..sort((a, b) => a.fullName.compareTo(b.fullName));
  }

  String _transliterate(String value) {
    const letters = <String, String>{
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'g',
      'д': 'd',
      'е': 'e',
      'ё': 'e',
      'ж': 'zh',
      'з': 'z',
      'и': 'i',
      'й': 'y',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'h',
      'ц': 'ts',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'sch',
      'ъ': '',
      'ы': 'y',
      'ь': '',
      'э': 'e',
      'ю': 'yu',
      'я': 'ya',
    };
    final out = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final character = String.fromCharCode(rune);
      out.write(letters[character] ?? character);
    }
    return out.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _suggestLogin(EmployeeModel employee, Set<String> reserved) {
    final parts = employee.fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final surname = parts.isNotEmpty ? _transliterate(parts.first) : 'user';
    final first = parts.length > 1 ? _transliterate(parts[1]) : '';
    final middle = parts.length > 2 ? _transliterate(parts[2]) : '';
    var base = [
      surname,
      if (first.isNotEmpty) first.substring(0, 1),
      if (middle.isNotEmpty) middle.substring(0, 1),
    ].where((part) => part.isNotEmpty).join();
    if (base.length < 3) base = 'user${employee.id.substring(0, 6)}';

    if (base.length > 80) base = base.substring(0, 80);
    var candidate = '$base${_auth.generateReadableLoginCode()}';
    while (reserved.contains(candidate.toLowerCase())) {
      candidate = '$base${_auth.generateReadableLoginCode()}';
    }
    reserved.add(candidate.toLowerCase());
    return candidate;
  }

  Future<void> _showCredentials(
    List<EmployeeAccountCredentials> credentials, {
    List<String> failed = const [],
  }) async {
    final text = credentials
        .map((item) =>
            '${item.fullName}\nЛогин: ${item.login}\nПароль: ${item.password}')
        .join('\n\n');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          credentials.length == 1
              ? 'Учётная запись создана'
              : 'Создано учётных записей: ${credentials.length}',
        ),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Скопируйте данные и передайте их сотрудникам. Пароль можно будет сменить после входа.',
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(text),
                ),
                if (failed.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Не удалось создать: ${failed.join(', ')}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: text.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Данные скопированы')),
                      );
                    }
                  },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Копировать всё'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  Future<void> _configureHiddenGroups(UserAccount user) async {
    if (_configuringVisibilityUserId != null) return;
    setState(() => _configuringVisibilityUserId = user.id);
    Set<String> hidden;
    try {
      final response = await ApiClient.instance.request(
        'GET',
        '/api/v1/users/${user.id}/hidden-groups',
      ) as Map<String, dynamic>;
      hidden = ((response['hidden_group_ids'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
    } catch (error) {
      if (mounted) {
        setState(() => _configuringVisibilityUserId = null);
        _snack('Не удалось загрузить ограничения: $error');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _configuringVisibilityUserId = null);

    final groups = List<GroupModel>.of(_groups)
      ..sort((a, b) => a.name.compareTo(b.name));
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Доступ к группам: ${user.fullName}'),
          content: SizedBox(
            width: 650,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Отмеченные группы будут скрыты от пользователя на сервере. '
                  'Он не сможет увидеть их сотрудников, график и фактические отметки.',
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: groups.isEmpty
                      ? const Center(child: Text('Группы ещё не созданы.'))
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final group in groups)
                              CheckboxListTile(
                                value: hidden.contains(group.id),
                                title: Text(group.name),
                                subtitle: Text(
                                  _findDepartment(group.departmentId)?.name ??
                                      'Подразделение не указано',
                                ),
                                secondary: const Icon(
                                  Icons.visibility_off_outlined,
                                ),
                                onChanged: (value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      hidden.add(group.id);
                                    } else {
                                      hidden.remove(group.id);
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: hidden.isEmpty
                  ? null
                  : () => setDialogState(() => hidden.clear()),
              child: const Text('Вернуть все группы'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Сохранить ограничения'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    setState(() => _configuringVisibilityUserId = user.id);
    try {
      await ApiClient.instance.request(
        'PUT',
        '/api/v1/users/${user.id}/hidden-groups',
        body: {'hidden_group_ids': hidden.toList()},
      );
      if (mounted) _snack('Доступ к группам обновлён');
    } catch (error) {
      if (mounted) _snack('Не удалось сохранить ограничения: $error');
    } finally {
      if (mounted) setState(() => _configuringVisibilityUserId = null);
    }
  }

  Future<void> _createAccountForOneEmployee() async {
    final available = _employeesWithoutAccounts;
    if (available.isEmpty) {
      _snack('У всех сотрудников уже есть учётные записи');
      return;
    }

    final searchController = TextEditingController();
    final loginController = TextEditingController();
    final passwordController =
        TextEditingController(text: _auth.generateReadablePassword());
    EmployeeModel? selected;
    String query = '';
    final reserved =
        _auth.users.map((user) => user.login.toLowerCase()).toSet();

    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filtered = available
              .where((employee) {
                if (query.isEmpty) return true;
                return '${employee.fullName} ${employee.position}'
                    .toLowerCase()
                    .contains(query);
              })
              .take(12)
              .toList();
          return AlertDialog(
            title: const Text('Создать вход сотруднику'),
            content: SizedBox(
              width: 680,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Найти сотрудника',
                        hintText: 'Введите фамилию или должность',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setDialogState(
                        () => query = value.trim().toLowerCase(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final employee = filtered[index];
                          final isSelected = selected?.id == employee.id;
                          return ListTile(
                            selected: isSelected,
                            leading: Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                            ),
                            title: Text(employee.fullName),
                            subtitle: Text(employee.position),
                            onTap: () {
                              setDialogState(() {
                                selected = employee;
                                loginController.text =
                                    _suggestLogin(employee, {...reserved});
                              });
                            },
                          );
                        },
                      ),
                    ),
                    if (selected != null) ...[
                      const Divider(height: 24),
                      TextField(
                        controller: loginController,
                        decoration: const InputDecoration(
                          labelText: 'Логин',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passwordController,
                        decoration: const InputDecoration(
                          labelText: 'Временный пароль',
                          helperText: 'Минимум 10 символов',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: selected == null ||
                        loginController.text.trim().length < 3 ||
                        passwordController.text.length < 10
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Создать'),
              ),
            ],
          );
        },
      ),
    );

    final employee = selected;
    final login = loginController.text.trim();
    final password = passwordController.text;
    searchController.dispose();
    loginController.dispose();
    passwordController.dispose();
    if (submitted != true || employee == null) return;

    setState(() => _creatingEmployeeAccounts = true);
    final created = await _auth.createAccountForEmployee(
      employee: employee,
      login: login,
      password: password,
    );
    if (!mounted) return;
    setState(() => _creatingEmployeeAccounts = false);
    if (created == null) {
      _snack('Не удалось создать учётную запись. Проверьте логин.');
      return;
    }
    await _showCredentials([created]);
  }

  Future<void> _createAccountsForAllEmployees() async {
    final available = _employeesWithoutAccounts;
    if (available.isEmpty) {
      _snack('У всех сотрудников уже есть учётные записи');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Создать вход всем сотрудникам?'),
        content: Text(
          'Будут автоматически созданы логины и временные пароли для ${available.length} сотрудников без учётной записи. Роль — «Рабочий».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final reserved =
        _auth.users.map((user) => user.login.toLowerCase()).toSet();
    final jobs = [
      for (final employee in available)
        (
          employee: employee,
          login: _suggestLogin(employee, reserved),
          password: _auth.generateReadablePassword(),
        ),
    ];
    final created = <EmployeeAccountCredentials>[];
    final failed = <String>[];
    setState(() {
      _creatingEmployeeAccounts = true;
      _accountCreationProgress = 0;
      _accountCreationTotal = jobs.length;
    });

    for (var start = 0; start < jobs.length; start += 3) {
      final end = start + 3 < jobs.length ? start + 3 : jobs.length;
      final batch = jobs.sublist(start, end);
      final results = await Future.wait([
        for (final job in batch)
          _auth.createAccountForEmployee(
            employee: job.employee,
            login: job.login,
            password: job.password,
            publishLocalChange: false,
          ),
      ]);
      for (var index = 0; index < batch.length; index++) {
        final result = results[index];
        if (result == null) {
          failed.add(batch[index].employee.fullName);
        } else {
          created.add(result);
        }
      }
      if (mounted) {
        setState(() => _accountCreationProgress = end);
      }
    }

    try {
      await _auth.refreshServerState();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _creatingEmployeeAccounts = false);
    await _showCredentials(created, failed: failed);
  }

  @override
  Widget build(BuildContext context) {
    final roles = _auth.roles.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (_roleId != null && roles.every((r) => r.id != _roleId)) {
      _roleId = roles.isNotEmpty ? roles.first.id : null;
      _resetBindingsForRole(_auth.roleById(_roleId));
    }

    final users = _filteredUsers(
      _auth.users.toList()
        ..sort((a, b) {
          final byName = a.fullName.compareTo(b.fullName);
          if (byName != 0) return byName;
          return a.login.compareTo(b.login);
        }),
    );

    final selectedRole = _selectedRole();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 520;
                    final description = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Доступ сотрудников',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Выдайте логин и временный пароль уже заведённым сотрудникам.',
                        ),
                      ],
                    );
                    final count = Chip(
                      label: Text(
                        'Без логина: ${_employeesWithoutAccounts.length}',
                      ),
                    );

                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          description,
                          const SizedBox(height: 8),
                          count,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: description),
                        const SizedBox(width: 12),
                        count,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _creatingEmployeeAccounts ||
                              _employeesWithoutAccounts.isEmpty
                          ? null
                          : _createAccountForOneEmployee,
                      icon: const Icon(Icons.person_add_alt_1_outlined),
                      label: const Text('Выдать доступ сотруднику'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _creatingEmployeeAccounts ||
                              _employeesWithoutAccounts.isEmpty
                          ? null
                          : _createAccountsForAllEmployees,
                      icon: const Icon(Icons.groups_2_outlined),
                      label: Text(
                        'Создать доступ всем (${_employeesWithoutAccounts.length})',
                      ),
                    ),
                  ],
                ),
                if (_creatingEmployeeAccounts) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _accountCreationTotal == 0
                        ? null
                        : _accountCreationProgress / _accountCreationTotal,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Создано: $_accountCreationProgress из $_accountCreationTotal',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Создать пользователя',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Пользователь — это учётная запись для входа. Её можно привязать к сотруднику и выдать нужную роль.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _roleHintCard(selectedRole),
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
                      _resetBindingsForRole(_auth.roleById(value));
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
                        ? 'Будет автоматически создан сотрудник: "${_normalizeFullName(_lastName.text, _firstName.text, _middleName.text)}".'
                        : _auth.requiredBindingHintByRoleId(_roleId),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _create,
                      child: const Text('Создать пользователя'),
                    ),
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Пользователи',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Chip(label: Text('Всего: ${users.length}')),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    labelText: 'Поиск пользователя',
                    hintText: 'ФИО, логин, роль, привязка',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () => _searchCtrl.clear(),
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (users.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Пользователей пока нет или по текущему поиску ничего не найдено.',
              ),
            ),
          )
        else
          ...users.map((UserAccount u) {
            final isMe = _auth.currentUser?.id == u.id;
            final role = _auth.roleById(u.roleId);
            final binding = _bindingSummaryForUser(
              u.departmentId,
              u.groupId,
              u.employeeId,
              role,
            );

            return Card(
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                title: Text(u.fullName),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Логин: ${u.login}'),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text(role?.name ?? u.roleId)),
                          Chip(label: Text(binding)),
                          if (isMe) const Chip(label: Text('Это вы')),
                        ],
                      ),
                    ],
                  ),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (_configuringVisibilityUserId == u.id)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        tooltip: 'Скрыть или вернуть группы',
                        icon: const Icon(Icons.visibility_off_outlined),
                        onPressed: () => _configureHiddenGroups(u),
                      ),
                    IconButton(
                      tooltip: 'Редактировать пользователя',
                      icon: const Icon(Icons.manage_accounts_outlined),
                      onPressed: () => _editUserDialog(u.id),
                    ),
                    IconButton(
                      tooltip: 'Удалить пользователя',
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
