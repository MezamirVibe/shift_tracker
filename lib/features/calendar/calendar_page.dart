import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
import '../day/attendance_deviation.dart';
import '../preferences/preferences_service.dart';
import '../structure/structure_storage.dart';

class _DaySummary {
  final int planned;
  final int worked;
  final int absent;
  final int sick;
  final int vacation;
  final bool closed;

  const _DaySummary({
    required this.planned,
    required this.worked,
    required this.absent,
    required this.sick,
    required this.vacation,
    required this.closed,
  });

  double get completionRatio {
    if (planned <= 0) {
      return worked > 0 ? 1.0 : 0.0;
    }
    return (worked / planned).clamp(0.0, 1.0);
  }

  int get missing => planned > worked ? planned - worked : 0;

  int get away => absent + sick + vacation;

  bool get hasOverflow => planned > 0 && worked > planned;

  bool get hasUnexpectedOutputWhenNoPlan => planned == 0 && worked > 0;
}

enum _PersonalDayKind {
  workShift,
  worked,
  vacation,
  sick,
  absent,
  dayOff,
}

class CalendarPage extends StatefulWidget {
  final bool fullView;
  final DateTime? initialDate;

  const CalendarPage({
    super.key,
    this.fullView = false,
    this.initialDate,
  });

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();
  final _structureStorage = StructureStorage();
  final _preferences = PreferencesService.instance;

