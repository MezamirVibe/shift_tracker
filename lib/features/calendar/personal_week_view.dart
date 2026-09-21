import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../attendance/attendance_storage.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';

class PersonalWeekView extends StatelessWidget {
  final EmployeeModel employee;
  final Map<String, dynamic> attendance;
  final DateTime weekStart, selectedDay;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<int> onMoveWeek;
  final VoidCallback onToday, onDetails, onRequest, onRequests;
  final Future<void> Function() onRefresh;
  const PersonalWeekView({
    super.key,
    required this.employee,
    required this.attendance,
    required this.weekStart,
    required this.selectedDay,
    required this.onSelect,
    required this.onMoveWeek,
    required this.onToday,
    required this.onDetails,
    required this.onRequest,
    required this.onRequests,
    required this.onRefresh,
  });

  AttendanceRecord? _record(DateTime day) {
    final raw = attendance[day.toIso8601String().split('T').first];
    final value = raw is Map ? raw[employee.id] : null;
    return value is Map
        ? AttendanceRecord.fromJson(Map<String, dynamic>.from(value))
        : null;
  }

  bool _planned(DateTime day) => isWorkDay(
        day: day,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      );
  int _minutes(AttendanceRecord? record) => record?.hasWorked == true
      ? record?.workedMinutes ?? employee.paidShiftHours * 60
      : 0;
  String _date(DateTime day) =>
      '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}';

  ({Color color, Color background, IconData icon, String short, String label})
      _style(BuildContext context, DateTime day) {
    final record = _record(day);
    final colors = context.shiftColors;
    final scheme = Theme.of(context).colorScheme;
    if (record?.hasWorked == true) {
      return (
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF6EE7B7)
            : colors.success,
        background: colors.successContainer,
        icon: record!.closed ? Icons.lock_outline : Icons.check_circle_outline,
        short: formatWorkDuration(_minutes(record)),
        label: record.closed ? 'Часы закрыты' : 'Часы учтены, день открыт',
      );
    }
    if (record != null && record.fact != FactStatus.none) {
      final color = switch (record.fact) {
        FactStatus.sick => colors.sick,
        FactStatus.absent => scheme.error,
        _ => colors.vacation,
      };
      return (
        color: color,
        background: color.withValues(alpha: 0.14),
        icon: Icons.event_busy_outlined,
        short: switch (record.fact) {
          FactStatus.vacation => 'Отп.',
          FactStatus.sick => 'Бол.',
          FactStatus.unpaid => 'Б/с',
          FactStatus.businessTrip => 'Ком.',
          _ => 'Неяв.',
        },
        label: record.fact.label,
      );
    }
    if (_planned(day)) {
      return (
        color: scheme.primary,
        background: scheme.primaryContainer,
        icon: Icons.work_outline,
        short: 'Смена',
        label: 'Рабочая смена по плану',
      );
    }
    return (
      color: colors.neutral,
      background: colors.neutralContainer,
      icon: Icons.weekend_outlined,
      short: 'Вых.',
      label: 'Выходной по графику',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    final record = _record(selectedDay);
    final planned = _planned(selectedDay);
    final style = _style(context, selectedDay);
    final closedMinutes = days.fold<int>(
      0,
      (sum, day) =>
          sum + (_record(day)?.closed == true ? _minutes(_record(day)) : 0),
    );
    Widget legend(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 9, color: color),
            const SizedBox(width: 5),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                        onPressed: () => onMoveWeek(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${_date(weekStart)} – ${_date(days.last)} · ${days.last.year}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Следующая неделя',
                        onPressed: () => onMoveWeek(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                      IconButton(
                        tooltip: 'Сегодня',
                        onPressed: onToday,
                        icon: const Icon(Icons.today_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final day in days)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Builder(
                              builder: (context) {
                                final state = _style(context, day);
                                final selected =
                                    dateOnly(day) == dateOnly(selectedDay);
                                return Semantics(
                                  selected: selected,
                                  label:
                                      '${_date(day)}: ${state.label}, ${state.short}',
                                  child: Tooltip(
                                    message: state.label,
                                    child: Material(
                                      color: state.background,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        side: BorderSide(
                                          color: selected
                                              ? scheme.onSurface
                                              : state.color.withValues(
                                                  alpha: 0.3,
                                                ),
                                          width: selected ? 2 : 1,
                                        ),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: () => onSelect(day),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 8,
                                            horizontal: 2,
                                          ),
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
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.labelSmall,
                                              ),
                                              Text(
                                                '${day.day}',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                              ),
                                              const SizedBox(height: 6),
                                              Icon(
                                                state.icon,
                                                color: state.color,
                                                size: 18,
                                              ),
                                              const SizedBox(height: 4),
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  state.short,
                                                  style: TextStyle(
                                                    color: state.color,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      legend(scheme.primary, 'Смена по плану'),
                      legend(context.shiftColors.success, 'Учтённые часы'),
                      legend(context.shiftColors.neutral, 'Выходной'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Рамка — выбранный день. Замок — часы закрыты.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Закрыто за эту неделю: ${formatWorkDuration(closedMinutes)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            color: style.background,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${_date(selectedDay)}.${selectedDay.year}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    style.label,
                    style: Theme.of(
                      context,
                    ).textTheme.titleLarge?.copyWith(color: style.color),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    record?.closed == true
                        ? 'Закрыто: ${formatWorkDuration(_minutes(record))}'
                        : record?.fact != null &&
                                record?.fact != FactStatus.none
                            ? 'Учтено: ${formatWorkDuration(_minutes(record))}'
                            : 'Часы ещё не закрыты',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (record != null && !record.closed)
                    const Text('День пока не закрыт руководителем'),
                  const SizedBox(height: 8),
                  Text(
                    planned
                        ? 'По плану: ${formatWorkDuration(employee.paidShiftHours * 60)} (перерыв вычтен)'
                        : 'Смена на этот день не запланирована',
                  ),
                  if (record?.actualStart != null)
                    Text(
                      'Фактическое время: ${record!.actualStart}–${record.actualEnd}',
                    ),
                  if (record?.comment?.isNotEmpty == true)
                    Text('Комментарий: ${record!.comment}'),
                  const SizedBox(height: 16),
                  if (!dateOnly(selectedDay).isAfter(dateOnly(DateTime.now())))
                    FilledButton.icon(
                      onPressed: onRequest,
                      icon: const Icon(Icons.more_time),
                      label: const Text('Запросить добавление часов'),
                    ),
                  TextButton(
                    onPressed: onDetails,
                    child: const Text('Подробности дня'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRequests,
            icon: const Icon(Icons.outgoing_mail),
            label: const Text('Мои запросы и ответы'),
          ),
        ],
      ),
    );
  }
}
