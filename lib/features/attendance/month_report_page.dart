import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
import 'attendance_storage.dart';
import '../../shared/widgets/adaptive_scaffold.dart';

class MonthReportPage extends StatefulWidget {
  final int year;
  final int month;

  const MonthReportPage({
    super.key,
    required this.year,
    required this.month,
  });

  @override
  State<MonthReportPage> createState() => _MonthReportPageState();
}

class _MonthReportPageState extends State<MonthReportPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();

  bool _loading = true;

  List<EmployeeModel> _employees = [];
  Map<String, dynamic> _rawAttendance = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final employees = await _employeesStorage.load();
    final raw = await _attendanceStorage.loadAllRaw();

    if (!mounted) return;
    setState(() {
      _employees = employees;
      _rawAttendance = raw;
      _loading = false;
    });
  }

  int _daysInMonth(int year, int month) {
    final first = DateTime(year, month, 1);
    final next = DateTime(year, month + 1, 1);
    return next.difference(first).inDays;
  }

  String _iso(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic>? _dayMap(String iso) {
    final v = _rawAttendance[iso];
    if (v is Map<String, dynamic>) return v;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final title = 'Табель: ${widget.month.toString().padLeft(2, '0')}.${widget.year}';

    return AdaptiveScaffold(
      title: title,
      selectedIndex: 2,
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
          label: 'Табель',
          icon: Icons.table_chart,
          onTap: () {},
        ),
      ],
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        )
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _employees.isEmpty
                ? const Center(child: Text('Нет сотрудников'))
                : ListView.separated(
                    itemCount: _employees.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final e = _employees[index];

                      int planned = 0;
                      int worked = 0;
                      int absent = 0;
                      int sick = 0;
                      int vacation = 0;
                      int minutes = 0;

                      final days = _daysInMonth(widget.year, widget.month);

                      for (int i = 1; i <= days; i++) {
                        final d = DateTime(widget.year, widget.month, i);
                        final d0 = dateOnly(d);

                        final isPlanned = isWorkDay(
                          day: d0,
                          type: e.scheduleType,
                          startDate: e.scheduleStartDate,
                        );

                        if (!isPlanned) continue;

                        planned++;

                        final iso = _iso(d0);
                        final dayMap = _dayMap(iso);

                        if (dayMap == null) continue;

                        final recJson = dayMap[e.id];
                        if (recJson is! Map<String, dynamic>) continue;

                        final rec = AttendanceRecord.fromJson(recJson);

                        switch (rec.fact) {
                          case FactStatus.worked:
                            worked++;
                            minutes += rec.workedMinutes ?? (e.paidShiftHours * 60);
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

                      final hours = (minutes / 60).toStringAsFixed(1);

                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                e.fullName,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  Text('План: $planned'),
                                  Text('Вышел: $worked'),
                                  Text('Прогул: $absent'),
                                  Text('Бол.: $sick'),
                                  Text('Отп.: $vacation'),
                                  Text('Часы: $hours'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