  bool _loading = true;

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);

  List<EmployeeModel> _employeesVisible = [];
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  String? _selectedDepartmentId;
  String? _selectedGroupId;
  String? _selectedPosition;
  bool _mobileFiltersExpanded = false;

  Map<String, _DaySummary> _summaryByDateIso = {};
  Map<String, dynamic> _rawAttendance = {};
  final Map<String, AttendanceRecord?> _recordCache = {};
  DateTime _weekStart = dateOnly(DateTime.now()).subtract(
    Duration(days: DateTime.now().weekday - DateTime.monday),
  );
  DateTime _selectedScheduleDay = dateOnly(DateTime.now());

  late final PageController _pageController;
  late final DateTime _pageBaseMonth;
  Timer? _attendanceRefreshTimer;
  int _loadGeneration = 0;
  final int _basePage = 2400;

  static const _monthNamesRu = [
    'январь',
    'февраль',
    'март',
    'апрель',
    'май',
    'июнь',
    'июль',
    'август',
    'сентябрь',
    'октябрь',
    'ноябрь',
    'декабрь',
  ];

  @override
  void initState() {
    super.initState();
    final initialDay = dateOnly(widget.initialDate ?? DateTime.now());
    _month = DateTime(initialDay.year, initialDay.month, 1);
    _selectedScheduleDay = initialDay;
    _weekStart = initialDay.subtract(
      Duration(days: initialDay.weekday - DateTime.monday),
    );
    _pageBaseMonth = _month;
    _pageController = PageController(initialPage: _basePage);
    AttendanceStorage.changes.addListener(_onAttendanceChanged);
    _loadAndRecalc();
  }

  @override
  void dispose() {
    AttendanceStorage.changes.removeListener(_onAttendanceChanged);
    _attendanceRefreshTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _onAttendanceChanged() {
    _attendanceRefreshTimer?.cancel();
    _attendanceRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        unawaited(_loadAndRecalc(forMonth: _month));
      }
    });
  }

  Future<void> _openDay(DateTime day) async {
    if (_isPersonalView) {
      await _showPersonalDayDetails(dateOnly(day));
      return;
    }
    await context.push('/day/${_isoDate(dateOnly(day))}');
    if (!mounted) return;
    await _loadAndRecalc(forMonth: _month);
  }

  DateTime _monthFromPage(int page) {
    final diff = page - _basePage;
    return DateTime(_pageBaseMonth.year, _pageBaseMonth.month + diff, 1);
  }

  String _isoDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }

  String _titleForMonth(DateTime m) {
    final name = _monthNamesRu[m.month - 1];
    return '$name ${m.year}';
  }

  List<DateTime?> _buildGridDays(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    final daysInMonth = nextMonth.difference(first).inDays;

    final leadingEmpty = first.weekday - DateTime.monday;
    final totalCells = leadingEmpty + daysInMonth;
    final rows = (totalCells / 7).ceil();
    final gridSize = rows * 7;

    final List<DateTime?> cells = List.filled(gridSize, null);
    int idx = leadingEmpty;
    for (int d = 1; d <= daysInMonth; d++) {
      cells[idx++] = DateTime(month.year, month.month, d);
    }
    return cells;
  }

  bool get _canChangeDepartmentFilter {
    final u = AuthService.instance.currentUser;
    if (u == null) return false;
    return u.role == UserRole.superAdmin;
  }

  bool get _canChangeGroupFilter {
    final u = AuthService.instance.currentUser;
    if (u == null) return false;
    if (u.role == UserRole.superAdmin) return true;
    if (u.role == UserRole.manager) return true;
    return false;
  }

  bool get _isPersonalView {
    final auth = AuthService.instance;
    return auth.roleById(auth.currentUser?.roleId)?.scopeKind == ScopeKind.self;
  }

  _PersonalDayKind _personalKindFor(DateTime day) {
    if (_employeesVisible.isEmpty) return _PersonalDayKind.dayOff;
    final employee = _employeesVisible.first;
    final record = _recordFor(day, employee.id);
    switch (record?.fact ?? FactStatus.none) {
      case FactStatus.worked:
        return _PersonalDayKind.worked;
      case FactStatus.vacation:
        return _PersonalDayKind.vacation;
      case FactStatus.sick:
        return _PersonalDayKind.sick;
      case FactStatus.absent:
        return _PersonalDayKind.absent;
      case FactStatus.none:
        return isWorkDay(
          day: day,
          type: employee.scheduleType,
          startDate: employee.scheduleStartDate,
          customWorkdays: employee.customWorkdays,
        )
            ? _PersonalDayKind.workShift
            : _PersonalDayKind.dayOff;
    }
  }

  String _clockFromMinutes(int minutes) {
    final normalized = minutes % (24 * 60);
    final hour = normalized ~/ 60;
    final minute = normalized % 60;
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  int? _clockToMinutes(String? value) {
    final parts = value?.split(':');
    if (parts == null || parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return null;
    }
    return hour * 60 + minute;
  }

  String _personalFactLabel(FactStatus fact, bool planned) {
    return switch (fact) {
      FactStatus.worked => 'Смена отработана',
      FactStatus.vacation => 'Отпуск',
      FactStatus.sick => 'Больничный',
      FactStatus.absent => 'Неявка',
      FactStatus.none => planned ? 'Рабочая смена по плану' : 'Выходной',
    };
  }

  Future<void> _showPersonalDayDetails(DateTime day) async {
    if (_employeesVisible.isEmpty) return;
    final employee = _employeesVisible.first;
    final record = _recordFor(day, employee.id);
    final fact = record?.fact ?? FactStatus.none;
    final planned = isWorkDay(
      day: day,
      type: employee.scheduleType,
      startDate: employee.scheduleStartDate,
      customWorkdays: employee.customWorkdays,
    );
    const plannedStart = 8 * 60;
    final plannedEnd = plannedStart + employee.shiftHours * 60;
    final actualStart = _clockToMinutes(record?.actualStart);
    final actualEnd = _clockToMinutes(record?.actualEnd);
    final workedMinutes = fact == FactStatus.worked
        ? (record?.workedMinutes ?? employee.paidShiftHours * 60)
        : 0;
    AttendanceDeviation? deviation;
    if (fact == FactStatus.worked && actualStart != null && actualEnd != null) {
      deviation = calculateAttendanceDeviation(
        plannedStartMinutes: plannedStart,
        plannedEndMinutes: plannedEnd,
        actualStartMinutes: actualStart,
        actualEndMinutes: actualEnd,
      );
    }
    final deviationParts = <String>[
      if ((deviation?.lateMinutes ?? 0) > 0)
        'Опоздание ${formatWorkDuration(deviation!.lateMinutes)}',
      if ((deviation?.earlyLeaveMinutes ?? 0) > 0)
        'Ранний уход ${formatWorkDuration(deviation!.earlyLeaveMinutes)}',
      if ((deviation?.overtimeMinutes ?? 0) > 0)
        'Переработка ${formatWorkDuration(deviation!.overtimeMinutes)}',
    ];
    final dateLabel = '${day.day.toString().padLeft(2, '0')}.'
        '${day.month.toString().padLeft(2, '0')}.${day.year}';

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;

        Widget detail(String label, String value, {IconData? icon}) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                dateLabel,
                style: Theme.of(sheetContext).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                _personalFactLabel(fact, planned),
                style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                      color: fact == FactStatus.absent
                          ? scheme.error
                          : scheme.primary,
                    ),
              ),
              const SizedBox(height: 14),
              if (planned) ...[
                detail(
                  'План',
                  '${_clockFromMinutes(plannedStart)}–'
                      '${_clockFromMinutes(plannedEnd)}',
                  icon: Icons.event_outlined,
                ),
                detail(
                  'По плану оплачивается',
                  formatWorkDuration(employee.paidShiftHours * 60),
                ),
                if (employee.breakHours > 0)
                  detail(
                    'Перерыв',
                    formatWorkDuration(employee.breakHours * 60),
                  ),
              ],
              if (fact == FactStatus.worked) ...[
                detail(
                  'Фактическое время',
                  record?.actualStart != null && record?.actualEnd != null
                      ? '${record!.actualStart}–${record.actualEnd}'
                      : 'Время не указано',
                  icon: Icons.schedule_outlined,
                ),
                detail(
                  'Оплачено за день',
                  formatWorkDuration(workedMinutes),
                  icon: Icons.payments_outlined,
                ),
                if (deviationParts.isNotEmpty)
                  detail('Отклонения', deviationParts.join(' · ')),
                if (deviation != null && !deviation.hasDeviations)
                  detail('Отклонения', 'Нет'),
              ],
              if (record?.comment?.trim().isNotEmpty == true)
                detail('Комментарий', record!.comment!.trim()),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  context.go('/schedule?date=${_isoDate(day)}');
                },
                icon: const Icon(Icons.view_week_outlined),
                label: const Text('Открыть неделю'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _applyRoleLocksToFilters() {
    final u = AuthService.instance.currentUser;
    if (u == null) return;

    setState(() {
      if (u.role == UserRole.manager) {
        _selectedDepartmentId = u.departmentId;
        if (_selectedGroupId != null) {
          final g = _groups
              .where((x) => x.id == _selectedGroupId)
              .cast<GroupModel?>()
              .firstOrNull;
          if (g == null || g.departmentId != _selectedDepartmentId) {
            _selectedGroupId = null;
          }
        }
      }

      if (u.role == UserRole.master) {
        _selectedGroupId = u.groupId;
        final g = _groups
            .where((x) => x.id == _selectedGroupId)
            .cast<GroupModel?>()
            .firstOrNull;
        _selectedDepartmentId = g?.departmentId;
      }

      if (u.role == UserRole.worker) {
        _selectedDepartmentId = null;
        _selectedGroupId = null;
        _selectedPosition = null;
      }

      if (_selectedPosition != null &&
          !_availablePositions.contains(_selectedPosition)) {
        _selectedPosition = null;
      }
    });
  }

  List<EmployeeModel> _applyFiltersWithinVisible(
    List<EmployeeModel> visibleEmployees,
  ) {
    Iterable<EmployeeModel> out = visibleEmployees;

    final depId = _selectedDepartmentId;
    if (depId != null) out = out.where((e) => e.departmentId == depId);

    final groupId = _selectedGroupId;
    if (groupId != null) out = out.where((e) => e.groupId == groupId);

    final position = _selectedPosition;
    if (position != null) out = out.where((e) => e.position == position);

    return out.toList();
  }

  Future<void> _loadAndRecalc({
    DateTime? forMonth,
    bool force = false,
  }) async {
    final loadGeneration = ++_loadGeneration;
    final targetMonth = forMonth ?? _month;

    if (_employeesVisible.isEmpty) {
      setState(() => _loading = true);
    }

    final rangeFrom = widget.fullView
        ? DateTime(targetMonth.year, targetMonth.month, 1)
        : _weekStart;
    final rangeTo = widget.fullView
        ? DateTime(targetMonth.year, targetMonth.month + 1, 0)
        : _weekStart.add(const Duration(days: 6));
    final results = await Future.wait([
      _preferences.syncForCurrentUser(force: force),
      _employeesStorage.load(force: force),
      _attendanceStorage.loadRange(
        rangeFrom,
        rangeTo,
        force: force,
      ),
      _structureStorage.loadDepartments(force: force),
      _structureStorage.loadGroups(force: force),
    ]);
    final employees = results[1] as List<EmployeeModel>;
    final rawAttendance = results[2] as Map<String, dynamic>;
    final deps = results[3] as List<DepartmentModel>;
    final groups = results[4] as List<GroupModel>;
    if (!mounted || loadGeneration != _loadGeneration) return;
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
      _month = DateTime(targetMonth.year, targetMonth.month, 1);
      _employeesVisible = visible;
      _departments = deps;
      _groups = visibleGroups;
    });

    _applyRoleLocksToFilters();

    final summary = widget.fullView
        ? _calcSummaryForMonth(
            _month,
            _applyFiltersWithinVisible(_employeesVisible),
            rawAttendance,
          )
        : <String, _DaySummary>{};

    if (!mounted) return;

    setState(() {
      _summaryByDateIso = summary;
      _rawAttendance = rawAttendance;
      _recordCache.clear();
      _loading = false;
    });
  }

  Map<String, _DaySummary> _calcSummaryForMonth(
    DateTime month,
    List<EmployeeModel> employeesForCalc,
    Map rawAttendance,
  ) {
    final first = DateTime(month.year, month.month, 1);
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    final daysInMonth = nextMonth.difference(first).inDays;

    final Map<String, _DaySummary> out = {};

    for (int i = 0; i < daysInMonth; i++) {
      final day = DateTime(month.year, month.month, 1 + i);
      final d = dateOnly(day);
      final iso = _isoDate(d);

      final plannedEmployees = employeesForCalc.where((e) {
        return isWorkDay(
          day: d,
          type: e.scheduleType,
          startDate: e.scheduleStartDate,
          customWorkdays: e.customWorkdays,
        );
      }).toList();

      final employeeIds = employeesForCalc.map((e) => e.id).toSet();
      final plannedIds = plannedEmployees.map((e) => e.id).toSet();
      final plannedCount = plannedEmployees.length;

      int worked = 0;
      int absent = 0;
      int sick = 0;
      int vacation = 0;
      bool closed = false;

      final dayMapAny = rawAttendance[iso];
      if (dayMapAny is Map) {
        final meta = dayMapAny['_meta'];
        if (meta is Map) {
          closed = meta['closed'] == true;
        }

        for (final entry in dayMapAny.entries) {
          if (entry.key == '_meta') continue;
          if (!employeeIds.contains(entry.key)) continue;

          final v = entry.value;
          if (v is Map) {
            final rec = AttendanceRecord.fromJson(Map<String, dynamic>.from(v));
            switch (rec.fact) {
              case FactStatus.worked:
                worked++;
                break;
              case FactStatus.absent:
                if (plannedIds.contains(entry.key)) absent++;
                break;
              case FactStatus.sick:
                if (plannedIds.contains(entry.key)) sick++;
                break;
              case FactStatus.vacation:
                if (plannedIds.contains(entry.key)) vacation++;
                break;
              case FactStatus.none:
                break;
            }
          }
        }
      }

      out[iso] = _DaySummary(
        planned: plannedCount,
        worked: worked,
        absent: absent,
        sick: sick,
        vacation: vacation,
        closed: closed,
      );
    }

    return out;
  }

  void _recalculateFromLoaded() {
    if (!widget.fullView) return;
    final filtered = _applyFiltersWithinVisible(_employeesVisible);
    final summary = _calcSummaryForMonth(
      _month,
      filtered,
      _rawAttendance,
    );
    setState(() => _summaryByDateIso = summary);
  }

  List<GroupModel> get _groupsForSelectedDepartment {
    final depId = _selectedDepartmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  List<String> get _availablePositions {
    Iterable<EmployeeModel> employees = _employeesVisible;
    final departmentId = _selectedDepartmentId;
    if (departmentId != null) {
      employees =
          employees.where((employee) => employee.departmentId == departmentId);
    }
    final groupId = _selectedGroupId;
    if (groupId != null) {
      employees = employees.where((employee) => employee.groupId == groupId);
    }
    final result = employees
        .map((employee) => employee.position.trim())
        .where((position) => position.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Widget _monthHeader({bool compact = false}) {
    if (compact) {
      return SizedBox(
        height: 42,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Предыдущий месяц',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _pageController.previousPage(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              ),
            ),
            Expanded(
              child: Text(
                _titleForMonth(_month),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _pageController.nextPage(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              ),
            ),
          ],
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _titleForMonth(_month),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Предыдущий месяц',
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                );
              },
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _filtersBlock(bool isPhone) {
    if (_isPersonalView) {
      return const SizedBox.shrink();
    }

    final depLocked = !_canChangeDepartmentFilter;
    final grpLocked = !_canChangeGroupFilter;
    final groups = _groupsForSelectedDepartment;

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 760;
        final fieldWidth = wide ? 320.0 : constraints.maxWidth;

        return Wrap(
          runSpacing: 12,
          spacing: 12,
          children: [
            SizedBox(
              width: fieldWidth,
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
                    child: Text('Все подразделения'),
                  ),
                  ..._departments.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d.id,
                      child: Text(d.name),
                    ),
                  ),
                ],
                onChanged: depLocked
                    ? null
                    : (v) {
                        setState(() {
                          _selectedDepartmentId = v;
                          _selectedGroupId = null;
                          _selectedPosition = null;
                        });
                        _recalculateFromLoaded();
                      },
              ),
            ),
            SizedBox(
              width: fieldWidth,
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
                    child: Text('Все группы'),
                  ),
                  ...groups.map(
                    (g) => DropdownMenuItem<String?>(
                      value: g.id,
                      child: Text(g.name),
                    ),
                  ),
                ],
                onChanged: grpLocked
                    ? null
                    : (_selectedDepartmentId == null)
                        ? null
                        : (v) {
                            setState(() {
                              _selectedGroupId = v;
                              _selectedPosition = null;
                            });
                            _recalculateFromLoaded();
                          },
              ),
            ),
            SizedBox(
              width: fieldWidth,
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedPosition,
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
                  for (final position in _availablePositions)
                    DropdownMenuItem<String?>(
                      value: position,
                      child: Text(
                        position,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  setState(() => _selectedPosition = value);
                  _recalculateFromLoaded();
                },
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () async {
                if (isPhone && _mobileFiltersExpanded) {
                  setState(() => _mobileFiltersExpanded = false);
                }
                await _loadAndRecalc(
                  forMonth: _month,
                  force: true,
                );
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить'),
            ),
          ],
        );
      },
    );

    if (!isPhone) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: content,
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        initiallyExpanded: _mobileFiltersExpanded,
        maintainState: false,
        onExpansionChanged: (expanded) {
          if (_mobileFiltersExpanded == expanded) return;
          setState(() => _mobileFiltersExpanded = expanded);
        },
        title: const Text('Фильтры'),
        subtitle: Text('Сотрудников в доступе: ${_employeesVisible.length}'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [content],
      ),
    );
  }

  Widget _calendarLegend({bool compact = false}) {
    final itemStyle = Theme.of(context).textTheme.bodySmall;

    Widget line(Color color, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: itemStyle),
        ],
      );
    }

    Widget dot(Color color, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: itemStyle),
        ],
      );
    }

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          if (_isPersonalView) ...[
            dot(Theme.of(context).colorScheme.primary, 'Рабочая смена'),
            dot(context.shiftColors.success, 'Смена отработана'),
            dot(context.shiftColors.vacation, 'Отпуск'),
            dot(context.shiftColors.sick, 'Больничный'),
            dot(Theme.of(context).colorScheme.error, 'Неявка'),
            dot(context.shiftColors.neutral, 'Выходной'),
          ] else ...[
            line(context.shiftColors.success, 'Вышли все по плану'),
            line(Theme.of(context).colorScheme.primary, 'Вышли частично'),
            line(context.shiftColors.warning, 'Вышли сверх плана'),
          ],
          dot(Theme.of(context).colorScheme.primary, 'Сегодня'),
          dot(context.shiftColors.warning, 'День закрыт'),
        ],
      ),
    );

    if (compact) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            useSafeArea: true,
            showDragHandle: true,
            builder: (sheetContext) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Обозначения календаря',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  content,
                ],
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isPersonalView
                        ? 'Цвета: смена, отпуск, больничный и выходной'
                        : 'В ячейке: вышли / план',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: content,
    );
  }

  Widget _scheduleLegend() {
    final colors = context.shiftColors;

    Widget item({
      required IconData icon,
      required Color foreground,
      required Color background,
      required String title,
      required String description,
    }) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: background,
            child: Icon(icon, size: 14, color: foreground),
          ),
          const SizedBox(width: 7),
          Text('$title — $description',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Wrap(
          spacing: 18,
          runSpacing: 9,
          children: [
            item(
              icon: Icons.event_available_outlined,
              foreground: scheme.primary,
              background: scheme.primaryContainer.withValues(alpha: 0.65),
              title: 'Рабочая смена',
              description: 'стоит в плане',
            ),
            item(
              icon: Icons.check_circle_outline,
              foreground: colors.success,
              background: colors.successContainer,
              title: 'Вышел на смену',
              description: 'факт подтверждён',
            ),
            item(
              icon: Icons.beach_access_outlined,
              foreground: colors.vacation,
              background: colors.vacationContainer,
              title: 'Отпуск',
              description: 'утверждённое отсутствие',
            ),
            item(
              icon: Icons.medical_services_outlined,
              foreground: colors.sick,
              background: colors.sickContainer,
              title: 'Больничный',
              description: 'подтверждённое отсутствие',
            ),
            item(
              icon: Icons.person_off_outlined,
              foreground: scheme.error,
              background: scheme.errorContainer,
              title: 'Неявка',
              description: 'сотрудник не вышел',
            ),
            item(
              icon: Icons.weekend_outlined,
              foreground: colors.neutral,
              background: colors.neutralContainer,
              title: 'Выходной',
              description: 'смена не запланирована',
            ),
          ],
        ),
      ),
    );
  }

  Widget _weekHeader() {
    const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    return Row(
      children: names
          .map(
            (n) => Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    n,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  double _cellHeightFor(bool isPhone) => isPhone ? 58 : 104;

  AttendanceRecord? _recordFor(DateTime day, String employeeId) {
    final cacheKey = '${_isoDate(day)}|$employeeId';
    if (_recordCache.containsKey(cacheKey)) return _recordCache[cacheKey];
    final rawDay = _rawAttendance[_isoDate(day)];
    if (rawDay is! Map) {
      _recordCache[cacheKey] = null;
      return null;
    }
    final rawRecord = rawDay[employeeId];
    if (rawRecord is! Map) {
      _recordCache[cacheKey] = null;
      return null;
    }
    final record =
        AttendanceRecord.fromJson(Map<String, dynamic>.from(rawRecord));
    _recordCache[cacheKey] = record;
    return record;
  }

  void _moveWeek(int delta) {
    final weekdayOffset = _selectedScheduleDay.weekday - DateTime.monday;
    setState(() {
      _weekStart = _weekStart.add(Duration(days: delta * 7));
      _selectedScheduleDay =
          _weekStart.add(Duration(days: weekdayOffset.clamp(0, 6)));
    });
    final targetMonth = DateTime(_weekStart.year, _weekStart.month, 1);
    _loadAndRecalc(forMonth: targetMonth);
  }

  Widget _desktopStat({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.13),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Text(value, style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopSchedule() {
    final employees = _applyFiltersWithinVisible(_employeesVisible);
    final days = [
      for (var i = 0; i < 7; i++) _weekStart.add(Duration(days: i))
    ];
    var planned = 0;
    var worked = 0;
    var away = 0;
    var missing = 0;
    for (final employee in employees) {
      final isPlanned = isWorkDay(
        day: _selectedScheduleDay,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      );
      if (isPlanned) planned++;
      final fact = _recordFor(_selectedScheduleDay, employee.id)?.fact ??
          FactStatus.none;
      if (fact == FactStatus.worked) worked++;
      if (isPlanned &&
          (fact == FactStatus.absent ||
              fact == FactStatus.sick ||
              fact == FactStatus.vacation)) {
        away++;
      }
      if (isPlanned &&
          fact == FactStatus.none &&
          !_selectedScheduleDay.isAfter(dateOnly(DateTime.now()))) {
        missing++;
      }
    }
    final end = days.last;
    const dayNames = [
      'понедельник',
      'вторник',
      'среда',
      'четверг',
      'пятница',
      'суббота',
      'воскресенье',
    ];
    final selectedLabel = '${dayNames[_selectedScheduleDay.weekday - 1]}, '
        '${_selectedScheduleDay.day.toString().padLeft(2, '0')}.'
        '${_selectedScheduleDay.month.toString().padLeft(2, '0')}.'
        '${_selectedScheduleDay.year}';
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Предыдущая неделя',
              onPressed: () => _moveWeek(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  '${_weekStart.day.toString().padLeft(2, '0')}.${_weekStart.month.toString().padLeft(2, '0')} – '
                  '${end.day.toString().padLeft(2, '0')}.${end.month.toString().padLeft(2, '0')}.${end.year}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Следующая неделя',
              onPressed: () => _moveWeek(1),
              icon: const Icon(Icons.chevron_right),
            ),
            const Spacer(),
            if (!_isPersonalView) ...[
              OutlinedButton.icon(
                onPressed: () => context.go('/employees'),
                icon: const Icon(Icons.edit_calendar_outlined),
                label: const Text('Настроить графики'),
              ),
              const SizedBox(width: 10),
            ],
            OutlinedButton.icon(
              onPressed: _isPersonalView
                  ? _jumpToToday
                  : () => _openDay(DateTime.now()),
              icon: const Icon(Icons.today_outlined),
              label: const Text('Сегодня'),
            ),
          ],
        ),
        if (!_isPersonalView) ...[
          const SizedBox(height: 12),
          _filtersBlock(false),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Показатели за $selectedLabel',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _desktopStat(
                icon: Icons.badge_outlined,
                label: 'План на смену',
                value: '$planned',
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              _desktopStat(
                icon: Icons.how_to_reg_outlined,
                label: 'Фактически вышли',
                value: '$worked',
                color: Colors.green,
              ),
              const SizedBox(width: 10),
              _desktopStat(
                icon: Icons.beach_access_outlined,
                label: 'Отсутствуют',
                value: '$away',
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(width: 10),
              _desktopStat(
                icon: Icons.warning_amber_rounded,
                label: 'Не заполнено',
                value: '$missing',
                color: Colors.orange,
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 220,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Text(
                              _isPersonalView ? 'Мой график' : 'Сотрудник',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      for (final day in days)
                        Expanded(
                          child: Material(
                            color: dateOnly(day) == _selectedScheduleDay
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              onTap: () => setState(
                                () => _selectedScheduleDay = dateOnly(day),
                              ),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Column(
                                  children: [
                                    Text(
                                      const [
                                        'Пн',
                                        'Вт',
                                        'Ср',
                                        'Чт',
                                        'Пт',
                                        'Сб',
                                        'Вс'
                                      ][day.weekday - 1],
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                    Text(
                                      '${day.day}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: employees.isEmpty
                      ? const Center(
                          child: Text('Нет сотрудников по выбранным фильтрам'))
                      : ListView.separated(
                          itemCount: employees.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final employee = employees[index];
                            return SizedBox(
                              height: 72,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 220,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => context
                                            .push('/employee/${employee.id}'),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14),
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 18,
                                                child: Text(_initials(
                                                    employee.fullName)),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      employee.fullName,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelLarge,
                                                    ),
                                                    Text(
                                                      employee.position,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Icon(
                                                Icons.chevron_right,
                                                size: 18,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  for (final day in days)
                                    Expanded(
                                        child: _scheduleCell(employee, day)),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _scheduleLegend(),
      ],
    );
  }

  void _jumpToToday() {
    final today = dateOnly(DateTime.now());
    final weekStart = today.subtract(
      Duration(days: today.weekday - DateTime.monday),
    );
    setState(() {
      _weekStart = weekStart;
      _selectedScheduleDay = today;
    });
    _loadAndRecalc(forMonth: DateTime(today.year, today.month, 1));
  }

  Widget _mobileStat({
    required IconData icon,
    required String label,
    required int value,
    required Color color,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    '$value',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileScheduleEmployee(EmployeeModel employee) {
    final record = _recordFor(_selectedScheduleDay, employee.id);
    final planned = isWorkDay(
      day: _selectedScheduleDay,
      type: employee.scheduleType,
      startDate: employee.scheduleStartDate,
      customWorkdays: employee.customWorkdays,
    );
    final colors = context.shiftColors;
    String status;
    String details = employee.position;
    Color foreground;
    Color background;
    switch (record?.fact ?? FactStatus.none) {
      case FactStatus.worked:
        status = 'Вышел';
        final workedMinutes =
            record?.workedMinutes ?? employee.paidShiftHours * 60;
        final factTime =
            record?.actualStart != null && record?.actualEnd != null
                ? '${record!.actualStart}–${record.actualEnd} · '
                : '';
        details = '$factTime${formatWorkDuration(workedMinutes)} отработано';
        foreground = colors.success;
        background = colors.successContainer;
        break;
      case FactStatus.vacation:
        status = 'Отпуск';
        details = 'Подтверждённое отсутствие';
        foreground = colors.vacation;
        background = colors.vacationContainer;
        break;
      case FactStatus.sick:
        status = 'Больничный';
        details = 'Подтверждённое отсутствие';
        foreground = colors.sick;
        background = colors.sickContainer;
        break;
      case FactStatus.absent:
        status = 'Неявка';
        details = 'Сотрудник не вышел';
        foreground = Theme.of(context).colorScheme.error;
        background = Theme.of(context).colorScheme.errorContainer;
        break;
      case FactStatus.none:
        status = planned
            ? (_isPersonalView ? 'Рабочая смена' : 'По плану')
            : 'Выходной';
        foreground =
            planned ? Theme.of(context).colorScheme.primary : colors.neutral;
        background = planned
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.65)
            : colors.neutralContainer;
        if (_isPersonalView) {
          details = planned
              ? 'План: 08:00–${_clockFromMinutes(8 * 60 + employee.shiftHours * 60)} · '
                  '${formatWorkDuration(employee.paidShiftHours * 60)} оплачивается'
              : 'Смена не запланирована';
        }
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _isPersonalView
            ? () => _showPersonalDayDetails(_selectedScheduleDay)
            : () => context.push('/employee/${employee.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                child: Text(_initials(employee.fullName)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      employee.fullName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(maxWidth: 92),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileSchedule() {
    final employees = _applyFiltersWithinVisible(_employeesVisible);
    final days = [
      for (var i = 0; i < 7; i++) _weekStart.add(Duration(days: i)),
    ];
    final selectedEmployees = employees.where((employee) {
      final planned = isWorkDay(
        day: _selectedScheduleDay,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      );
      return planned ||
          (_recordFor(_selectedScheduleDay, employee.id)?.fact ??
                  FactStatus.none) !=
              FactStatus.none;
    }).toList();

    var planned = 0;
    var worked = 0;
    var away = 0;
    var missing = 0;
    for (final employee in employees) {
      final isPlanned = isWorkDay(
        day: _selectedScheduleDay,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      );
      final fact = _recordFor(_selectedScheduleDay, employee.id)?.fact ??
          FactStatus.none;
      if (isPlanned) planned++;
      if (fact == FactStatus.worked) worked++;
      if (isPlanned &&
          (fact == FactStatus.absent ||
              fact == FactStatus.sick ||
              fact == FactStatus.vacation)) {
        away++;
      }
      if (isPlanned &&
          fact == FactStatus.none &&
          !_selectedScheduleDay.isAfter(dateOnly(DateTime.now()))) {
        missing++;
      }
    }

    final end = days.last;
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: () => _loadAndRecalc(
        forMonth: _month,
        force: true,
      ),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: selectedEmployees.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) {
            return _mobileScheduleEmployee(selectedEmployees[index - 1]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Предыдущая неделя',
                            onPressed: () => _moveWeek(-1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: Text(
                              '${_weekStart.day.toString().padLeft(2, '0')}.${_weekStart.month.toString().padLeft(2, '0')} – '
                              '${end.day.toString().padLeft(2, '0')}.${end.month.toString().padLeft(2, '0')}',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Следующая неделя',
                            onPressed: () => _moveWeek(1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                          IconButton(
                            tooltip: 'Сегодня',
                            onPressed: _jumpToToday,
                            icon: const Icon(Icons.today_outlined),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          for (final day in days)
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                child: Material(
                                  color: dateOnly(day) == _selectedScheduleDay
                                      ? scheme.primaryContainer
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  child: InkWell(
                                    onTap: () => setState(
                                      () =>
                                          _selectedScheduleDay = dateOnly(day),
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 7),
                                      child: Column(
                                        children: [
                                          Text(
                                            const [
                                              'Пн',
                                              'Вт',
                                              'Ср',
                                              'Чт',
                                              'Пт',
                                              'Сб',
                                              'Вс',
                                            ][day.weekday - 1],
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                          Text(
                                            '${day.day}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (!_isPersonalView) ...[
                const SizedBox(height: 8),
                _filtersBlock(true),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = (constraints.maxWidth - 8) / 2;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        SizedBox(
                          width: width,
                          child: _mobileStat(
                            icon: Icons.badge_outlined,
                            label: 'По плану',
                            value: planned,
                            color: scheme.primary,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _mobileStat(
                            icon: Icons.how_to_reg_outlined,
                            label: 'Вышли',
                            value: worked,
                            color: context.shiftColors.success,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _mobileStat(
                            icon: Icons.beach_access_outlined,
                            label: 'Отсутствуют',
                            value: away,
                            color: scheme.tertiary,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _mobileStat(
                            icon: Icons.warning_amber_rounded,
                            label: 'Не заполнено',
                            value: missing,
                            color: context.shiftColors.warning,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => _openDay(_selectedScheduleDay),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Отметить сотрудников'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.go('/employees'),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Настроить графики сотрудников'),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                _isPersonalView
                    ? 'Моя смена'
                    : 'Сотрудники: ${selectedEmployees.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (selectedEmployees.isEmpty)
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _isPersonalView
                          ? 'На выбранный день у вас нет смены.'
                          : 'На выбранный день сотрудники не запланированы.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }

  Widget _scheduleCell(EmployeeModel employee, DateTime day) {
    final record = _recordFor(day, employee.id);
    final planned = isWorkDay(
      day: day,
      type: employee.scheduleType,
      startDate: employee.scheduleStartDate,
      customWorkdays: employee.customWorkdays,
    );
    final colors = context.shiftColors;
    String code;
    String subtitle = '';
    Color foreground;
    Color background;
    switch (record?.fact ?? FactStatus.none) {
      case FactStatus.worked:
        code = 'Вышел на смену';
        subtitle = formatWorkDuration(
          record?.workedMinutes ?? employee.paidShiftHours * 60,
        );
        foreground = colors.success;
        background = colors.successContainer;
        break;
      case FactStatus.vacation:
        code = 'Отпуск';
        foreground = colors.vacation;
        background = colors.vacationContainer;
        break;
      case FactStatus.sick:
        code = 'Больничный';
        foreground = colors.sick;
        background = colors.sickContainer;
        break;
      case FactStatus.absent:
        code = 'Неявка';
        foreground = Theme.of(context).colorScheme.error;
        background = Theme.of(context).colorScheme.errorContainer;
        break;
      case FactStatus.none:
        code = planned ? 'Рабочая смена' : 'Выходной';
        subtitle = planned ? 'По плану · ${employee.shiftHours} ч' : '';
        foreground =
            planned ? Theme.of(context).colorScheme.primary : colors.neutral;
        background = planned
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.65)
            : colors.neutralContainer;
        break;
    }
    return Padding(
      padding: const EdgeInsets.all(5),
      child: InkWell(
        onTap: () => _openDay(day),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          decoration: BoxDecoration(
              color: background, borderRadius: BorderRadius.circular(9)),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  code,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    style: TextStyle(color: foreground, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(String value) => value
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .map((part) => part[0].toUpperCase())
      .join();

  @override
  Widget build(BuildContext context) {
    final isPhone = MediaQuery.of(context).size.shortestSide < 600;
    final isDesktop = MediaQuery.sizeOf(context).width >= 1100;

    return AdaptiveScaffold(
      title: widget.fullView ? 'Календарь месяца' : 'График на неделю',
      selectedRoute: widget.fullView ? '/calendar' : '/schedule',
      actions: [
        IconButton(
          tooltip: widget.fullView ? 'График смен' : 'Полный календарь',
          icon: Icon(
            widget.fullView
                ? Icons.calendar_view_week_outlined
                : Icons.calendar_month_outlined,
          ),
          onPressed: () => context.go(
            widget.fullView
                ? '/schedule?date=${_isoDate(_selectedScheduleDay)}'
                : '/calendar?date=${_isoDate(_selectedScheduleDay)}',
          ),
        ),
      ],
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 8 : 16),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : !widget.fullView
                ? (isDesktop ? _desktopSchedule() : _mobileSchedule())
                : Column(
                    children: [
                      _monthHeader(compact: isPhone),
                      const SizedBox(height: 8),
                      _filtersBlock(isPhone),
                      const SizedBox(height: 8),
                      _calendarLegend(compact: isPhone),
                      const SizedBox(height: 8),
                      _weekHeader(),
                      const SizedBox(height: 6),
                      Expanded(
                        child: PageView.builder(
                          controller: _pageController,
                          onPageChanged: (page) async {
                            final m = _monthFromPage(page);
                            setState(() => _month = m);
                            await _loadAndRecalc(forMonth: m);
                          },
                          itemBuilder: (context, pageIndex) {
                            final pageMonth = _monthFromPage(pageIndex);
                            final days = _buildGridDays(pageMonth);

                            return LayoutBuilder(
                              builder: (context, c) {
                                const cross = 7;
                                final spacing = isPhone ? 4.0 : 6.0;
                                final cellHeight = _cellHeightFor(isPhone);

                                return SingleChildScrollView(
                                  child: GridView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    padding: const EdgeInsets.only(bottom: 12),
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cross,
                                      crossAxisSpacing: spacing,
                                      mainAxisSpacing: spacing,
                                      mainAxisExtent: cellHeight,
                                    ),
                                    itemCount: days.length,
                                    itemBuilder: (context, index) {
                                      final day = days[index];
                                      if (day == null) {
                                        return const SizedBox.shrink();
                                      }

                                      final d0 = dateOnly(day);
                                      final iso = _isoDate(d0);

                                      final s = _summaryByDateIso[iso] ??
                                          const _DaySummary(
                                            planned: 0,
                                            worked: 0,
                                            absent: 0,
                                            sick: 0,
                                            vacation: 0,
                                            closed: false,
                                          );

                                      return _DayCell(
                                        day: day,
                                        summary: s,
                                        compact: isPhone,
                                        personalKind: _isPersonalView
                                            ? _personalKindFor(day)
                                            : null,
                                        onTap: () => _openDay(day),
                                      );
                                    },
                                  ),
                                );
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

class _DayCell extends StatelessWidget {
  final DateTime day;
  final _DaySummary summary;
  final VoidCallback onTap;
  final bool compact;
  final _PersonalDayKind? personalKind;

  const _DayCell({
    required this.day,
    required this.summary,
    required this.onTap,
    required this.compact,
    this.personalKind,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.shiftColors;
    final isToday = dateOnly(day) == dateOnly(DateTime.now());

    final borderColor =
        isToday ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.7);

    final aggregateFillColor = summary.hasUnexpectedOutputWhenNoPlan
        ? colors.warning
        : summary.completionRatio >= 1
            ? colors.success
            : scheme.primary;
    final personalLabel = switch (personalKind) {
      _PersonalDayKind.workShift => 'Смена',
      _PersonalDayKind.worked => 'Вышел',
      _PersonalDayKind.vacation => 'Отпуск',
      _PersonalDayKind.sick => 'Больн.',
      _PersonalDayKind.absent => 'Неявка',
      _PersonalDayKind.dayOff => 'Выходн.',
      null => null,
    };
    final fillColor = switch (personalKind) {
      _PersonalDayKind.workShift => scheme.primary,
      _PersonalDayKind.worked => colors.success,
      _PersonalDayKind.vacation => colors.vacation,
      _PersonalDayKind.sick => colors.sick,
      _PersonalDayKind.absent => scheme.error,
      _PersonalDayKind.dayOff => colors.neutral,
      null => aggregateFillColor,
    };

    final padding = compact ? 5.0 : 8.0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            width: isToday ? 2 : 1,
            color: borderColor,
          ),
        ),
        child: Stack(
          children: [
            if (summary.hasOverflow || summary.hasUnexpectedOutputWhenNoPlan)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: compact ? 3 : 4,
                  decoration: const BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(13),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: compact ? 4 : 6,
              right: compact ? 4 : 6,
              bottom: compact ? 4 : 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: compact ? 5 : 6,
                  color: scheme.surfaceContainerHighest,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor:
                          personalKind == null ? summary.completionRatio : 1,
                      child: Container(
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(padding),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${day.day}',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const Spacer(),
                            if (summary.closed)
                              Icon(
                                Icons.lock,
                                size: 11,
                                color: colors.warning,
                              ),
                          ],
                        ),
                        const Spacer(),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            personalLabel ??
                                (summary.planned == 0 && summary.worked == 0
                                    ? '—'
                                    : '${summary.worked}/${summary.planned}'),
                            maxLines: 1,
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: fillColor,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        const SizedBox(height: 7),
                      ],
                    )
                  : personalKind != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '${day.day}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                                const Spacer(),
                                if (summary.closed)
                                  Icon(
                                    Icons.lock,
                                    size: 14,
                                    color: colors.warning,
                                  ),
                              ],
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Icon(
                                  Icons.event_available_outlined,
                                  size: 17,
                                  color: fillColor,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    personalLabel!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: fillColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '${day.day}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                                const Spacer(),
                                if (summary.closed)
                                  Icon(
                                    Icons.lock,
                                    size: 14,
                                    color: colors.warning,
                                  ),
                              ],
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Icon(Icons.groups_2_outlined,
                                    size: 17, color: fillColor),
                                const SizedBox(width: 5),
                                Text(
                                  '${summary.worked} / ${summary.planned}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: fillColor,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ],
                            ),
                            Text(
                              summary.away > 0
                                  ? 'вышли / план · отсутствуют ${summary.away}'
                                  : 'вышли / план',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            const SizedBox(height: 7),
                          ],
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
