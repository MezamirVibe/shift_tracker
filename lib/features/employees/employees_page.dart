import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../structure/structure_storage.dart';
import 'employee_editor_dialog.dart';
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

  List<EmployeeModel> _employeesAll = [];
  List<EmployeeModel> _employeesVisible = [];

  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  String? _selectedDepartmentId; // null = все доступные (но может быть зажато ролью)
  String? _selectedGroupId; // null = все доступные (но может быть зажато ролью)

  bool get _canViewEmployees => AuthService.instance.hasPerm(AppPermission.viewEmployees);
  bool get _canEditEmployees => AuthService.instance.hasPerm(AppPermission.editEmployees);

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);

    final employees = await _storage.load();
    final deps = await _structureStorage.loadDepartments();
    final groups = await _structureStorage.loadGroups();

    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    // ✅ главное: видимость по роли/привязке
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
        // руководитель: отдел фиксируем
        _selectedDepartmentId = u.departmentId;
        _selectedGroupId = null;
      } else if (u.role == UserRole.master) {
        // мастер: группа фиксируется
        _selectedGroupId = u.groupId;

        // для красоты можем поставить отдел группы
        final g = _groups.where((x) => x.id == _selectedGroupId).cast<GroupModel?>().firstOrNull;
        _selectedDepartmentId = g?.departmentId;
      } else if (u.role == UserRole.worker) {
        // рабочий: фильтры не нужны
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

    final g = _groups.where((x) => x.id == _selectedGroupId).cast<GroupModel?>().firstOrNull;
    if (g == null || g.departmentId != _selectedDepartmentId) {
      setState(() => _selectedGroupId = null);
    }
  }

  Future<void> _saveEmployees() async {
    await _storage.save(_employeesAll);
  }

  Future<void> _addEmployee() async {
    if (!_canEditEmployees) return;

    final draft = await showDialog<EmployeeDraft>(
      context: context,
      builder: (context) => const EmployeeEditorDialog(),
    );

    if (draft == null) return;

    final newEmployee = EmployeeModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fullName: draft.fullName,
      position: draft.position,
      salary: draft.salary,
      bonus: draft.bonus,
    );

    setState(() {
      _employeesAll = [..._employeesAll, newEmployee];
    });

    await _saveEmployees();
    await _loadAll();
  }

  Future<void> _applyEmployeeResult(EmployeeModel current, Map<String, dynamic> res) async {
    if (res['deleted'] == true) {
      setState(() {
        _employeesAll = _employeesAll.where((x) => x.id != current.id).toList();
      });
      await _saveEmployees();
      await _loadAll();
      return;
    }

    final scheduleTypeRaw = res['scheduleType'] as String?;
    final scheduleStartDateRaw = res['scheduleStartDate'] as String?;

    final updated = current.copyWith(
      fullName: (res['fullName'] as String?) ?? current.fullName,
      position: (res['position'] as String?) ?? current.position,
      salary: (res['salary'] as int?) ?? current.salary,
      bonus: (res['bonus'] as int?) ?? current.bonus,
      scheduleType: scheduleTypeRaw != null ? scheduleTypeFromString(scheduleTypeRaw) : null,
      scheduleStartDate: scheduleStartDateRaw != null ? DateTime.tryParse(scheduleStartDateRaw) : null,
      shiftHours: (res['shiftHours'] as int?) ?? current.shiftHours,
      breakHours: (res['breakHours'] as int?) ?? current.breakHours,
      departmentId: (res['departmentId'] as String?) ?? current.departmentId,
      groupId: (res['groupId'] as String?) ?? current.groupId,
      clearDepartment: res['departmentId'] == null,
      clearGroup: res['groupId'] == null,
    );

    setState(() {
      _employeesAll = _employeesAll.map((x) => x.id == current.id ? updated : x).toList();
    });

    await _saveEmployees();
    await _loadAll();
  }

  String _depName(String? depId) {
    if (depId == null || depId.isEmpty) return '—';
    final d = _departments.where((x) => x.id == depId).cast<DepartmentModel?>().firstOrNull;
    return d?.name ?? '—';
  }

  String _groupName(String? groupId) {
    if (groupId == null || groupId.isEmpty) return '—';
    final g = _groups.where((x) => x.id == groupId).cast<GroupModel?>().firstOrNull;
    return g?.name ?? '—';
  }

  List<GroupModel> get _groupsForSelectedDepartment {
    final depId = _selectedDepartmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  List<EmployeeModel> get _filteredEmployees {
    Iterable<EmployeeModel> out = _employeesVisible;

    final depId = _selectedDepartmentId;
    if (depId != null) out = out.where((e) => e.departmentId == depId);

    final groupId = _selectedGroupId;
    if (groupId != null) out = out.where((e) => e.groupId == groupId);

    final list = out.toList()..sort((a, b) => a.fullName.compareTo(b.fullName));
    return list;
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
                decoration: const InputDecoration(labelText: 'Подразделение', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Все подразделения')),
                  ..._departments.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
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
                decoration: const InputDecoration(labelText: 'Группа', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Все группы')),
                  ...groups.map((g) => DropdownMenuItem<String?>(value: g.id, child: Text(g.name))),
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
              child: Text('Видно сотрудников: ${_employeesVisible.length}'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canView = _canViewEmployees;
    final canEdit = _canEditEmployees;

    final list = _filteredEmployees;

    final u = AuthService.instance.currentUser;
    final noBinding = (u != null && u.role != UserRole.superAdmin && _employeesVisible.isEmpty);

    return AdaptiveScaffold(
      title: 'Сотрудники',
      selectedIndex: 1,
      items: [
        NavItem(label: 'Календарь', icon: Icons.calendar_month, onTap: () => context.go('/')),
        NavItem(label: 'Сотрудники', icon: Icons.people, onTap: () => context.go('/employees')),
        NavItem(label: 'Ещё', icon: Icons.more_horiz, onTap: () {}),
      ],
      floatingActionButton: canEdit ? FloatingActionButton(onPressed: _addEmployee, child: const Icon(Icons.add)) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: !canView
            ? Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Нет доступа: у твоей роли нет права "Просмотр сотрудников".')),
                    ],
                  ),
                ),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      if (noBinding)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: const [
                                Icon(Icons.warning_amber),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Для вашей роли не настроена привязка (сотрудник/группа/подразделение). '
                                    'Попросите руководителя настроить доступ в "Админ → Пользователи".',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
                                              ? 'Пока нет сотрудников.\nНажми "+" чтобы добавить.'
                                              : 'Список сотрудников пуст.')
                                          : 'По выбранным фильтрам сотрудников нет.'),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              )
                            : ListView.separated(
                                itemCount: list.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final e = list[index];
                                  final dep = _depName(e.departmentId);
                                  final grp = _groupName(e.groupId);

                                  return ListTile(
                                    title: Text(e.fullName),
                                    subtitle: Text(
                                      '${e.position} • $dep • $grp\nоклад ${e.salary} ₽ • премия ${e.bonus} ₽',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!canEdit)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 8),
                                            child: Chip(label: Text('Просмотр')),
                                          ),
                                        const Icon(Icons.chevron_right),
                                      ],
                                    ),
                                    onTap: () async {
                                      if (!canEdit) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Нет прав на редактирование сотрудников')),
                                        );
                                        return;
                                      }
                                      final res = await context.push<Map<String, dynamic>>('/employee/${e.id}');
                                      if (res == null) return;
                                      await _applyEmployeeResult(e, res);
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}