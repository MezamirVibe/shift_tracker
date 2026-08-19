import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../preferences/preferences_service.dart';
import '../structure/structure_storage.dart';
import 'employee_editor_dialog.dart';
import 'employees_storage.dart';
import 'schedule_utils.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({super.key});

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _storage = EmployeesStorage();
  final _structureStorage = StructureStorage();
  final _preferences = PreferencesService.instance;
  final _searchCtrl = TextEditingController();

  bool _loading = true;

  List<EmployeeModel> _employeesAll = <EmployeeModel>[];
  List<EmployeeModel> _employeesVisible = <EmployeeModel>[];

  List<dynamic> _departments = <dynamic>[];
  List<dynamic> _groups = <dynamic>[];

  String? _selectedDepartmentId;
  String? _selectedGroupId;
  String? _selectedEmployeeId;
  String _search = '';

  bool get _canViewEmployees =>
      AuthService.instance.hasPerm(AppPermission.viewEmployees);

  bool get _canEditEmployees =>
      AuthService.instance.hasPerm(AppPermission.editEmployees);

  bool get _isSuperAdmin => AuthService.instance.isCurrentUserSuperAdmin;

  bool get _canAddEmployees =>
      _canEditEmployees ||
      _isSuperAdmin ||
      AuthService.instance.hasPerm(AppPermission.manageUsers);

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _search = _searchCtrl.text.trim().toLowerCase();
      });
    });
    _loadAll();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
    if (mounted) {
      setState(() => _loading = true);
    }

    await _preferences.syncForCurrentUser(force: true);
    final results = await Future.wait([
      _storage.load(),
      _structureStorage.loadDepartments(),
      _structureStorage.loadGroups(),
    ]);
    final employees = results[0] as List<EmployeeModel>;
    final deps = results[1] as List<DepartmentModel>;
    final groups = results[2] as List<GroupModel>;

    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    final visible = AuthService.instance
        .filterEmployeesByScope(employees)
        .where((employee) => _preferences.isGroupVisible(employee.groupId))
        .toList();
    final visibleGroups =
        groups.where((group) => _preferences.isGroupVisible(group.id)).toList();

    if (!mounted) return;

    setState(() {
      _employeesAll = visible;
      _employeesVisible = visible;
      _departments = deps;
      _groups = visibleGroups;
      final selectedStillVisible = visible.any(
        (employee) => employee.id == _selectedEmployeeId,
      );
      if (!selectedStillVisible) {
        _selectedEmployeeId = visible.isEmpty ? null : visible.first.id;
      }
      _loading = false;
    });

    _applyRoleLockToFilters();
    _normalizeGroupSelection();
  }

  void _applyRoleLockToFilters() {
    final u = AuthService.instance.currentUser;
    if (u == null) return;
    if (_isSuperAdmin) return;

    final role = AuthService.instance.roleById(u.roleId);
    if (role == null) return;

    setState(() {
      switch (role.scopeKind) {
        case ScopeKind.all:
          break;
        case ScopeKind.department:
          _selectedDepartmentId = u.departmentId;
          _selectedGroupId = null;
          break;
        case ScopeKind.group:
          _selectedGroupId = u.groupId;
          final g = _findGroup(_selectedGroupId);
          _selectedDepartmentId = g?.departmentId as String?;
          break;
        case ScopeKind.self:
          _selectedDepartmentId = null;
          _selectedGroupId = null;
          break;
      }
    });
  }

  bool get _filtersLockedByRole {
    final u = AuthService.instance.currentUser;
    if (u == null) return true;
    if (_isSuperAdmin) return false;

    final role = AuthService.instance.roleById(u.roleId);
    if (role == null) return true;

    return role.scopeKind != ScopeKind.all;
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

    if (_search.isNotEmpty) {
      out = out.where((e) {
        final haystack =
            '${e.fullName} ${e.position} ${_depName(e.departmentId)} ${_groupName(e.groupId)}'
                .toLowerCase();
        return haystack.contains(_search);
      });
    }

    return out.toList()..sort((a, b) => a.fullName.compareTo(b.fullName));
  }

  Future<void> _showCredentialsDialog({
    required String login,
    required String password,
    required String roleName,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Сотрудник и учётная запись созданы'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _copyTile('Логин', login),
            const SizedBox(height: 8),
            _copyTile('Временный пароль', password),
            const SizedBox(height: 8),
            _copyTile('Роль', roleName),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Пароль показывается только сейчас. Позже его можно будет только сбросить.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final text = 'Логин: $login\nПароль: $password\nРоль: $roleName';
              await Clipboard.setData(ClipboardData(text: text));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('Данные для входа скопированы')),
              );
            },
            child: const Text('Скопировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _copyTile(String label, String value) {
    return Row(
      children: [
        SizedBox(width: 140, child: Text(label)),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Future<void> _addEmployee() async {
    if (!_canAddEmployees) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет прав на создание сотрудников')),
      );
      return;
    }

    final draft = await showDialog<EmployeeDraft>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const EmployeeEditorDialog(
        showAccessFields: true,
      ),
    );

    if (!mounted || draft == null) return;

    final result = await AuthService.instance.createEmployeeWithAccount(
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
      customWorkdays: draft.customWorkdays,
      login: draft.login ?? '',
      roleId: draft.roleId ?? BuiltInRoleIds.worker,
    );

    if (!mounted) return;

    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось создать сотрудника и учётную запись. Проверь логин, роль и привязку.',
          ),
        ),
      );
      return;
    }

    await _loadAll();

    if (!mounted) return;

    final roleName = AuthService.instance.roleById(result.user.roleId)?.name ??
        result.user.roleId;

    await _showCredentialsDialog(
      login: result.user.login,
      password: result.password,
      roleName: roleName,
    );
  }

  void _resetFilters() {
    setState(() {
      _searchCtrl.clear();
      _search = '';
      if (!_filtersLockedByRole) {
        _selectedDepartmentId = null;
        _selectedGroupId = null;
      }
    });

    if (_filtersLockedByRole) {
      _applyRoleLockToFilters();
    }
  }

  Widget _scopeHint() {
    final u = AuthService.instance.currentUser;
    if (u == null) return const SizedBox.shrink();
    final role = AuthService.instance.roleById(u.roleId);
    if (role == null) return const SizedBox.shrink();

    String text;
    switch (role.scopeKind) {
      case ScopeKind.all:
        text = 'Вы видите всех сотрудников.';
        break;
      case ScopeKind.department:
        text = 'Вы видите сотрудников только своего подразделения.';
        break;
      case ScopeKind.group:
        text = 'Вы видите сотрудников только своей группы.';
        break;
      case ScopeKind.self:
        text = 'Вы видите только себя.';
        break;
    }

    return Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.visibility_outlined),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  Widget _statsRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(label: Text('Видно: ${_filteredEmployees.length}')),
        Chip(label: Text('Всего: ${_employeesAll.length}')),
      ],
    );
  }

  Widget _filtersCard() {
    final groups = _groupsForSelectedDepartment;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isNarrow = width < 760;

        double fieldWidth() {
          if (isNarrow) return width;
          final candidate = (width - 12) / 2;
          if (candidate < 260) return 260;
          if (candidate > 360) return 360;
          return candidate;
        }

        final filterWidth = fieldWidth();

        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Поиск и фильтры',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Быстрый поиск по ФИО, должности, подразделению и группе.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    labelText: 'Поиск сотрудника',
                    hintText: 'Например: Иванов, сварщик, цех 1',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            onPressed: () => _searchCtrl.clear(),
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  runSpacing: 12,
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: filterWidth,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _selectedDepartmentId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Подразделение',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              'Все подразделения',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ..._departments.map(
                            (d) => DropdownMenuItem<String?>(
                              value: d.id as String?,
                              child: Text(
                                d.name as String,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                      width: filterWidth,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _selectedGroupId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Группа',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              'Все группы',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ...groups.map(
                            (g) => DropdownMenuItem<String?>(
                              value: g.id as String?,
                              child: Text(
                                g.name as String,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                    OutlinedButton.icon(
                      onPressed: _resetFilters,
                      icon: const Icon(Icons.filter_alt_off),
                      label: const Text('Сбросить'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _statsRow(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _heroCard(bool isPhone) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Сотрудники',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Карточки сотрудников, структура, должности и доступ в приложение.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            if (_canAddEmployees)
              SizedBox(
                width: isPhone ? double.infinity : null,
                child: FilledButton.icon(
                  onPressed: _addEmployee,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Добавить сотрудника'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(bool noBinding) {
    final text = noBinding
        ? 'Нет данных из-за отсутствия привязки.\nПопросите настроить доступ в админке.'
        : (_employeesAll.isEmpty
            ? (_canAddEmployees
                ? 'Список пока пуст.\nСоздай первого сотрудника.'
                : 'Список сотрудников пока пуст.')
            : 'По текущим фильтрам и поиску сотрудников не найдено.');

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline, size: 40),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_canAddEmployees && _employeesAll.isEmpty) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _addEmployee,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Добавить сотрудника'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _employeeTile(EmployeeModel e, bool canEdit) {
    final dep = _depName(e.departmentId);
    final grp = _groupName(e.groupId);
    final linkedUser = AuthService.instance.userByEmployeeId(e.id);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          if (!canEdit) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Нет прав на редактирование сотрудников'),
              ),
            );
            return;
          }

          final res = await context.push<Map>('/employee/${e.id}');
          if (!mounted) return;

          if (res != null) {
            await _loadAll();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      e.fullName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                e.position,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(dep)),
                  Chip(label: Text(grp)),
                  Chip(label: Text('Оклад ${e.salary} ₽')),
                  Chip(label: Text('Премия ${e.bonus} ₽')),
                  if (linkedUser != null)
                    Chip(label: Text('Логин: ${linkedUser.login}')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEmployee(EmployeeModel employee, bool canEdit) async {
    if (!canEdit) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет прав на редактирование сотрудников')),
      );
      return;
    }
    final result = await context.push<Map>('/employee/${employee.id}');
    if (!mounted) return;
    if (result != null) await _loadAll();
  }

  Widget _desktopList(List<EmployeeModel> employees, bool canEdit) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: scheme.surfaceContainerHighest,
            child: const _EmployeeTableRow(
              name: 'Сотрудник',
              position: 'Должность',
              schedule: 'График',
              department: 'Подразделение',
              header: true,
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: employees.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: scheme.outlineVariant,
              ),
              itemBuilder: (context, index) {
                final employee = employees[index];
                final selected = employee.id == _selectedEmployeeId;
                final schedule = scheduleTypeLabel(employee.scheduleType);
                return Material(
                  color: selected
                      ? scheme.primaryContainer.withValues(alpha: 0.55)
                      : Colors.transparent,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _selectedEmployeeId = employee.id),
                    onDoubleTap: () => _openEmployee(employee, canEdit),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 13,
                      ),
                      child: _EmployeeTableRow(
                        name: employee.fullName,
                        initials: _initials(employee.fullName),
                        position:
                            employee.position.isEmpty ? '—' : employee.position,
                        schedule: schedule,
                        department: _depName(employee.departmentId),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _employeePreview(bool canEdit) {
    EmployeeModel? employee;
    for (final item in _filteredEmployees) {
      if (item.id == _selectedEmployeeId) employee = item;
    }
    if (employee == null) {
      return const Card(child: Center(child: Text('Выберите сотрудника')));
    }
    final linked = AuthService.instance.userByEmployeeId(employee.id);
    final schedule = scheduleTypeLabel(employee.scheduleType);
    final worksToday = isWorkDay(
      day: DateTime.now(),
      type: employee.scheduleType,
      startDate: employee.scheduleStartDate,
      customWorkdays: employee.customWorkdays,
    );
    final statusColor = worksToday ? Colors.green : Colors.grey;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  child: Text(
                    _initials(employee.fullName),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(employee.fullName,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 3),
                      Text(employee.position.isEmpty
                          ? 'Должность не указана'
                          : employee.position),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Chip(
              avatar: Icon(
                worksToday
                    ? Icons.check_circle_outline
                    : Icons.weekend_outlined,
                size: 18,
                color: statusColor,
              ),
              label:
                  Text(worksToday ? 'Сегодня по графику' : 'Сегодня выходной'),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 10),
            _DetailLine(
                label: 'Подразделение', value: _depName(employee.departmentId)),
            _DetailLine(label: 'Группа', value: _groupName(employee.groupId)),
            _DetailLine(label: 'Рабочий график', value: schedule),
            _DetailLine(label: 'Смена', value: '${employee.shiftHours} ч'),
            _DetailLine(label: 'Перерыв', value: '${employee.breakHours} ч'),
            _DetailLine(label: 'Логин', value: linked?.login ?? 'Не создан'),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    canEdit ? () => _openEmployee(employee!, canEdit) : null,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Редактировать'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String value) {
    return value
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final canView = _canViewEmployees;
    final canEdit = _canEditEmployees;
    final list = _filteredEmployees;
    final isPhone = MediaQuery.of(context).size.shortestSide < 600;
    final isDesktop = MediaQuery.sizeOf(context).width >= 1100;

    final u = AuthService.instance.currentUser;
    final currentRole =
        u == null ? null : AuthService.instance.roleById(u.roleId);
    final noBinding = u != null &&
        !_isSuperAdmin &&
        _employeesVisible.isEmpty &&
        currentRole != null;

    return AdaptiveScaffold(
      title: 'Сотрудники',
      selectedRoute: '/employees',
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 8 : 12),
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
                          'Нет доступа: у вашей роли нет права "Просмотр сотрудников".',
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
                      _heroCard(isPhone),
                      const SizedBox(height: 12),
                      _scopeHint(),
                      if (noBinding &&
                          currentRole.scopeKind != ScopeKind.all) ...[
                        const SizedBox(height: 12),
                        const Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(Icons.warning_amber),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Для вашей роли не настроена привязка (сотрудник, группа или подразделение). Из-за этого список сейчас пуст.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _filtersCard(),
                      const SizedBox(height: 12),
                      Expanded(
                        child: list.isEmpty
                            ? _emptyState(noBinding)
                            : isDesktop
                                ? Row(
                                    children: [
                                      Expanded(
                                          flex: 7,
                                          child: _desktopList(list, canEdit)),
                                      const SizedBox(width: 12),
                                      SizedBox(
                                          width: 360,
                                          child: _employeePreview(canEdit)),
                                    ],
                                  )
                                : ListView.separated(
                                    itemCount: list.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      return _employeeTile(
                                          list[index], canEdit);
                                    },
                                  ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _EmployeeTableRow extends StatelessWidget {
  final String name;
  final String? initials;
  final String position;
  final String schedule;
  final String department;
  final bool header;

  const _EmployeeTableRow({
    required this.name,
    this.initials,
    required this.position,
    required this.schedule,
    required this.department,
    this.header = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = header
        ? Theme.of(context).textTheme.labelLarge
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Row(
            children: [
              if (!header) ...[
                CircleAvatar(radius: 18, child: Text(initials ?? '')),
                const SizedBox(width: 10),
              ],
              Expanded(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis, style: style)),
            ],
          ),
        ),
        Expanded(
            flex: 3,
            child:
                Text(position, overflow: TextOverflow.ellipsis, style: style)),
        Expanded(flex: 2, child: Text(schedule, style: style)),
        Expanded(
            flex: 3,
            child: Text(department,
                overflow: TextOverflow.ellipsis, style: style)),
      ],
    );
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
