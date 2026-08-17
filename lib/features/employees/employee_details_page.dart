import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/extensions/iterable_x.dart';
import '../auth/auth_service.dart';
import '../auth/auth_storage.dart';
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

class _EmployeeDetailsPageState extends State<EmployeeDetailsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 5, vsync: this);

  final _storage = EmployeesStorage();
  final _structureStorage = StructureStorage();

  bool _loading = true;

  String _fullName = '';
  String _position = '';
  int _salary = 0;
  int _bonus = 0;

  String? _departmentId;
  String? _groupId;

  ScheduleType _scheduleType = ScheduleType.twoTwo;
  DateTime _startDate = DateTime.now();
  int _shiftHours = 12;
  int _breakHours = 1;

  UserAccount? _linkedUser;

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
      _linkedUser = AuthService.instance.userByEmployeeId(widget.id);
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
      _linkedUser = AuthService.instance.userByEmployeeId(widget.id);
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
          departmentId: _departmentId,
          groupId: _groupId,
          scheduleType: _scheduleType,
          scheduleStartDate: _startDate,
          shiftHours: _shiftHours,
          breakHours: _breakHours,
        ),
        title: 'Редактировать сотрудника',
        confirmText: 'Сохранить',
      ),
    );

    if (!mounted || draft == null) return;

    final current = await _getFreshEmployee();

    if (!mounted || current == null) return;

    final updated = current.copyWith(
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
      clearDepartment: draft.departmentId == null,
      clearGroup: draft.groupId == null,
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
    context.pop(<String, dynamic>{'deleted': true});
  }

  Future<void> _resetPassword() async {
    final user = _linkedUser;
    if (user == null) return;

    final newPassword = await AuthService.instance.resetPassword(user.id);
    if (!mounted) return;

    if (newPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сбросить пароль')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Пароль сброшен'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _kv('Логин', user.login),
            const SizedBox(height: 8),
            _kv('Новый временный пароль', newPassword),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Пароль показывается только сейчас.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: 'Логин: ${user.login}\nНовый пароль: $newPassword',
                ),
              );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Данные скопированы')),
              );
            },
            child: const Text('Скопировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );

    setState(() {
      _linkedUser = AuthService.instance.userByEmployeeId(widget.id);
    });
  }

  Widget _kv(String label, String value) {
    return Row(
      children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  void _popWithUpdated() {
    context.pop(<String, dynamic>{
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

  String _formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year}';
  }

  String _scheduleLabel(ScheduleType type) {
    switch (type) {
      case ScheduleType.twoTwo:
        return '2/2';
      case ScheduleType.fiveTwo:
        return '5/2';
    }
  }

  Widget _heroCard(bool isPhone) {
    final roleName = _linkedUser == null
        ? null
        : AuthService.instance.roleById(_linkedUser!.roleId)?.name;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _fullName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              _position,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('Оклад $_salary ₽')),
                Chip(label: Text('Премия $_bonus ₽')),
                Chip(label: Text('График ${_scheduleLabel(_scheduleType)}')),
                if (_linkedUser != null)
                  Chip(label: Text('Логин: ${_linkedUser!.login}')),
                if (roleName != null) Chip(label: Text('Роль: $roleName')),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Редактировать'),
                ),
                OutlinedButton.icon(
                  onPressed: _fire,
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('Уволить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = MediaQuery.of(context).size.shortestSide < 600;

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
        title: const Text('Карточка сотрудника'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: 'График'),
            Tab(text: 'Структура'),
            Tab(text: 'Зарплата'),
            Tab(text: 'Доступ'),
            Tab(text: 'История'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                isPhone ? 8 : 12, isPhone ? 8 : 12, isPhone ? 8 : 12, 0),
            child: _heroCard(isPhone),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _ScheduleTab(
                  scheduleType: _scheduleType,
                  startDate: _startDate,
                  shiftHours: _shiftHours,
                  breakHours: _breakHours,
                  onChanged: (nextType, nextStart, nextShiftHours,
                      nextBreakHours) async {
                    final current = await _getFreshEmployee();
                    if (!mounted || current == null) return;

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
                    if (!mounted || current == null) return;

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
                _AccessTab(
                  user: _linkedUser,
                  roleName: _linkedUser == null
                      ? null
                      : AuthService.instance
                          .roleById(_linkedUser!.roleId)
                          ?.name,
                  onResetPassword: _resetPassword,
                ),
                const _HistoryTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccessTab extends StatelessWidget {
  final UserAccount? user;
  final String? roleName;
  final Future<void> Function() onResetPassword;

  const _AccessTab({
    required this.user,
    required this.roleName,
    required this.onResetPassword,
  });

  @override
  Widget build(BuildContext context) {
    if (user == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_off_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'Связанная учётная запись не найдена.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Доступ в приложение',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Управление учётной записью сотрудника.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text('Логин: ${user!.login}')),
                    Chip(label: Text('Роль: ${roleName ?? user!.roleId}')),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onResetPassword,
                  icon: const Icon(Icons.lock_reset),
                  label: const Text('Сбросить пароль'),
                ),
              ],
            ),
          ),
        ),
      ],
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

  List<dynamic> _deps = <dynamic>[];
  List<dynamic> _groups = <dynamic>[];

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

    if (_groupId != null && _depId != null) {
      final g = _groups.where((x) => x.id == _groupId).firstOrNull;
      if (g != null && g.departmentId != _depId) {
        _groupId = null;
        await widget.onChanged(_depId, _groupId);

        if (!mounted) return;
        setState(() {});
      }
    }
  }

  List<dynamic> get _groupsForSelectedDep {
    final depId = _depId;
    if (depId == null || depId.isEmpty) return <dynamic>[];
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
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Подразделение',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Определи, где числится сотрудник.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _depId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('— не выбрано —'),
                    ),
                    ..._deps.map(
                      (d) => DropdownMenuItem<String?>(
                        value: d.id as String,
                        child: Text(d.name as String),
                      ),
                    ),
                  ],
                  onChanged: (v) async {
                    setState(() {
                      _depId = v;
                      _groupId = null;
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
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Группа',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Выбери группу внутри подразделения.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _groupId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('— не выбрано —'),
                    ),
                    ...groups.map(
                      (g) => DropdownMenuItem<String?>(
                        value: g.id as String,
                        child: Text(g.name as String),
                      ),
                    ),
                  ],
                  onChanged: (_depId == null)
                      ? null
                      : (v) async {
                          setState(() => _groupId = v);
                          await widget.onChanged(_depId, _groupId);
                        },
                ),
              ],
            ),
          ),
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

  String _scheduleLabel(ScheduleType type) {
    switch (type) {
      case ScheduleType.twoTwo:
        return '2/2';
      case ScheduleType.fiveTwo:
        return '5/2';
    }
  }

  String _formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Параметры графика',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Основные параметры рабочего графика сотрудника.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<ScheduleType>(
                  initialValue: scheduleType,
                  decoration: const InputDecoration(
                    labelText: 'Тип графика',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ScheduleType.twoTwo,
                      child: Text('2/2'),
                    ),
                    DropdownMenuItem(
                      value: ScheduleType.fiveTwo,
                      child: Text('5/2'),
                    ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await onChanged(v, startDate, shiftHours, breakHours);
                  },
                ),
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Дата старта: ${_formatDate(startDate)}',
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
                            await onChanged(
                              scheduleType,
                              picked,
                              shiftHours,
                              breakHours,
                            );
                          },
                          child: const Text('Выбрать'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: shiftHours,
                  decoration: const InputDecoration(
                    labelText: 'Длительность смены',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 9, child: Text('9 часов')),
                    DropdownMenuItem(value: 12, child: Text('12 часов')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    final nextBreak = breakHours >= v ? v - 1 : breakHours;
                    await onChanged(scheduleType, startDate, v, nextBreak);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: breakHours,
                  decoration: const InputDecoration(
                    labelText: 'Перерыв',
                    border: OutlineInputBorder(),
                  ),
                  items: List.generate(
                    shiftHours,
                    (i) => DropdownMenuItem<int>(
                      value: i,
                      child: Text('$i час(а)'),
                    ),
                  ),
                  onChanged: (v) async {
                    if (v == null) return;
                    await onChanged(scheduleType, startDate, shiftHours, v);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Быстрый обзор',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Ближайшие 14 дней по текущему графику.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ...List.generate(14, (i) {
                  final d = DateTime.now().add(Duration(days: i));
                  final isWork = isWorkDay(
                    day: d,
                    type: scheduleType,
                    startDate: startDate,
                  );
                  final label =
                      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Theme.of(context).colorScheme.surfaceContainerLowest,
                    child: ListTile(
                      dense: true,
                      title: Text(label),
                      subtitle: Text('График ${_scheduleLabel(scheduleType)}'),
                      trailing: Text(isWork ? 'Смена' : 'Выходной'),
                    ),
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
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Оплата',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Базовые параметры оплаты сотрудника.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Chip(label: Text('Оклад $salary ₽')),
                    Chip(label: Text('Премия $bonus ₽')),
                    Chip(label: Text('Итого ${salary + bonus} ₽')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'История изменений появится позже.',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
