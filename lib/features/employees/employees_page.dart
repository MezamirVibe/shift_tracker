import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'employee_editor_dialog.dart';
import 'employees_storage.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({super.key});

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _storage = EmployeesStorage();

  bool _loading = true;
  List<EmployeeModel> _employees = [];

  bool get _canViewEmployees => AuthService.instance.hasPerm(AppPermission.viewEmployees);
  bool get _canEditEmployees => AuthService.instance.hasPerm(AppPermission.editEmployees);

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    final loaded = await _storage.load();
    if (!mounted) return;
    setState(() {
      _employees = loaded;
      _loading = false;
    });
  }

  Future<void> _saveEmployees() async {
    await _storage.save(_employees);
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
      _employees = [..._employees, newEmployee];
    });

    await _saveEmployees();
  }

  Future<void> _applyEmployeeResult(EmployeeModel current, Map<String, dynamic> res) async {
    if (res['deleted'] == true) {
      setState(() {
        _employees = _employees.where((x) => x.id != current.id).toList();
      });
      await _saveEmployees();
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
    );

    setState(() {
      _employees = _employees.map((x) => x.id == current.id ? updated : x).toList();
    });

    await _saveEmployees();
  }

  @override
  Widget build(BuildContext context) {
    final canView = _canViewEmployees;
    final canEdit = _canEditEmployees;

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
      floatingActionButton: canEdit
          ? FloatingActionButton(
              onPressed: _addEmployee,
              child: const Icon(Icons.add),
            )
          : null,
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
                      Expanded(
                        child: Text(
                          'Нет доступа: у твоей роли нет права "Просмотр сотрудников".',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : _employees.isEmpty
                    ? Center(
                        child: Text(
                          canEdit
                              ? 'Пока нет сотрудников.\nНажми "+" чтобы добавить.'
                              : 'Список сотрудников пуст.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      )
                    : ListView.separated(
                        itemCount: _employees.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final e = _employees[index];

                          return ListTile(
                            title: Text(e.fullName),
                            subtitle: Text('${e.position} • оклад ${e.salary} ₽ • премия ${e.bonus} ₽'),
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
                              // Детали сотрудника у тебя сейчас позволяют редактировать график/увольнять.
                              // Если прав нет — просто не пускаем, чтобы не давать обход.
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
    );
  }
}
