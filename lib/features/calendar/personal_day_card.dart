import 'package:flutter/material.dart';

import '../../shared/formatters/work_duration_formatter.dart';
import '../attendance/attendance_history_view.dart';
import '../attendance/attendance_storage.dart';
import '../attendance/hour_requests_storage.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';

/// One presentation of a personal day, in both week and month views.
class PersonalDayCard extends StatefulWidget {
  final EmployeeModel employee;
  final DateTime day;
  final AttendanceRecord? record;
  final VoidCallback onRequest, onRequests;
  const PersonalDayCard(
      {super.key,
      required this.employee,
      required this.day,
      required this.record,
      required this.onRequest,
      required this.onRequests});

  @override
  State<PersonalDayCard> createState() => _PersonalDayCardState();
}

class _PersonalDayCardState extends State<PersonalDayCard>
    with WidgetsBindingObserver {
  List<HourRequest> _requests = [];
  bool _loading = true;
  bool _failed = false;
  bool _showHistory = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PersonalDayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day || oldWidget.record != widget.record) {
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final items = await HourRequestsStorage.forDay(widget.day);
      if (!mounted || generation != _generation) return;
      setState(() {
        _requests = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final planned = isWorkDay(
        day: widget.day,
        type: widget.employee.scheduleType,
        startDate: widget.employee.scheduleStartDate,
        customWorkdays: widget.employee.customWorkdays);
    final minutes = record?.hasWorked == true
        ? record?.workedMinutes ?? widget.employee.paidShiftHours * 60
        : 0;
    final scheme = Theme.of(context).colorScheme;
    final pending = _requests.where((request) => request.pending).firstOrNull;
    final latest = pending ?? _requests.firstOrNull;
    final dayLabel = '${widget.day.day.toString().padLeft(2, '0')}.'
        '${widget.day.month.toString().padLeft(2, '0')}.${widget.day.year}';
    final fact = record?.fact ?? FactStatus.none;
    final status =
        fact == FactStatus.none ? 'Отметка ещё не внесена' : fact.label;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(dayLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text('Учтено: ${formatWorkDuration(minutes)}',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Row(children: [
            Icon(
                record?.closed == true
                    ? Icons.lock_outline
                    : Icons.lock_open_outlined,
                size: 18,
                color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(record?.closed == true
                    ? 'День закрыт'
                    : 'День ещё не закрыт')),
          ]),
          const SizedBox(height: 8),
          Text(planned
              ? 'По плану: ${formatWorkDuration(widget.employee.paidShiftHours * 60)}'
              : 'По плану: выходной'),
          if (fact != FactStatus.none || planned) Text(status),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            title: const Text('Подробности дня'),
            children: [
              Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Приход: ${record?.actualStart ?? 'не указан'}'),
                      Text('Уход: ${record?.actualEnd ?? 'не указан'}'),
                      if (planned && widget.employee.breakHours > 0)
                        Text(
                            'Перерыв по плану: ${formatWorkDuration(widget.employee.breakHours * 60)} (вычтен)'),
                      if (record?.comment?.trim().isNotEmpty == true)
                        Text('Комментарий: ${record!.comment!.trim()}'),
                    ],
                  )),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('История изменений'),
                subtitle: const Text('Кто и что менял в этот день'),
                onExpansionChanged: (expanded) {
                  if (expanded && !_showHistory) {
                    setState(() => _showHistory = true);
                  }
                },
                children: [
                  if (_showHistory)
                    SizedBox(
                      height: 360,
                      child: AttendanceHistoryView(
                        employeeId: widget.employee.id,
                        day: widget.day,
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_failed) ...[
            const Text('Статус запроса не обновлён. Проверьте соединение.'),
            TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить')),
          ] else if (latest != null) ...[
            const SizedBox(height: 8),
            Text(
                'Запрошено +${formatWorkDuration(latest.additionalMinutes)} — ${latest.statusLabel.toLowerCase()}',
                style: Theme.of(context).textTheme.titleSmall),
            if (latest.reviewComment?.trim().isNotEmpty == true)
              Text('Ответ руководителя: ${latest.reviewComment}'),
            TextButton(
                onPressed: widget.onRequests,
                child: const Text('Запрос и ответ')),
          ],
          if (pending == null &&
              !dateOnly(widget.day).isAfter(dateOnly(DateTime.now())))
            FilledButton.icon(
              onPressed: _loading || _failed ? null : widget.onRequest,
              icon: const Icon(Icons.more_time),
              label: const Text('Запросить добавление часов',
                  textAlign: TextAlign.center),
            ),
        ]),
      ),
    );
  }
}
