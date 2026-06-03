import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
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

  int get factsTotal => worked + absent + sick + vacation;

  double get completionRatio {
    if (planned <= 0) {
      return factsTotal > 0 ? 1.0 : 0.0;
    }
    return (factsTotal / planned).clamp(0.0, 1.0);
  }

  bool get hasOverflow => planned > 0 && factsTotal > planned;

  bool get hasUnexpectedOutputWhenNoPlan => planned == 0 && factsTotal > 0;
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();
  final _structureStorage = StructureStorage();

  bool _loading = true;

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);

  List<EmployeeModel> _employeesVisible = [];
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  String? _selectedDepartmentId;
  String? _selectedGroupId;

  Map<String, _DaySummary> _summaryByDateIso = {};

  late final PageController _pageController;
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
    _pageController = PageController(initialPage: _basePage);
    _loadAndRecalc();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  DateTime _monthFromPage(int page) {
    final diff = page - _basePage;
    return DateTime(_month.year, _month.month + diff, 1);
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

    return out.toList();
  }

  Future<void> _loadAndRecalc({DateTime? forMonth}) async {
    final targetMonth = forMonth ?? _month;

    setState(() => _loading = true);

    final employees = await _employeesStorage.load();
    final rawAttendance = await _attendanceStorage.loadAllRaw();

    final deps = await _structureStorage.loadDepartments();
    final groups = await _structureStorage.loadGroups();
    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    final visible = AuthService.instance.filterEmployeesByScope(employees);

    if (!mounted) return;

    setState(() {
      _month = DateTime(targetMonth.year, targetMonth.month, 1);
      _employeesVisible = visible;
      _departments = deps;
      _groups = groups;
    });

    _applyRoleLocksToFilters();

    final filtered = _applyFiltersWithinVisible(_employeesVisible);
    final summary = _calcSummaryForMonth(_month, filtered, rawAttendance);

    if (!mounted) return;

    setState(() {
      _summaryByDateIso = summary;
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
        );
      }).toList();

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
          if (!plannedIds.contains(entry.key)) continue;

          final v = entry.value;
          if (v is Map) {
            final rec = AttendanceRecord.fromJson(Map<String, dynamic>.from(v));
            switch (rec.fact) {
              case FactStatus.worked:
                worked++;
                break;
              case FactStatus.absent:
                absent++;
                break;
              case FactStatus.sick:
                sick++;
                break;
              case FactStatus.vacation:
                vacation++;
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

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content:
            const Text('Ты выйдешь из приложения и попадёшь на экран входа.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await AuthService.instance.logout();
  }

  List<GroupModel> get _groupsForSelectedDepartment {
    final depId = _selectedDepartmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  Widget _monthHeader() {
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
    final u = AuthService.instance.currentUser;
    final hideFilters = (u != null && u.role == UserRole.worker);

    if (hideFilters) {
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
                    : (v) async {
                        setState(() {
                          _selectedDepartmentId = v;
                          _selectedGroupId = null;
                        });
                        await _loadAndRecalc(forMonth: _month);
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
                        : (v) async {
                            setState(() => _selectedGroupId = v);
                            await _loadAndRecalc(forMonth: _month);
                          },
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _loadAndRecalc(forMonth: _month),
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
        title: const Text('Фильтры'),
        subtitle: Text('Сотрудников в доступе: ${_employeesVisible.length}'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [content],
      ),
    );
  }

  Widget _legend() {
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

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            line(Colors.green, 'Выход по плану'),
            line(Colors.orange, 'Перевыход'),
            dot(Theme.of(context).colorScheme.primary, 'Сегодня'),
            dot(Colors.orange, 'День закрыт'),
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

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final user = auth.currentUser;

    final canAdmin = user != null &&
        (user.role == UserRole.superAdmin ||
            auth.hasPerm(AppPermission.manageUsers) ||
            auth.hasPerm(AppPermission.editRolePolicies));

    final isPhone = MediaQuery.of(context).size.shortestSide < 600;

    return AdaptiveScaffold(
      title: 'Календарь',
      selectedIndex: 0,
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
      ],
      actions: [
        if (canAdmin)
          IconButton(
            tooltip: 'Администрирование',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => context.push('/admin'),
          ),
        IconButton(
          tooltip: 'Выйти',
          icon: const Icon(Icons.logout),
          onPressed: _logout,
        ),
      ],
      child: Padding(
        padding: EdgeInsets.all(isPhone ? 8 : 12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _monthHeader(),
                  const SizedBox(height: 8),
                  _filtersBlock(isPhone),
                  const SizedBox(height: 8),
                  _legend(),
                  const SizedBox(height: 8),
                  _weekHeader(),
                  const SizedBox(height: 6),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      onPageChanged: (page) async {
                        final m = _monthFromPage(page);
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
                                physics: const NeverScrollableScrollPhysics(),
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
                                    onTap: () => context.push('/day/$iso'),
                                  );
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (isPhone)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Свайпни по календарю, чтобы сменить месяц',
                        style: Theme.of(context).textTheme.labelSmall,
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

  const _DayCell({
    required this.day,
    required this.summary,
    required this.onTap,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isToday = dateOnly(day) == dateOnly(DateTime.now());

    final borderColor =
        isToday ? scheme.primary : scheme.outlineVariant.withOpacity(0.7);

    final fillColor = summary.hasUnexpectedOutputWhenNoPlan
        ? Colors.deepOrange
        : summary.completionRatio >= 1
            ? Colors.green
            : scheme.primary;

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
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: const BorderRadius.vertical(
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
                      widthFactor: summary.completionRatio,
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
              child: Row(
                children: [
                  Text(
                    '${day.day}',
                    style: compact
                        ? Theme.of(context).textTheme.labelLarge
                        : Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (summary.closed)
                    Icon(
                      Icons.lock,
                      size: compact ? 12 : 14,
                      color: Colors.orange,
                    ),
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