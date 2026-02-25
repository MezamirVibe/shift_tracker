import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'employee_editor_dialog.dart';
import 'employees_storage.dart';
import 'schedule_utils.dart';

class EmployeeDetailsPage extends StatefulWidget {
  final String id;

  const EmployeeDetailsPage({
    super.key,
    required this.id,
  });

  @override
  State<EmployeeDetailsPage> createState() => _EmployeeDetailsPageState();
}

class _EmployeeDetailsPageState extends State<EmployeeDetailsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 4, vsync: this);

  final _storage = EmployeesStorage();

  bool _loading = true;

  // данные сотрудника
  String _fullName = '';
  String _position = '';
  int _salary = 0;
  int _bonus = 0;

  // график
  ScheduleType _scheduleType = ScheduleType.twoTwo;
  DateTime _startDate = DateTime.now();
  int _shiftHours = 12;
  int _breakHours = 1;

  @override
  void initState() {
    super.initState();
    _loadEmployee();
  }

  Future<void> _loadEmployee() async {
    final all = await _storage.load();
    final e = all.where((x) => x.id == widget.id).firstOrNull;

    if (!mounted) return;

    if (e == null) {
      setState(() => _loading = false);
      return;
    }

    setState(() {
      _fullName = e.fullName;
      _position = e.position;
      _salary = e.salary;
      _bonus = e.bonus;

      _scheduleType = e.scheduleType;
      _startDate = e.scheduleStartDate;
      _shiftHours = e.shiftHours;
      _breakHours = e.breakHours;

      _loading = false;
    });
  }

  Future<EmployeeModel?> _getFreshEmployee() async {
    final all = await _storage.load();
    return all.where((x) => x.id == widget.id).firstOrNull;
  }

  Future<void> _saveEmployee(EmployeeModel updated) async {
    final all = await _storage.load();
    final updatedAll = all.map((x) => x.id == widget.id ? updated : x).toList();
    await _storage.save(updatedAll);

    if (!mounted) return;
    setState(() {
      _fullName = updated.fullName;
      _position = updated.position;
      _salary = updated.salary;
      _bonus = updated.bonus;

      _scheduleType = updated.scheduleType;
      _startDate = updated.scheduleStartDate;
      _shiftHours = updated.shiftHours;
      _breakHours = updated.breakHours;
    });
  }

  Future<void> _edit() async {
    final draft = await showDialog<EmployeeDraft>(
      context: context,
      builder: (context) => EmployeeEditorDialog(
        initial: EmployeeDraft(
          fullName: _fullName,
          position: _position,
          salary: _salary,
          bonus: _bonus,
        ),
        title: 'Редактировать сотрудника',
        confirmText: 'Сохранить',
      ),
    );

    if (draft == null) return;

    final current = await _getFreshEmployee();
    if (current == null) return;

    final updated = current.copyWith(
      fullName: draft.fullName,
      position: draft.position,
      salary: draft.salary,
      bonus: draft.bonus,
    );

    await _saveEmployee(updated);
  }

  Future<void> _fire() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Уволить сотрудника?'),
        content: Text('Уволить "$_fullName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Уволить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final all = await _storage.load();
    final updated = all.where((x) => x.id != widget.id).toList();
    await _storage.save(updated);

    if (!context.mounted) return;
    context.pop({'deleted': true});
  }

  void _popWithUpdated() {
    context.pop({
      'id': widget.id,
      'fullName': _fullName,
      'position': _position,
      'salary': _salary,
      'bonus': _bonus,
      'scheduleType': scheduleTypeToString(_scheduleType),
      'scheduleStartDate': _startDate.toIso8601String(),
      'shiftHours': _shiftHours,
      'breakHours': _breakHours,
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_fullName.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Сотрудник не найден'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
        ),
        body: const Center(child: Text('Запись сотрудника отсутствует.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Назад',
          icon: const Icon(Icons.arrow_back),
          onPressed: _popWithUpdated,
        ),
        title: Text(_fullName),
        actions: [
          IconButton(
            tooltip: 'Редактировать',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
          IconButton(
            tooltip: 'Уволить',
            icon: const Icon(Icons.person_off_outlined),
            onPressed: _fire,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'График'),
            Tab(text: 'Зарплата'),
            Tab(text: 'Штрафы'),
            Tab(text: 'История'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ScheduleTab(
            scheduleType: _scheduleType,
            startDate: _startDate,
            shiftHours: _shiftHours,
            breakHours: _breakHours,
            onChanged: (nextType, nextStart, nextShiftHours, nextBreakHours) async {
              final current = await _getFreshEmployee();
              if (current == null) return;

              final updated = current.copyWith(
                scheduleType: nextType,
                scheduleStartDate: nextStart,
                shiftHours: nextShiftHours,
                breakHours: nextBreakHours,
              );

              await _saveEmployee(updated);
            },
          ),
          _SalaryTab(salary: _salary, bonus: _bonus),
          const _FinesTab(),
          const _HistoryTab(),
        ],
      ),
    );
  }
}

class _ScheduleTab extends StatelessWidget {
  final ScheduleType scheduleType;
  final DateTime startDate;
  final int shiftHours;
  final int breakHours;

  final Future<void> Function(
    ScheduleType scheduleType,
    DateTime startDate,
    int shiftHours,
    int breakHours,
  ) onChanged;

  const _ScheduleTab({
    required this.scheduleType,
    required this.startDate,
    required this.shiftHours,
    required this.breakHours,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Тип графика', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<ScheduleType>(
                  value: scheduleType,
                  items: const [
                    DropdownMenuItem(value: ScheduleType.twoTwo, child: Text('2/2')),
                    DropdownMenuItem(value: ScheduleType.fiveTwo, child: Text('5/2')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await onChanged(v, startDate, shiftHours, breakHours);
                  },
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Дата старта графика', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${startDate.day.toString().padLeft(2, '0')}.'
                        '${startDate.month.toString().padLeft(2, '0')}.'
                        '${startDate.year}',
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                          initialDate: startDate,
                        );
                        if (picked == null) return;
                        await onChanged(scheduleType, picked, shiftHours, breakHours);
                      },
                      child: const Text('Выбрать'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Длительность смены', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: shiftHours,
                  items: const [
                    DropdownMenuItem(value: 9, child: Text('9 часов')),
                    DropdownMenuItem(value: 12, child: Text('12 часов')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await onChanged(scheduleType, startDate, v, breakHours);
                  },
                ),
                const SizedBox(height: 12),
                Text('Перерыв', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('Вычитаем $breakHours час(а) из смены'),
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
                Text('Пример: ближайшие 14 дней', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...List.generate(14, (i) {
                  final d = DateTime.now().add(Duration(days: i));
                  final isWork = isWorkDay(day: d, type: scheduleType, startDate: startDate);
                  final label =
                      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
                  return ListTile(
                    dense: true,
                    title: Text(label),
                    trailing: Text(isWork ? 'Смена' : 'Выходной'),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SalaryTab extends StatelessWidget {
  final int salary;
  final int bonus;

  const _SalaryTab({required this.salary, required this.bonus});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Оклад', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('$salary ₽'),
                const SizedBox(height: 12),
                Text('Премия', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('$bonus ₽'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FinesTab extends StatelessWidget {
  const _FinesTab();

  @override
  Widget build(BuildContext context) => const Center(child: Text('Штрафы: позже'));
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context) => const Center(child: Text('История: позже'));
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
