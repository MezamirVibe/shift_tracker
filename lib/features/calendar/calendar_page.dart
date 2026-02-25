import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
import '../../shared/widgets/adaptive_scaffold.dart';

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
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();

  DateTime _focusedMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool _loading = true;

  List<EmployeeModel> _employees = [];
  Map<String, _DaySummary> _summaryByDateIso = {};

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
    _loadAndRecalc();
  }

  Future<void> _loadAndRecalc() async {
    setState(() => _loading = true);

    final employees = await _employeesStorage.load();
    final rawAttendance = await _attendanceStorage.loadAllRaw();
    final summary = _calcSummaryForMonth(_focusedMonth, employees, rawAttendance);

    if (!mounted) return;
    setState(() {
      _employees = employees;
      _summaryByDateIso = summary;
      _loading = false;
    });
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Ты выйдешь из приложения и попадёшь на экран входа.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Выйти')),
        ],
      ),
    );

    if (ok != true) return;
    await AuthService.instance.logout();
  }

  Map<String, _DaySummary> _calcSummaryForMonth(
    DateTime month,
    List<EmployeeModel> employees,
    Map<String, dynamic> rawAttendance,
  ) {
    final first = DateTime(month.year, month.month, 1);
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    final daysInMonth = nextMonth.difference(first).inDays;

    final Map<String, _DaySummary> out = {};

    for (int i = 0; i < daysInMonth; i++) {
      final day = DateTime(month.year, month.month, 1 + i);
      final d = dateOnly(day);
      final iso = _isoDate(d);

      final plannedEmployees = employees.where((e) {
        return isWorkDay(day: d, type: e.scheduleType, startDate: e.scheduleStartDate);
      }).toList();

      final plannedIds = plannedEmployees.map((e) => e.id).toSet();
      final plannedCount = plannedEmployees.length;

      int worked = 0;
      int absent = 0;
      int sick = 0;
      int vacation = 0;
      bool closed = false;

      final dayMapAny = rawAttendance[iso];
      if (dayMapAny is Map<String, dynamic>) {
        final meta = dayMapAny['_meta'];
        if (meta is Map<String, dynamic>) {
          closed = meta['closed'] == true;
        }

        for (final entry in dayMapAny.entries) {
          if (entry.key == '_meta') continue;
          if (!plannedIds.contains(entry.key)) continue;

          final v = entry.value;
          if (v is Map<String, dynamic>) {
            final rec = AttendanceRecord.fromJson(v);
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

  DateTime _prevMonth(DateTime m) => DateTime(m.year, m.month - 1, 1);
  DateTime _nextMonth(DateTime m) => DateTime(m.year, m.month + 1, 1);

  List<DateTime?> _buildGridDays(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    final daysInMonth = nextMonth.difference(first).inDays;

    final leadingEmpty = first.weekday - DateTime.monday;
    final totalCells = leadingEmpty + daysInMonth;
    final rows = (totalCells / 7).ceil();
    final gridSize = rows * 7;

    final List<DateTime?> cells = List<DateTime?>.filled(gridSize, null);

    int idx = leadingEmpty;
    for (int d = 1; d <= daysInMonth; d++) {
      cells[idx++] = DateTime(month.year, month.month, d);
    }
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final days = _buildGridDays(_focusedMonth);

    final auth = AuthService.instance;
    final user = auth.currentUser;

    final canAdmin = user != null &&
        (user.role == UserRole.superAdmin ||
            auth.hasPerm(AppPermission.manageUsers) ||
            auth.hasPerm(AppPermission.editRolePolicies));

    return AdaptiveScaffold(
      title: _titleForMonth(_focusedMonth),
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
        NavItem(
          label: 'Ещё',
          icon: Icons.more_horiz,
          onTap: () {},
        ),
      ],
      actions: [
        if (user != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(child: Text(user.login, style: Theme.of(context).textTheme.labelMedium)),
          ),
        if (canAdmin)
          IconButton(
            tooltip: 'Администрирование',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => context.push('/admin'),
          ),
        IconButton(
          tooltip: 'Предыдущий месяц',
          icon: const Icon(Icons.chevron_left),
          onPressed: () async {
            setState(() => _focusedMonth = _prevMonth(_focusedMonth));
            await _loadAndRecalc();
          },
        ),
        IconButton(
          tooltip: 'Следующий месяц',
          icon: const Icon(Icons.chevron_right),
          onPressed: () async {
            setState(() => _focusedMonth = _nextMonth(_focusedMonth));
            await _loadAndRecalc();
          },
        ),
        IconButton(
          tooltip: 'Обновить',
          icon: const Icon(Icons.refresh),
          onPressed: _loadAndRecalc,
        ),
        IconButton(
          tooltip: 'Выйти',
          icon: const Icon(Icons.logout),
          onPressed: _logout,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  const SizedBox(height: 8),
                  const _WeekHeader(),
                  const SizedBox(height: 8),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 7,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1.15,
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
                          onTap: () => context.push('/day/$iso'),
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

class _WeekHeader extends StatelessWidget {
  const _WeekHeader();

  @override
  Widget build(BuildContext context) {
    const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    return Row(
      children: names
          .map((n) => Expanded(child: Center(child: Text(n, style: Theme.of(context).textTheme.labelMedium))))
          .toList(),
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime day;
  final _DaySummary summary;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.summary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isToday = dateOnly(day) == dateOnly(DateTime.now());
    final hasFacts = (summary.worked + summary.absent + summary.sick + summary.vacation) > 0;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            width: isToday ? 2 : 1,
            color: isToday ? Theme.of(context).colorScheme.primary : Colors.white24,
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${day.day}', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (summary.closed) const Icon(Icons.lock, size: 16),
              ],
            ),
            const Spacer(),
            Text('План: ${summary.planned}', style: Theme.of(context).textTheme.labelMedium),
            if (hasFacts) ...[
              const SizedBox(height: 2),
              Text('Факт: ✔${summary.worked} ✖${summary.absent}', style: Theme.of(context).textTheme.labelSmall),
              if ((summary.sick + summary.vacation) > 0)
                Text('Б/О: ${summary.sick}/${summary.vacation}', style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}
