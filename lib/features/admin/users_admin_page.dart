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

  bool _loadingLists = true;

  List<EmployeeModel> _employees = [];
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  UserRole _role = UserRole.worker;

  String? _departmentId;
  String? _groupId;
  String? _employeeId;

  bool _createEmployeeForWorker = true;

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    _lastName.dispose();
    _firstName.dispose();
    _middleName.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
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

  void _resetBindingsForRole(UserRole role) {
    setState(() {
      switch (role) {
        case UserRole.manager:
          _departmentId = null;
          _groupId = null;
          _employeeId = null;
          _createEmployeeForWorker = false;
          break;
        case UserRole.master:
          _departmentId = null;
          _groupId = null;
          _employeeId = null;
          _createEmployeeForWorker = false;
          break;
        case UserRole.worker:
          _departmentId = null;
          _groupId = null;
          _employeeId = null;
          _createEmployeeForWorker = true;
          break;
        case UserRole.superAdmin:
          _departmentId = null;
          _groupId = null;
          _employeeId = null;
          _createEmployeeForWorker = false;
          break;
      }
    });
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
    UserRole role,
  ) {
    switch (role) {
      case UserRole.superAdmin:
        return 'Привязка не требуется';
      case UserRole.manager:
        final dep = _findDepartment(depId);
        return 'Подразделение: ${dep?.name ?? '—'}';
      case UserRole.master:
        final group = _findGroup(groupId);
        final dep = _findDepartment(group?.departmentId);
        if (group == null) return 'Группа: —';
        return dep == null
            ? 'Группа: ${group.name}'
            : 'Группа: ${group.name} • ${dep.name}';
      case UserRole.worker:
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

    switch (_role) {
      case UserRole.manager:
        if (_departmentId == null || _departmentId!.isEmpty) {
          _snack(auth.requiredBindingHint(_role));
          return false;
        }
        return true;

      case UserRole.master:
        if (_groupId == null || _groupId!.isEmpty) {
          _snack(auth.requiredBindingHint(_role));
          return false;
        }
        return true;

      case UserRole.worker:
        if (_createEmployeeForWorker) {
          if (_departmentId == null ||
              _departmentId!.isEmpty ||
              _groupId == null ||
              _groupId!.isEmpty) {
            _snack(
              'Для нового рабочего укажи подразделение и группу. Тогда сотрудник сразу появится в списке.',
            );
            return false;
          }
        } else {
          if (_employeeId == null || _employeeId!.isEmpty) {
            _snack(auth.requiredBindingHint(_role));
            return false;
          }
        }
        return true;

      case UserRole.superAdmin:
        return true;
    }
  }

  Future<void> _create() async {
    final auth = AuthService.instance;

    if (!_validateCreate(auth)) return;

    final ok = await auth.createUser(
      login: _login.text.trim(),
      password: _pass.text,
      role: _role,
      lastName: _lastName.text.trim(),
      firstName: _firstName.text.trim(),
      middleName: _middleName.text.trim(),
      departmentId: (_role == UserRole.manager ||
              (_role == UserRole.worker && _createEmployeeForWorker))
          ? _departmentId
          : null,
      groupId: (_role == UserRole.master ||
              (_role == UserRole.worker && _createEmployeeForWorker))
          ? _groupId
          : null,
      employeeId:
          (_role == UserRole.worker && !_createEmployeeForWorker)
              ? _employeeId
              : null,
      createEmployeeForWorker:
          _role == UserRole.worker && _createEmployeeForWorker,
      employeePosition: 'Рабочий',
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
      _role = UserRole.worker;
      _departmentId = null;
      _groupId = null;
      _employeeId = null;
      _createEmployeeForWorker = true;
    });

    await _loadLists();

    if (!mounted) return;
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
    final user = auth.users.where((x) => x.id == userId).firstOrNull;
    if (user == null) return;

    UserRole role = user.role;
    String? depId = user.departmentId;
    String? groupId = user.groupId;
    String? empId = user.employeeId;

    String lastName = user.lastName;
    String firstName = user.firstName;
    String middleName = user.middleName;

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

    final lastNameCtrl = TextEditingController(text: lastName);
    final firstNameCtrl = TextEditingController(text: firstName);
    final middleNameCtrl = TextEditingController(text: middleName);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            final groupsForDep = _groupsForDepartment(depId);

            Widget bindingEditor() {
              if (role == UserRole.manager) {
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
              }

              if (role == UserRole.master) {
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
              }

              if (role == UserRole.worker) {
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

              return const Text('Суперадмин: привязка не требуется');
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
                      DropdownButtonFormField<UserRole>(
                        initialValue: role,
                        decoration: const InputDecoration(
                          labelText: 'Роль',
                          border: OutlineInputBorder(),
                        ),
                        items: UserRole.values
                            .map(
                              (r) => DropdownMenuItem<UserRole>(
                                value: r,
                                child: Text(roleLabel(r)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;

                          setLocal(() {
                            role = value;

                            switch (role) {
                              case UserRole.manager:
                                depId = null;
                                groupId = null;
                                empId = null;
                                break;
                              case UserRole.master:
                                depId = null;
                                groupId = null;
                                empId = null;
                                break;
                              case UserRole.worker:
                                depId = null;
                                groupId = null;
                                empId = null;
                                break;
                              case UserRole.superAdmin:
                                depId = null;
                                groupId = null;
                                empId = null;
                                break;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      bindingEditor(),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          auth.requiredBindingHint(role),
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

                    if (lastName.isEmpty || firstName.isEmpty) {
                      _snack('Заполни минимум фамилию и имя');
                      return;
                    }

                    switch (role) {
                      case UserRole.manager:
                        if (depId == null || depId!.isEmpty) {
                          _snack(auth.requiredBindingHint(role));
                          return;
                        }
                        break;
                      case UserRole.master:
                        if (groupId == null || groupId!.isEmpty) {
                          _snack(auth.requiredBindingHint(role));
                          return;
                        }
                        break;
                      case UserRole.worker:
                        if (empId == null || empId!.isEmpty) {
                          _snack(auth.requiredBindingHint(role));
                          return;
                        }
                        break;
                      case UserRole.superAdmin:
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

    final saved = await auth.updateUserAccess(
      userId: userId,
      role: role,
      lastName: lastName,
      firstName: firstName,
      middleName: middleName,
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

  Widget _workerCreateMode() {
    if (_role != UserRole.worker) return const SizedBox.shrink();

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Сразу создать сотрудника для рабочего'),
              subtitle: const Text(
                'Рекомендуется: пользователь появится и в системе доступа, и в списке сотрудников.',
              ),
              value: _createEmployeeForWorker,
              onChanged: (value) {
                setState(() {
                  _createEmployeeForWorker = value;
                  _departmentId = null;
                  _groupId = null;
                  _employeeId = null;
                });
              },
            ),
            const SizedBox(height: 8),
            if (_createEmployeeForWorker) ...[
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
    if (_loadingLists) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }

    if (_role == UserRole.manager) {
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
    }

    if (_role == UserRole.master) {
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
    }

    if (_role == UserRole.worker) {
      return _workerCreateMode();
    }

    return const Text('Суперадмин: привязка не требуется');
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final users = auth.users.toList()
      ..sort((a, b) {
        final byName = a.fullName.compareTo(b.fullName);
        if (byName != 0) return byName;
        return a.login.compareTo(b.login);
      });

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
                DropdownButtonFormField<UserRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'Роль',
                    border: OutlineInputBorder(),
                  ),
                  items: UserRole.values
                      .map(
                        (r) => DropdownMenuItem<UserRole>(
                          value: r,
                          child: Text(roleLabel(r)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _role = value);
                    _resetBindingsForRole(value);
                  },
                ),
                const SizedBox(height: 12),
                _bindingEditorForCreate(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _role == UserRole.worker && _createEmployeeForWorker
                        ? 'Для рабочего будет автоматически создан сотрудник: "${_normalizeFullName(_lastName.text, _firstName.text, _middleName.text)}".'
                        : auth.requiredBindingHint(_role),
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
            final binding = _bindingSummaryForUser(
              u.departmentId,
              u.groupId,
              u.employeeId,
              u.role,
            );

            return Card(
              child: ListTile(
                title: Text(u.fullName),
                subtitle: Text(
                  '${u.login} • ${roleLabel(u.role)}\n$binding',
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}