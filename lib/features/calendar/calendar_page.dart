import 'dart:math' as math;

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
  int _basePage = 2400; // “середина”, чтобы листать в обе стороны

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

  // ---------------- helpers ----------------

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
    return '$name ${m.year} г.';
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

  // ---------------- role/scope ----------------

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
        // группа может быть выбрана внутри отдела
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
      List<EmployeeModel> visibleEmployees) {
    Iterable<EmployeeModel> out = visibleEmployees;

    final depId = _selectedDepartmentId;
    if (depId != null) out = out.where((e) => e.departmentId == depId);

    final groupId = _selectedGroupId;
    if (groupId != null) out = out.where((e) => e.groupId == groupId);

    return out.toList();
  }

  // ---------------- data ----------------

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
            day: d, type: e.scheduleType, startDate: e.scheduleStartDate);
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

  // ---------------- actions ----------------

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
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Выйти')),
        ],
      ),
    );

    if (ok != true) return;
    await AuthService.instance.logout();
  }

  // ---------------- UI ----------------

  List<GroupModel> get _groupsForSelectedDepartment {
    final depId = _selectedDepartmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  Widget _filtersBlock() {
    final u = AuthService.instance.currentUser;

    final hideFilters = (u != null && u.role == UserRole.worker);

    if (hideFilters) {
      return const SizedBox.shrink();
    }

    final depLocked = !_canChangeDepartmentFilter;
    final grpLocked = !_canChangeGroupFilter;

    final groups = _groupsForSelectedDepartment;

    // На мобиле фильтры лучше прятать в раскрывашку, чтобы календарю хватало места.
    final isPhone = MediaQuery.of(context).size.shortestSide < 600;

    final content = Wrap(
      runSpacing: 12,
      spacing: 12,
      children: [
        SizedBox(
          width: 320,
          child: DropdownButtonFormField<String?>(
            initialValue: _selectedDepartmentId,
            decoration: const InputDecoration(
                labelText: 'Подразделение', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Все подразделения')),
              ..._departments.map((d) =>
                  DropdownMenuItem<String?>(value: d.id, child: Text(d.name))),
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
          width: 320,
          child: DropdownButtonFormField<String?>(
            initialValue: _selectedGroupId,
            decoration: const InputDecoration(
                labelText: 'Группа', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Все группы')),
              ...groups.map((g) =>
                  DropdownMenuItem<String?>(value: g.id, child: Text(g.name))),
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
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 8),
          child: Text('Сотрудников в доступе: ${_employeesVisible.length}'),
        ),
      ],
    );

    if (!isPhone) {
      return Card(
          child: Padding(padding: const EdgeInsets.all(12), child: content));
    }

    return Card(
      child: ExpansionTile(
        title: const Text('Фильтры'),
        subtitle: const Text('Подразделение / группа'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [content],
      ),
    );
  }

  Widget _weekHeader() {
    const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    return Row(
      children: names
          .map((n) => Expanded(
                child: Center(
                    child: Text(n,
                        style: Theme.of(context).textTheme.labelMedium)),
              ))
          .toList(),
    );
  }

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
      title: _titleForMonth(_month),
      selectedIndex: 0,
      items: [
        NavItem(
            label: 'Календарь',
            icon: Icons.calendar_month,
            onTap: () => context.go('/')),
        NavItem(
            label: 'Сотрудники',
            icon: Icons.people,
            onTap: () => context.go('/employees')),
        NavItem(label: 'Ещё', icon: Icons.more_horiz, onTap: () {}),
      ],
      actions: [
        if (user != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
                child: Text(user.login,
                    style: Theme.of(context).textTheme.labelMedium)),
          ),
        if (canAdmin)
          IconButton(
            tooltip: 'Администрирование',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => context.push('/admin'),
          ),

        // Кнопки оставим (на мобиле пригодятся), но основное — свайп
        IconButton(
          tooltip: 'Предыдущий месяц',
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            _pageController.previousPage(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut);
          },
        ),
        IconButton(
          tooltip: 'Следующий месяц',
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            _pageController.nextPage(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut);
          },
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
                  _filtersBlock(),
                  const SizedBox(height: 8),
                  _weekHeader(),
                  const SizedBox(height: 8),

                  // ✅ Важное: календарь занимает ОСТАВШЕЕСЯ место и не скроллится
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
                        final rows = (days.length / 7).ceil();

                        return LayoutBuilder(
                          builder: (context, c) {
                            const cross = 7;
                            const spacing = 6.0;

                            final cellW =
                                (c.maxWidth - (cross - 1) * spacing) / cross;
                            final cellH =
                                (c.maxHeight - (rows - 1) * spacing) / rows;
                            final aspect = cellW / math.max(1.0, cellH);

                            return GridView.builder(
                              physics: const NeverScrollableScrollPhysics(),
                              padding: EdgeInsets.zero,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cross,
                                crossAxisSpacing: spacing,
                                mainAxisSpacing: spacing,
                                childAspectRatio: aspect,
                              ),
                              itemCount: days.length,
                              itemBuilder: (context, index) {
                                final day = days[index];
                                if (day == null) return const SizedBox.shrink();

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
                        'Свайпни влево/вправо для смены месяца',
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
    final isToday = dateOnly(day) == dateOnly(DateTime.now());
    final hasFacts = summary.factsTotal > 0;

    final borderColor =
        isToday ? Theme.of(context).colorScheme.primary : Colors.white24;

    // На телефоне показываем меньше строк, чтобы точно не было overflow
    final padding = compact ? 6.0 : 10.0;
    final titleStyle = compact
        ? Theme.of(context).textTheme.labelLarge
        : Theme.of(context).textTheme.titleMedium;
    final small = Theme.of(context).textTheme.labelSmall;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(width: isToday ? 2 : 1, color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Верхняя строка
            Row(
              children: [
                Text('${day.day}', style: titleStyle),
                const Spacer(),
                if (summary.closed) const Icon(Icons.lock, size: 14),
              ],
            ),

            // Заполняем, чтобы низ всегда влез
            const Spacer(),

            // Низ: план/факт (в компактном режиме — максимум 2 строки)
            Text('План: ${summary.planned}',
                style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (hasFacts)
              Text(
                compact
                    ? '✔${summary.worked} ✖${summary.absent}'
                    : 'Факт: ✔${summary.worked} ✖${summary.absent}  Б/О: ${summary.sick}/${summary.vacation}',
                style: small,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
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
