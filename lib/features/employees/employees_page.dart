import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'employee_editor_dialog.dart';
import '../structure/structure_storage.dart';
import 'employees_storage.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({super.key});

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _storage = EmployeesStorage();
  final _structureStorage = StructureStorage();

  bool _loading = true;

  List<EmployeeModel> _employeesAll = <EmployeeModel>[];
  List<EmployeeModel> _employeesVisible = <EmployeeModel>[];

  List<dynamic> _departments = <dynamic>[];
  List<dynamic> _groups = <dynamic>[];

  String? _selectedDepartmentId;
  String? _selectedGroupId;

  bool get _canViewEmployees =>
      AuthService.instance.hasPerm(AppPermission.viewEmployees);
  bool get _canEditEmployees =>
      AuthService.instance.hasPerm(AppPermission.editEmployees);

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  dynamic _findDepartment(String? depId) {
    if (depId == null) return null;
    for (final d in _departments) {
      if (d.id == depId) return d;
    }
    return null;
  }

  dynamic _findGroup(String? groupId) {
    if (groupId == null) return null;
    for (final g in _groups) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);

    final employees = await _storage.load();
    final deps = await _structureStorage.loadDepartments();
    final groups = await _structureStorage.loadGroups();

    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    final visible = AuthService.instance.filterEmployeesByScope(employees);

    if (!mounted) return;

    setState(() {
      _employeesAll = employees;
      _employeesVisible = visible;
      _departments = deps;
      _groups = groups;
      _loading = false;
    });

    _applyRoleLockToFilters();
    _normalizeGroupSelection();
  }

  void _applyRoleLockToFilters() {
    final u = AuthService.instance.currentUser;
    if (u == null) return;
    if (u.role == UserRole.superAdmin) return;

    setState(() {
      if (u.role == UserRole.manager) {
        _selectedDepartmentId = u.departmentId;
        _selectedGroupId = null;
      } else if (u.role == UserRole.master) {
        _selectedGroupId = u.groupId;
        final g = _findGroup(_selectedGroupId);
        _selectedDepartmentId = g?.departmentId;
      } else if (u.role == UserRole.worker) {
        _selectedDepartmentId = null;
        _selectedGroupId = null;
      }
    });
  }

  bool get _filtersLockedByRole {
    final u = AuthService.instance.currentUser;
    if (u == null) return true;
    return u.role != UserRole.superAdmin;
  }

  void _normalizeGroupSelection() {
    if (_selectedDepartmentId == null) {
      if (_selectedGroupId != null && !_filtersLockedByRole) {
        setState(() => _selectedGroupId = null);
      }
      return;
    }

    if (_selectedGroupId == null) return;

    final g = _findGroup(_selectedGroupId);
    if (g == null || g.departmentId != _selectedDepartmentId) {
      setState(() => _selectedGroupId = null);
    }
  }

  String _depName(String? depId) {
    final d = _findDepartment(depId);
    return (d?.name as String?) ?? '—';
  }

  String _groupName(String? groupId) {
    final g = _findGroup(groupId);
    return (g?.name as String?) ?? '—';
  }

  List<dynamic> get _groupsForSelectedDepartment {
    final depId = _selectedDepartmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  List<EmployeeModel> get _filteredEmployees {
    Iterable<EmployeeModel> out = _employeesVisible;

    final depId = _selectedDepartmentId;
    if (depId != null) {
      out = out.where((e) => e.departmentId == depId);
    }

    final groupId = _selectedGroupId;
    if (groupId != null) {
      out = out.where((e) => e.groupId == groupId);
    }

    return out.toList()..sort((a, b) => a.fullName.compareTo(b.fullName));
  }

  Future<void> _addEmployee() async {
    final draft = await showDialog<EmployeeDraft>(
      context: context,
      builder: (context) => const EmployeeEditorDialog(),
    );

    if (!mounted || draft == null) return;

    final all = await _storage.load();

    final newEmployee = EmployeeModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fullName: draft.fullName,
      position: draft.position,
      salary: draft.salary,
      bonus: draft.bonus,
      departmentId: draft.departmentId,
      groupId: draft.groupId,
      scheduleType: draft.scheduleType,
      scheduleStartDate: draft.scheduleStartDate,
      shiftHours: draft.shiftHours,
      breakHours: draft.breakHours,
    );

    final updated = [...all, newEmployee];
    await _storage.save(updated);

    final visibleAfterSave = AuthService.instance.filterEmployeesByScope(updated);
    final isVisibleForCurrentUser =
        visibleAfterSave.any((e) => e.id == newEmployee.id);

    await _loadAll();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isVisibleForCurrentUser
              ? 'Сотрудник добавлен'
              : 'Сотрудник добавлен, но не попадает в ваш текущий доступ',
        ),
      ),
    );
  }

  Widget _filtersCard() {
    final groups = _groupsForSelectedDepartment;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          runSpacing: 12,
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedDepartmentId,
                decoration: const InputDecoration(
                  labelText: 'Подразделение',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Все подразделения'),
                  ),
                  ..._departments.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d.id as String?,
                      child: Text(d.name as String),
                    ),
                  ),
                ],
                onChanged: _filtersLockedByRole
                    ? null
                    : (v) => setState(() {
                          _selectedDepartmentId = v;
                          _selectedGroupId = null;
                        }),
              ),
            ),
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedGroupId,
                decoration: const InputDecoration(
                  labelText: 'Группа',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Все группы'),
                  ),
                  ...groups.map(
                    (g) => DropdownMenuItem<String?>(
                      value: g.id as String?,
                      child: Text(g.name as String),
                    ),
                  ),
                ],
                onChanged: _filtersLockedByRole
                    ? null
                    : (_selectedDepartmentId == null)
                        ? null
                        : (v) => setState(() => _selectedGroupId = v),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _loadAll,
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить'),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('Видно сотрудников: ${_filteredEmployees.length}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(bool canEdit) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Всего сотрудников в базе: ${_employeesAll.length}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (canEdit)
          FilledButton.icon(
            onPressed: _addEmployee,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Добавить сотрудника'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canView = _canViewEmployees;
    final canEdit = _canEditEmployees;
    final list = _filteredEmployees;

    final u = AuthService.instance.currentUser;
    final noBinding =
        u != null && u.role != UserRole.superAdmin && _employeesVisible.isEmpty;

    return AdaptiveScaffold(
      title: 'Сотрудники',
      selectedIndex: 1,
      items: [
        NavItem(
          label: 'Календарь',
          icon: Icons.calendar_month,
          onTap: () => context.go('/'),
        ),
        NavItem(
          label: 'Сотрудники',
          icon: Icons.people,
          onTap: () => context.go('/employees'),
        ),
        NavItem(
          label: 'Ещё',
          icon: Icons.more_horiz,
          onTap: () {},
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: !canView
            ? const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Нет доступа: у твоей роли нет права "Просмотр сотрудников".',
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      if (noBinding)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(Icons.warning_amber),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Для вашей роли не настроена привязка (сотрудник/группа/подразделение).\n'
                                    'Попросите руководителя настроить доступ в "Админ → Пользователи".',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      _buildToolbar(canEdit),
                      const SizedBox(height: 12),
                      _filtersCard(),
                      const SizedBox(height: 12),
                      Expanded(
                        child: list.isEmpty
                            ? Center(
                                child: Text(
                                  noBinding
                                      ? 'Нет данных из-за отсутствия привязки.'
                                      : (_employeesAll.isEmpty
                                          ? (canEdit
                                              ? 'Пока нет сотрудников.\nДобавь через кнопку выше.'
                                              : 'Список сотрудников пуст.')
                                          : 'По выбранным фильтрам сотрудников нет.'),
                                  textAlign: TextAlign.center,
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                              )
                            : ListView.separated(
                                itemCount: list.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final e = list[index];
                                  final dep = _depName(e.departmentId);
                                  final grp = _groupName(e.groupId);

                                  return ListTile(
                                    title: Text(e.fullName),
                                    subtitle: Text(
                                      '${e.position} • $dep • $grp\n'
                                      'оклад ${e.salary} ₽ • премия ${e.bonus} ₽',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () async {
                                      if (!canEdit) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Нет прав на редактирование сотрудников',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final res =
                                          await context.push<Map>('/employee/${e.id}');
                                      if (!mounted) return;

                                      if (res != null) {
                                        await _loadAll();
                                      }
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
      ),
    );
  }
}