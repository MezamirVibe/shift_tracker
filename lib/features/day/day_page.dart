import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
import '../preferences/preferences_service.dart';
import '../structure/structure_storage.dart';
import 'attendance_deviation.dart';

class DayPage extends StatefulWidget {
  final String dateIso;
  const DayPage({super.key, required this.dateIso});

  @override
  State<DayPage> createState() => _DayPageState();
}

class _DayPageState extends State<DayPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();
  final _structureStorage = StructureStorage();
  final _preferences = PreferencesService.instance;
  final _searchController = TextEditingController();

  bool _loading = true;
  bool _closed = false;

  late final DateTime _day;
  late final String _dateIso;

  List<EmployeeModel> _planned = <EmployeeModel>[];
  List<GroupModel> _groups = <GroupModel>[];
  Set<String> _scopeGroupIds = <String>{};
  Map<String, AttendanceRecord> _recordsById = <String, AttendanceRecord>{};
  bool _groupByGroup = true;
  String _search = '';
  FactStatus? _statusFilter;
  String? _positionFilter;
  bool _bulkSaving = false;
  bool _mobileToolsExpanded = false;
  final Set<String> _savingEmployeeIds = <String>{};
  final Set<String> _expandedGroups = <String>{};

  @override
  void initState() {
    super.initState();
    _dateIso = widget.dateIso;
    _day = DateTime.parse(widget.dateIso);
    _searchController.addListener(() {
      if (mounted) {
        setState(() => _search = _searchController.text.trim().toLowerCase());
      }
    });
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _canEditAttendance =>
      AuthService.instance.hasPerm(AppPermission.editAttendance);

  Future<void> _load({bool force = false}) async {
    final results = await Future.wait([
      _employeesStorage.load(force: force),
      _structureStorage.loadGroups(force: force),
      _attendanceStorage.loadDay(_dateIso, force: force),
      _preferences.syncForCurrentUser(force: force),
    ]);
    final allEmployees = results[0] as List<EmployeeModel>;
    final groups = results[1] as List<GroupModel>;

    // ✅ scope по роли
    final scopedEmployees =
        AuthService.instance.filterEmployeesByScope(allEmployees);
    final visibleEmployees = scopedEmployees
        .where((employee) => _preferences.isGroupVisible(employee.groupId))
        .toList();

    final d = dateOnly(_day);
    final planned = visibleEmployees.where((e) {
      return isWorkDay(
        day: d,
        type: e.scheduleType,
        startDate: e.scheduleStartDate,
        customWorkdays: e.customWorkdays,
      );
    }).toList();

    final attendance =
        results[2] as ({Map<String, AttendanceRecord> records, bool closed});
    final configurableGroups = groups
        .where(
          (group) => !_preferences.adminHiddenGroupIds.contains(group.id),
        )
        .toList();

    if (!mounted) return;
    setState(() {
      _planned = planned;
      _groups = configurableGroups..sort((a, b) => a.name.compareTo(b.name));
      _scopeGroupIds = scopedEmployees
          .map((employee) => employee.groupId)
          .whereType<String>()
          .toSet();
      _recordsById = attendance.records;
      _closed = attendance.closed;
      _loading = false;
    });
  }

  AttendanceRecord? _recordOf(EmployeeModel e) => _recordsById[e.id];
  FactStatus _factOf(EmployeeModel e) => _recordOf(e)?.fact ?? FactStatus.none;

  String _factLabel(FactStatus s) {
    switch (s) {
      case FactStatus.none:
        return 'Не заполнено';
      case FactStatus.worked:
        return 'Вышел';
      case FactStatus.absent:
        return 'Неявка';
      case FactStatus.sick:
        return 'Больничный';
      case FactStatus.vacation:
        return 'Отпуск';
    }
  }

  int _minutesFor(EmployeeModel e, FactStatus s) {
    switch (s) {
      case FactStatus.worked:
        return _recordOf(e)?.workedMinutes ?? (e.paidShiftHours * 60);
      case FactStatus.none:
        return e.paidShiftHours * 60;
      case FactStatus.absent:
      case FactStatus.sick:
      case FactStatus.vacation:
        return 0;
    }
  }

  TimeOfDay _parseTime(String? value, TimeOfDay fallback) {
    final parts = value?.split(':');
    if (parts == null || parts.length < 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return fallback;
    }
    return TimeOfDay(hour: hour, minute: minute);
  }

  String _timeValue(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  ({TimeOfDay start, TimeOfDay end}) _defaultTimes(EmployeeModel employee) {
    const start = TimeOfDay(hour: 8, minute: 0);
    final endTotal = start.hour * 60 + employee.shiftHours * 60;
    return (
      start: start,
      end: TimeOfDay(hour: (endTotal ~/ 60) % 24, minute: endTotal % 60),
    );
  }

  int _workedMinutesBetween(
    TimeOfDay start,
    TimeOfDay end,
    EmployeeModel employee, {
    bool deductBreak = true,
  }) {
    final startMinutes = start.hour * 60 + start.minute;
    var endMinutes = end.hour * 60 + end.minute;
    if (endMinutes <= startMinutes) endMinutes += 24 * 60;
    final breakMinutes = deductBreak ? employee.breakHours * 60 : 0;
    return (endMinutes - startMinutes - breakMinutes).clamp(0, 24 * 60);
  }

  AttendanceDeviation _timeDeviations(
    EmployeeModel employee,
    TimeOfDay actualStart,
    TimeOfDay actualEnd,
  ) {
    final planned = _defaultTimes(employee);
    final plannedStart = planned.start.hour * 60 + planned.start.minute;
    final plannedEnd = planned.end.hour * 60 + planned.end.minute;

    return calculateAttendanceDeviation(
      plannedStartMinutes: plannedStart,
      plannedEndMinutes: plannedEnd,
      actualStartMinutes: actualStart.hour * 60 + actualStart.minute,
      actualEndMinutes: actualEnd.hour * 60 + actualEnd.minute,
    );
  }

  String? _deviationLabel(
    EmployeeModel employee,
    AttendanceRecord? record,
  ) {
    if (record?.fact != FactStatus.worked ||
        record?.actualStart == null ||
        record?.actualEnd == null) {
      return null;
    }
    final defaults = _defaultTimes(employee);
    final deviations = _timeDeviations(
      employee,
      _parseTime(record!.actualStart, defaults.start),
      _parseTime(record.actualEnd, defaults.end),
    );
    final parts = <String>[
      if (deviations.lateMinutes > 0) 'Опоздание ${deviations.lateMinutes} мин',
      if (deviations.earlyLeaveMinutes > 0)
        'Ранний уход ${deviations.earlyLeaveMinutes} мин',
      if (deviations.overtimeMinutes > 0)
        'Переработка ${deviations.overtimeMinutes} мин',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _deviationSummary(
    EmployeeModel employee,
    TimeOfDay actualStart,
    TimeOfDay actualEnd,
  ) {
    final deviations = _timeDeviations(employee, actualStart, actualEnd);
    final scheme = Theme.of(context).colorScheme;

    Widget item(String label, IconData icon, Color color) => Chip(
          avatar: Icon(icon, size: 17, color: color),
          label: Text(label),
          side: BorderSide(color: color.withValues(alpha: 0.45)),
        );

    if (!deviations.hasDeviations) {
      return Align(
        alignment: Alignment.centerLeft,
        child: item(
          'Без отклонений от графика',
          Icons.check_circle_outline,
          context.shiftColors.success,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (deviations.lateMinutes > 0)
            item(
              'Опоздание: ${deviations.lateMinutes} мин',
              Icons.schedule,
              context.shiftColors.warning,
            ),
          if (deviations.earlyLeaveMinutes > 0)
            item(
              'Ранний уход: ${deviations.earlyLeaveMinutes} мин',
              Icons.logout,
              scheme.error,
            ),
          if (deviations.overtimeMinutes > 0)
            item(
              'Переработка: ${deviations.overtimeMinutes} мин',
              Icons.more_time,
              context.shiftColors.success,
            ),
        ],
      ),
    );
  }

  Future<void> _setFact(
    EmployeeModel e,
    FactStatus fact, {
    String? comment,
    int? workedMinutes,
    String? actualStart,
    String? actualEnd,
  }) async {
    if (_savingEmployeeIds.contains(e.id) || _bulkSaving || _closed) return;
    final previous = _recordsById[e.id];
    final next = AttendanceRecord(
      fact: fact,
      comment: comment,
      workedMinutes: workedMinutes,
      actualStart: actualStart,
      actualEnd: actualEnd,
    );
    setState(() {
      _recordsById = {..._recordsById, e.id: next};
      _savingEmployeeIds.add(e.id);
    });
    try {
      await _attendanceStorage.setFact(
        dateIso: _dateIso,
        employeeId: e.id,
        fact: fact,
        comment: comment,
        workedMinutes: workedMinutes,
        actualStart: actualStart,
        actualEnd: actualEnd,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        final restored = {..._recordsById};
        if (previous == null) {
          restored.remove(e.id);
        } else {
          restored[e.id] = previous;
        }
        _recordsById = restored;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить отметку: $error')),
      );
    } finally {
      if (mounted) setState(() => _savingEmployeeIds.remove(e.id));
    }
  }

  Future<void> _setFacts(
    List<EmployeeModel> employees,
    FactStatus fact,
  ) async {
    if (employees.isEmpty || _bulkSaving || _closed) return;
    final targets = fact == FactStatus.worked
        ? employees.where((employee) => _factOf(employee) != fact).toList()
        : employees;
    if (targets.isEmpty) return;
    final updates = <String, AttendanceRecord>{
      for (final employee in targets)
        employee.id: AttendanceRecord(
          fact: fact,
          comment: _recordsById[employee.id]?.comment,
          workedMinutes:
              fact == FactStatus.worked ? employee.paidShiftHours * 60 : 0,
          actualStart: fact == FactStatus.worked
              ? _timeValue(_defaultTimes(employee).start)
              : null,
          actualEnd: fact == FactStatus.worked
              ? _timeValue(_defaultTimes(employee).end)
              : null,
        ),
    };
    final previous = Map<String, AttendanceRecord>.from(_recordsById);
    setState(() {
      _bulkSaving = true;
      _recordsById = {..._recordsById, ...updates};
    });
    try {
      await _attendanceStorage.setFacts(
        dateIso: _dateIso,
        recordsByEmployeeId: updates,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _recordsById = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Не удалось выполнить массовую отметку: $error')),
      );
    } finally {
      if (mounted) setState(() => _bulkSaving = false);
    }
  }

  bool _allWorked(List<EmployeeModel> employees) =>
      employees.isNotEmpty &&
      employees.every((employee) => _factOf(employee) == FactStatus.worked);

  Future<void> _toggleAllWorked(
    List<EmployeeModel> employees, {
    required String markTitle,
    required String clearTitle,
  }) async {
    if (employees.isEmpty) return;
    final clear = _allWorked(employees);
    final targetCount = clear
        ? employees.length
        : employees
            .where((employee) => _factOf(employee) != FactStatus.worked)
            .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(clear ? clearTitle : markTitle),
        content: Text(
          clear
              ? 'Снять отметку о выходе у $targetCount сотрудников?'
              : 'Отметить статус «Вышел» для $targetCount сотрудников?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(clear ? 'Снять отметки' : 'Отметить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _setFacts(
        employees,
        clear ? FactStatus.none : FactStatus.worked,
      );
    }
  }

  Future<void> _edit(EmployeeModel e) async {
    final canEditNow = _canEditAttendance && !_closed;
    final current = _recordOf(e);

    FactStatus fact = current?.fact ?? FactStatus.none;
    final commentController =
        TextEditingController(text: current?.comment ?? '');
    final defaults = _defaultTimes(e);
    var actualStart = _parseTime(current?.actualStart, defaults.start);
    var actualEnd = _parseTime(current?.actualEnd, defaults.end);
    var deductBreak = current?.workedMinutes == null ||
        current!.workedMinutes ==
            _workedMinutesBetween(actualStart, actualEnd, e);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: Text(e.fullName),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<FactStatus>(
                      initialValue: fact,
                      items: const [
                        DropdownMenuItem(
                          value: FactStatus.none,
                          child: Text('Не заполнено'),
                        ),
                        DropdownMenuItem(
                          value: FactStatus.worked,
                          child: Text('Вышел'),
                        ),
                        DropdownMenuItem(
                          value: FactStatus.absent,
                          child: Text('Неявка'),
                        ),
                        DropdownMenuItem(
                          value: FactStatus.sick,
                          child: Text('Больничный'),
                        ),
                        DropdownMenuItem(
                          value: FactStatus.vacation,
                          child: Text('Отпуск'),
                        ),
                      ],
                      onChanged: canEditNow
                          ? (v) {
                              if (v == null) return;
                              setLocalState(() => fact = v);
                            }
                          : null,
                      decoration: const InputDecoration(labelText: 'Факт'),
                    ),
                    if (fact == FactStatus.worked) ...[
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'План: ${_timeValue(defaults.start)}–${_timeValue(defaults.end)}. '
                          'Укажите фактическое начало и окончание — опоздание, ранний уход и переработка рассчитаются автоматически.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: canEditNow
                                  ? () async {
                                      final selected = await showTimePicker(
                                        context: context,
                                        initialTime: actualStart,
                                        helpText: 'Время начала работы',
                                      );
                                      if (selected != null) {
                                        setLocalState(
                                          () => actualStart = selected,
                                        );
                                      }
                                    }
                                  : null,
                              icon: const Icon(Icons.login),
                              label: Text(
                                'Начало: ${_timeValue(actualStart)}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: canEditNow
                                  ? () async {
                                      final selected = await showTimePicker(
                                        context: context,
                                        initialTime: actualEnd,
                                        helpText: 'Время окончания работы',
                                      );
                                      if (selected != null) {
                                        setLocalState(
                                            () => actualEnd = selected);
                                      }
                                    }
                                  : null,
                              icon: const Icon(Icons.logout),
                              label: Text(
                                'Окончание: ${_timeValue(actualEnd)}',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _deviationSummary(e, actualStart, actualEnd),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Оплачиваемое время: ${_workedMinutesBetween(actualStart, actualEnd, e, deductBreak: deductBreak)} мин '
                          '(перерыв: ${deductBreak ? e.breakHours * 60 : 0} мин)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (e.breakHours > 0)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: deductBreak,
                          title: Text(
                            'Вычесть стандартный перерыв '
                            '(${e.breakHours * 60} мин)',
                          ),
                          subtitle: const Text(
                            'Отключите, если сотрудник не использовал перерыв.',
                          ),
                          onChanged: canEditNow
                              ? (value) => setLocalState(
                                    () => deductBreak = value,
                                  )
                              : null,
                        ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: commentController,
                      enabled: canEditNow,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Комментарий',
                        hintText: 'Например: отпустили раньше в 15:00',
                      ),
                    ),
                    if (!canEditNow) ...[
                      const SizedBox(height: 12),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Режим просмотра: нет прав или день закрыт.',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(canEditNow ? 'Отмена' : 'Закрыть'),
              ),
              if (canEditNow)
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Сохранить'),
                ),
            ],
          ),
        );
      },
    );

    final comment = commentController.text.trim();
    commentController.dispose();
    if (saved != true) return;

    final minutesToSave = fact == FactStatus.worked
        ? _workedMinutesBetween(
            actualStart,
            actualEnd,
            e,
            deductBreak: deductBreak,
          )
        : 0;

    await _setFact(
      e,
      fact,
      comment: comment.isEmpty ? null : comment,
      workedMinutes: minutesToSave,
      actualStart: fact == FactStatus.worked ? _timeValue(actualStart) : null,
      actualEnd: fact == FactStatus.worked ? _timeValue(actualEnd) : null,
    );
  }

  Future<void> _closeDay() async {
    if (!_canEditAttendance) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Закрыть день?'),
        content: const Text(
          'После закрытия дня все сотрудники со статусом «Не заполнено» автоматически получат статус «Неявка».\n\nПродолжить?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Закрыть день'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await _attendanceStorage.closeDay(
      dateIso: _dateIso,
      plannedEmployeeIds: _planned.map((e) => e.id).toList(),
    );

    if (!mounted) return;
    await _load();
  }

  Future<void> _reopenDay() async {
    if (!_canEditAttendance) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переоткрыть день?'),
        content: const Text(
            'День снова станет доступен для изменений.\n\nПродолжить?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Переоткрыть'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await _attendanceStorage.reopenDay(dateIso: _dateIso);

    if (!mounted) return;
    await _load();
  }

  String _groupName(String? groupId) {
    if (groupId == null) return 'Без группы';
    for (final group in _groups) {
      if (group.id == groupId) return group.name;
    }
    return 'Без группы';
  }

  List<GroupModel> get _groupsAvailableForCurrentUser {
    final auth = AuthService.instance;
    final user = auth.currentUser;
    final role = auth.roleById(user?.roleId);
    if (user == null || role == null) return const [];
    switch (role.scopeKind) {
      case ScopeKind.all:
        return List<GroupModel>.of(_groups);
      case ScopeKind.department:
        return _groups
            .where((group) => group.departmentId == user.departmentId)
            .toList();
      case ScopeKind.group:
        return _groups.where((group) => group.id == user.groupId).toList();
      case ScopeKind.self:
        return _groups
            .where((group) => _scopeGroupIds.contains(group.id))
            .toList();
    }
  }

  Future<void> _manageGroupVisibility() async {
    final available = _groupsAvailableForCurrentUser
      ..sort((a, b) => a.name.compareTo(b.name));
    var hidden = {..._preferences.hiddenGroupIds};
    final adminHiddenCount = _preferences.adminHiddenGroupIds.length;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Видимость групп'),
          content: SizedBox(
            width: 580,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Скрытые группы не показываются в вашем графике. '
                  'Настройка сохраняется только для вашей учётной записи.',
                ),
                if (adminHiddenCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Администратор ограничил доступ ещё к $adminHiddenCount группам. '
                    'Эти ограничения пользователь изменить не может.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Flexible(
                  child: available.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Доступных для настройки групп нет.'),
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final group in available)
                              SwitchListTile(
                                value: !hidden.contains(group.id),
                                title: Text(group.name),
                                subtitle: Text(
                                  hidden.contains(group.id)
                                      ? 'Скрыта вами'
                                      : 'Показывается',
                                ),
                                onChanged: (visible) {
                                  setDialogState(() {
                                    if (visible) {
                                      hidden.remove(group.id);
                                    } else {
                                      hidden.add(group.id);
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
                  : () => setDialogState(() => hidden = <String>{}),
              child: const Text('Показать все группы'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    await _preferences.setHiddenGroupIds(hidden);
    if (mounted) await _load();
  }

  List<EmployeeModel> get _filteredPlanned {
    return _planned.where((employee) {
      if (_statusFilter != null && _factOf(employee) != _statusFilter) {
        return false;
      }
      if (_positionFilter != null && employee.position != _positionFilter) {
        return false;
      }
      if (_search.isEmpty) return true;
      final haystack = '${employee.fullName} ${employee.position} '
              '${_groupName(employee.groupId)} ${_factLabel(_factOf(employee))}'
          .toLowerCase();
      return haystack.contains(_search);
    }).toList();
  }

  List<String> get _availablePositions {
    final result = _planned
        .map((employee) => employee.position.trim())
        .where((position) => position.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  bool get _hasActiveFilters =>
      _search.isNotEmpty || _statusFilter != null || _positionFilter != null;

  Widget _employeeTile(EmployeeModel employee, bool canEditNow) {
    final fact = _factOf(employee);
    final minutes = _minutesFor(employee, fact);
    final hours = (minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1);
    final record = _recordOf(employee);
    final actualTime = fact == FactStatus.worked &&
            record?.actualStart != null &&
            record?.actualEnd != null
        ? '${record!.actualStart}–${record.actualEnd}'
        : null;
    final comment = record?.comment?.trim();
    final hasComment = comment != null && comment.isNotEmpty;
    final deviation = _deviationLabel(employee, record);
    final saving = _savingEmployeeIds.contains(employee.id);
    final canChange = canEditNow && !_bulkSaving && !saving;

    Future<void> setQuickFact(FactStatus value) async {
      if (!canChange) return;
      if (fact == value) return;
      final defaults = _defaultTimes(employee);
      await _setFact(
        employee,
        value,
        workedMinutes:
            value == FactStatus.worked ? employee.paidShiftHours * 60 : 0,
        actualStart: value == FactStatus.worked
            ? (record?.actualStart ?? _timeValue(defaults.start))
            : null,
        actualEnd: value == FactStatus.worked
            ? (record?.actualEnd ?? _timeValue(defaults.end))
            : null,
      );
    }

    final isPhone = MediaQuery.sizeOf(context).width < 680;
    if (isPhone) {
      final scheme = Theme.of(context).colorScheme;

      Widget quickButton({
        required FactStatus value,
        required String label,
        required IconData icon,
      }) {
        final selected = fact == value;
        final selectedColor = value == FactStatus.absent
            ? scheme.errorContainer
            : scheme.primaryContainer;
        final selectedForeground = value == FactStatus.absent
            ? scheme.onErrorContainer
            : scheme.onPrimaryContainer;
        return Expanded(
          child: OutlinedButton.icon(
            onPressed:
                canChange && !selected ? () => setQuickFact(value) : null,
            style: OutlinedButton.styleFrom(
              backgroundColor: selected ? selectedColor : null,
              foregroundColor: selected ? selectedForeground : null,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            icon: Icon(icon, size: 17),
            label: Text(label),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: canChange ? () => _edit(employee) : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            employee.fullName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${employee.position} • ${_factLabel(fact)}'
                            '${actualTime == null ? '' : ' • $actualTime'}'
                            '${deviation == null ? '' : ' • $deviation'}'
                            '${hasComment ? ' • $comment' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (saving)
                  const Padding(
                    padding: EdgeInsets.all(11),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '$hours ч',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  Tooltip(
                    message: 'Время, опоздание и переработка',
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.tune, size: 20),
                      label: const Text('Время'),
                      onPressed: canChange ? () => _edit(employee) : null,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                quickButton(
                  value: FactStatus.worked,
                  label: 'Вышел',
                  icon: Icons.check,
                ),
                const SizedBox(width: 8),
                quickButton(
                  value: FactStatus.absent,
                  label: 'Неявка',
                  icon: Icons.close,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ListTile(
      title: Text(
        employee.fullName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${employee.position} • ${_factLabel(fact)}'
        '${actualTime == null ? '' : ' • $actualTime'}'
        '${deviation == null ? '' : ' • $deviation'}'
        '${hasComment ? ' • $comment' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$hours ч'),
          const SizedBox(width: 12),
          if (saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            SegmentedButton<FactStatus>(
              segments: [
                ButtonSegment(
                  value: FactStatus.worked,
                  label: const Text('Вышел'),
                  icon: const Icon(Icons.check),
                  enabled: fact != FactStatus.worked,
                ),
                ButtonSegment(
                  value: FactStatus.absent,
                  label: const Text('Неявка'),
                  icon: const Icon(Icons.close),
                  enabled: fact != FactStatus.absent,
                ),
              ],
              selected: {
                if (fact == FactStatus.worked) FactStatus.worked,
                if (fact == FactStatus.absent) FactStatus.absent,
              },
              emptySelectionAllowed: true,
              onSelectionChanged: canChange
                  ? (selection) async {
                      if (selection.isEmpty) {
                        return;
                      }
                      await setQuickFact(selection.first);
                    }
                  : null,
            ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Фактическое время, опоздание и переработка',
            child: OutlinedButton.icon(
              icon: const Icon(Icons.schedule, size: 18),
              label: const Text('Время и отклонения'),
              onPressed: canChange ? () => _edit(employee) : null,
            ),
          ),
        ],
      ),
      onTap: canChange ? () => _edit(employee) : null,
    );
  }

  Widget _employeesList(bool canEditNow) {
    final visible = _filteredPlanned;
    final isPhone = MediaQuery.sizeOf(context).width < 680;
    if (!_groupByGroup) {
      return ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) =>
            _employeeTile(visible[index], canEditNow),
      );
    }

    final grouped = <String, List<EmployeeModel>>{};
    for (final employee in visible) {
      grouped.putIfAbsent(_groupName(employee.groupId), () => []).add(employee);
    }
    final names = grouped.keys.toList()..sort();
    final forcedOpen = _hasActiveFilters;
    final rows = <Object>[];
    for (final name in names) {
      final employees = grouped[name]!;
      final expanded = forcedOpen || _expandedGroups.contains(name);
      rows.add(MapEntry<String, List<EmployeeModel>>(name, employees));
      if (expanded) {
        if (canEditNow) rows.add(employees);
        rows.addAll(employees);
      }
    }

    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is MapEntry<String, List<EmployeeModel>>) {
          final name = row.key;
          final employees = row.value;
          final expanded = forcedOpen || _expandedGroups.contains(name);
          return Material(
            key: ValueKey('day-group-$name'),
            color: Colors.transparent,
            child: InkWell(
              onTap: forcedOpen
                  ? null
                  : () => setState(() {
                        if (expanded) {
                          _expandedGroups.remove(name);
                        } else {
                          _expandedGroups.add(name);
                        }
                      }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  children: [
                    const Icon(Icons.groups_2_outlined, size: 21),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text('${employees.length} сотрудников по плану'),
                        ],
                      ),
                    ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          );
        }
        if (row is List<EmployeeModel>) {
          return Padding(
            padding: EdgeInsets.fromLTRB(isPhone ? 12 : 44, 6, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _bulkSaving
                    ? null
                    : () => _toggleAllWorked(
                          row,
                          markTitle: 'Вся группа вышла?',
                          clearTitle: 'Снять отметки у всей группы?',
                        ),
                icon: Icon(
                  _allWorked(row) ? Icons.remove_done : Icons.done_all,
                  size: 18,
                ),
                label: Text(
                  _allWorked(row) ? 'Снять отметки группы' : 'Отметить группу',
                ),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ),
          );
        }
        return _employeeTile(row as EmployeeModel, canEditNow);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title =
        '${_day.day.toString().padLeft(2, '0')}.${_day.month.toString().padLeft(2, '0')}.${_day.year}';

    final plannedCount = _planned.length;
    final workedCount =
        _planned.where((e) => _factOf(e) == FactStatus.worked).length;
    final absentCount =
        _planned.where((e) => _factOf(e) == FactStatus.absent).length;
    final sickCount =
        _planned.where((e) => _factOf(e) == FactStatus.sick).length;
    final vacationCount =
        _planned.where((e) => _factOf(e) == FactStatus.vacation).length;
    final unfilledCount =
        _planned.where((e) => _factOf(e) == FactStatus.none).length;
    final visibleCount = _filteredPlanned.length;

    final canEditNow = _canEditAttendance && !_closed;
    final isPhone = MediaQuery.sizeOf(context).width < 680;

    return AdaptiveScaffold(
      title: isPhone ? title : 'День: $title',
      selectedRoute: '/day/${widget.dateIso}',
      actions: [
        IconButton(
          tooltip: 'Обновить',
          icon: const Icon(Icons.refresh),
          onPressed: () => _load(force: true),
        ),
        if (!isPhone && !_loading && !_closed)
          FilledButton.icon(
            onPressed: (canEditNow && _planned.isNotEmpty && !_bulkSaving)
                ? _closeDay
                : null,
            icon: const Icon(Icons.lock),
            label: const Text('Закрыть день'),
          ),
        if (!isPhone && !_loading && _closed) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Chip(label: Text('День закрыт')),
          ),
          OutlinedButton.icon(
            onPressed: _canEditAttendance ? _reopenDay : null,
            icon: const Icon(Icons.lock_open),
            label: const Text('Переоткрыть'),
          ),
        ],
      ],
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 8 : 12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_canEditAttendance)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.visibility_outlined),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Режим просмотра: у твоей роли нет права "Редактирование факта".',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_closed)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.lock),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'День закрыт.\nИзменение факта отключено.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(isPhone ? 12 : 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isPhone)
                            InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => setState(() {
                                _mobileToolsExpanded = !_mobileToolsExpanded;
                              }),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Wrap(
                                        spacing: 12,
                                        runSpacing: 4,
                                        children: [
                                          Text('План $plannedCount'),
                                          Text('Вышли $workedCount'),
                                          Text('Неявка $absentCount'),
                                          Text(
                                            'Ожидают $unfilledCount',
                                            style: TextStyle(
                                              color: unfilledCount > 0
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .error
                                                  : null,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      _mobileToolsExpanded
                                          ? Icons.expand_less
                                          : Icons.tune,
                                      size: 21,
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                Text('По плану: $plannedCount'),
                                Text('Вышли: $workedCount'),
                                Text('Неявка: $absentCount'),
                                Text('Больничный: $sickCount'),
                                Text('Отпуск: $vacationCount'),
                                Text(
                                  'Не заполнено: $unfilledCount',
                                  style: TextStyle(
                                    color: unfilledCount > 0
                                        ? Theme.of(context).colorScheme.error
                                        : null,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          if (!isPhone || _mobileToolsExpanded) ...[
                            if (isPhone && _canEditAttendance) ...[
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: _closed
                                    ? OutlinedButton.icon(
                                        onPressed: _reopenDay,
                                        icon: const Icon(
                                          Icons.lock_open,
                                          size: 18,
                                        ),
                                        label: const Text('Переоткрыть день'),
                                        style: OutlinedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      )
                                    : FilledButton.tonalIcon(
                                        onPressed: canEditNow &&
                                                _planned.isNotEmpty &&
                                                !_bulkSaving
                                            ? _closeDay
                                            : null,
                                        icon: const Icon(Icons.lock, size: 18),
                                        label: const Text('Закрыть день'),
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                              ),
                            ],
                            const Divider(height: 24),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final narrow = constraints.maxWidth < 760;
                                final search = TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    labelText: 'Найти сотрудника',
                                    hintText: 'ФИО, должность или группа',
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: _search.isEmpty
                                        ? null
                                        : IconButton(
                                            onPressed: _searchController.clear,
                                            icon: const Icon(Icons.clear),
                                          ),
                                    border: const OutlineInputBorder(),
                                  ),
                                );
                                final status =
                                    DropdownButtonFormField<FactStatus?>(
                                  initialValue: _statusFilter,
                                  decoration: const InputDecoration(
                                    labelText: 'Показать статус',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: const [
                                    DropdownMenuItem<FactStatus?>(
                                      value: null,
                                      child: Text('Все статусы'),
                                    ),
                                    DropdownMenuItem<FactStatus?>(
                                      value: FactStatus.none,
                                      child: Text('Не заполнено'),
                                    ),
                                    DropdownMenuItem<FactStatus?>(
                                      value: FactStatus.worked,
                                      child: Text('Вышел'),
                                    ),
                                    DropdownMenuItem<FactStatus?>(
                                      value: FactStatus.absent,
                                      child: Text('Неявка'),
                                    ),
                                    DropdownMenuItem<FactStatus?>(
                                      value: FactStatus.sick,
                                      child: Text('Больничный'),
                                    ),
                                    DropdownMenuItem<FactStatus?>(
                                      value: FactStatus.vacation,
                                      child: Text('Отпуск'),
                                    ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => _statusFilter = value),
                                );
                                final position =
                                    DropdownButtonFormField<String?>(
                                  initialValue: _positionFilter,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Должность',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('Все должности'),
                                    ),
                                    for (final value in _availablePositions)
                                      DropdownMenuItem<String?>(
                                        value: value,
                                        child: Text(
                                          value,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => _positionFilter = value),
                                );
                                if (narrow) {
                                  return Column(
                                    children: [
                                      search,
                                      const SizedBox(height: 10),
                                      status,
                                      const SizedBox(height: 10),
                                      position,
                                    ],
                                  );
                                }
                                return Row(
                                  children: [
                                    Expanded(child: search),
                                    const SizedBox(width: 10),
                                    SizedBox(width: 220, child: status),
                                    const SizedBox(width: 10),
                                    SizedBox(width: 260, child: position),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (canEditNow)
                                  FilledButton.icon(
                                    onPressed: _bulkSaving
                                        ? null
                                        : () => _toggleAllWorked(
                                              _filteredPlanned,
                                              markTitle: !_hasActiveFilters
                                                  ? 'Вся смена вышла?'
                                                  : 'Отметить найденных?',
                                              clearTitle: !_hasActiveFilters
                                                  ? 'Снять отметки у всей смены?'
                                                  : 'Снять отметки у найденных?',
                                            ),
                                    icon: Icon(
                                      _allWorked(_filteredPlanned)
                                          ? Icons.remove_done
                                          : Icons.done_all,
                                      size: 18,
                                    ),
                                    label: Text(
                                      _allWorked(_filteredPlanned)
                                          ? (!_hasActiveFilters
                                              ? (isPhone
                                                  ? 'Снять отметки'
                                                  : 'Снять отметки у всей смены')
                                              : (isPhone
                                                  ? 'Снять у найденных'
                                                  : 'Снять отметки у найденных'))
                                          : (!_hasActiveFilters
                                              ? (isPhone
                                                  ? 'Отметить всех'
                                                  : 'Отметить всю смену вышедшей')
                                              : (isPhone
                                                  ? 'Отметить найденных'
                                                  : 'Отметить найденных вышедшими')),
                                    ),
                                    style: FilledButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                    ),
                                  ),
                                FilterChip(
                                  avatar: const Icon(Icons.groups_2_outlined,
                                      size: 18),
                                  label: Text(
                                    isPhone
                                        ? 'По группам'
                                        : 'Разделить по группам',
                                  ),
                                  selected: _groupByGroup,
                                  onSelected: (value) =>
                                      setState(() => _groupByGroup = value),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _manageGroupVisibility,
                                  icon:
                                      const Icon(Icons.visibility_off_outlined),
                                  label: Text(
                                    _preferences.hiddenGroupIds.isEmpty
                                        ? (isPhone
                                            ? 'Видимость'
                                            : 'Видимость групп')
                                        : (isPhone
                                            ? 'Скрыто: ${_preferences.hiddenGroupIds.length}'
                                            : 'Скрыто групп: ${_preferences.hiddenGroupIds.length}'),
                                  ),
                                ),
                                Text('Показано: $visibleCount'),
                              ],
                            ),
                            if (_bulkSaving) ...[
                              const SizedBox(height: 12),
                              const LinearProgressIndicator(),
                              const SizedBox(height: 4),
                              const Text('Сохраняем массовую отметку…'),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _planned.isEmpty
                        ? const Center(
                            child: Text(
                                'Никто не запланирован в смену по графику.'),
                          )
                        : visibleCount == 0
                            ? const Center(
                                child: Text(
                                  'По выбранному поиску и статусу сотрудников нет.',
                                ),
                              )
                            : _employeesList(canEditNow),
                  ),
                ],
              ),
      ),
    );
  }
}
