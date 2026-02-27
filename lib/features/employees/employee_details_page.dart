import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../structure/structure_storage.dart';
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

class _EmployeeDetailsPageState extends State<EmployeeDetailsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 5, vsync: this);

  final _storage = EmployeesStorage();
  final _structureStorage = StructureStorage();

  bool _loading = true;

  // данные сотрудника
  String _fullName = '';
  String _position = '';
  int _salary = 0;
  int _bonus = 0;

  // структура
  String? _departmentId;
  String? _groupId;

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

      _departmentId = e.departmentId;
      _groupId = e.groupId;

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

      _departmentId = updated.departmentId;
      _groupId = updated.groupId;

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
      'departmentId': _departmentId,
      'groupId': _groupId,
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
            Tab(text: 'Структура'),
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
            onChanged: (
              nextType,
              nextStart,
              nextShiftHours,
              nextBreakHours,
            ) async {
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

          _StructureTab(
            departmentId: _departmentId,
            groupId: _groupId,
            storage: _structureStorage,
            onChanged: (depId, grpId) async {
              final current = await _getFreshEmployee();
              if (current == null) return;

              final updated = current.copyWith(
                departmentId: depId,
                groupId: grpId,
                clearDepartment: depId == null,
                clearGroup: grpId == null,
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

class _StructureTab extends StatefulWidget {
  final String? departmentId;
  final String? groupId;
  final StructureStorage storage;
  final Future<void> Function(String? departmentId, String? groupId) onChanged;

  const _StructureTab({
    required this.departmentId,
    required this.groupId,
    required this.storage,
    required this.onChanged,
  });

  @override
  State<_StructureTab> createState() => _StructureTabState();
}

class _StructureTabState extends State<_StructureTab> {
  bool _loading = true;
  List<DepartmentModel> _deps = [];
  List<GroupModel> _groups = [];

  String? _depId;
  String? _groupId;

  @override
  void initState() {
    super.initState();
    _depId = widget.departmentId;
    _groupId = widget.groupId;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final deps = await widget.storage.loadDepartments();
    final groups = await widget.storage.loadGroups();

    if (!mounted) return;

    setState(() {
      _deps = deps..sort((a, b) => a.name.compareTo(b.name));
      _groups = groups..sort((a, b) => a.name.compareTo(b.name));
      _loading = false;
    });

    // если выбранная группа не принадлежит выбранному подразделению — сбросим
    if (_groupId != null && _depId != null) {
      final g = _groups.where((x) => x.id == _groupId).cast<GroupModel?>().firstOrNull;
      if (g != null && g.departmentId != _depId) {
        _groupId = null;
        await widget.onChanged(_depId, _groupId);
        if (!mounted) return;
        setState(() {});
      }
    }
  }

  List<GroupModel> get _groupsForSelectedDep {
    final depId = _depId;
    if (depId == null || depId.isEmpty) return [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final groups = _groupsForSelectedDep;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Подразделение', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: _depId,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— не выбрано —')),
                    ..._deps.map((d) => DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
                  ],
                  onChanged: (v) async {
                    setState(() {
                      _depId = v;
                      _groupId = null; // при смене подразделения сбрасываем группу
                    });
                    await widget.onChanged(_depId, _groupId);
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
                Text('Группа', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: _groupId,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— не выбрано —')),
                    ...groups.map((g) => DropdownMenuItem<String?>(value: g.id, child: Text(g.name))),
                  ],
                  onChanged: (_depId == null)
                      ? null
                      : (v) async {
                          setState(() => _groupId = v);
                          await widget.onChanged(_depId, _groupId);
                        },
                ),
                const SizedBox(height: 8),
                if (_depId == null)
                  const Text('Сначала выбери подразделение, чтобы выбрать группу.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Обновить списки'),
        ),
      ],
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
                  initialValue: scheduleType,
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
                  initialValue: shiftHours,
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
                  final label = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
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