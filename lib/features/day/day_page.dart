import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';

class DayPage extends StatefulWidget {
  final String dateIso;
  const DayPage({super.key, required this.dateIso});

  @override
  State<DayPage> createState() => _DayPageState();
}

class _DayPageState extends State<DayPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();

  bool _loading = true;
  bool _closed = false;

  late final DateTime _day;
  late final String _dateIso;

  List<EmployeeModel> _planned = <EmployeeModel>[];
  Map<String, AttendanceRecord> _recordsById = <String, AttendanceRecord>{};

  @override
  void initState() {
    super.initState();
    _dateIso = widget.dateIso;
    _day = DateTime.parse(widget.dateIso);
    _load();
  }

  bool get _canEditAttendance =>
      AuthService.instance.hasPerm(AppPermission.editAttendance);

  Future<void> _load() async {
    final allEmployees = await _employeesStorage.load();

    // ✅ scope по роли
    final visibleEmployees =
        AuthService.instance.filterEmployeesByScope(allEmployees);

    final d = dateOnly(_day);
    final planned = visibleEmployees.where((e) {
      return isWorkDay(
        day: d,
        type: e.scheduleType,
        startDate: e.scheduleStartDate,
      );
    }).toList();

    final records = await _attendanceStorage.loadDayRecords(_dateIso);
    final closed = await _attendanceStorage.isDayClosed(_dateIso);

    if (!mounted) return;
    setState(() {
      _planned = planned;
      _recordsById = records;
      _closed = closed;
      _loading = false;
    });
  }

  AttendanceRecord? _recordOf(EmployeeModel e) => _recordsById[e.id];
  FactStatus _factOf(EmployeeModel e) => _recordOf(e)?.fact ?? FactStatus.none;

  String _factLabel(FactStatus s) {
    switch (s) {
      case FactStatus.none:
        return 'Без факта';
      case FactStatus.worked:
        return 'Вышел';
      case FactStatus.absent:
        return 'Прогул';
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

  Future<void> _setFact(
    EmployeeModel e,
    FactStatus fact, {
    String? comment,
    int? workedMinutes,
  }) async {
    await _attendanceStorage.setFact(
      dateIso: _dateIso,
      employeeId: e.id,
      fact: fact,
      comment: comment,
      workedMinutes: workedMinutes,
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _edit(EmployeeModel e) async {
    final canEditNow = _canEditAttendance && !_closed;
    final current = _recordOf(e);

    FactStatus fact = current?.fact ?? FactStatus.none;
    final commentController =
        TextEditingController(text: current?.comment ?? '');
    final workedMinutesController = TextEditingController(
      text: (current?.workedMinutes ?? (e.paidShiftHours * 60)).toString(),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: Text(e.fullName),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<FactStatus>(
                    initialValue: fact,
                    items: const [
                      DropdownMenuItem(
                        value: FactStatus.none,
                        child: Text('Без факта'),
                      ),
                      DropdownMenuItem(
                        value: FactStatus.worked,
                        child: Text('Вышел'),
                      ),
                      DropdownMenuItem(
                        value: FactStatus.absent,
                        child: Text('Прогул'),
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
                  const SizedBox(height: 12),
                  TextField(
                    controller: workedMinutesController,
                    enabled: canEditNow && fact == FactStatus.worked,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Минуты (оплачиваемые)',
                      helperText: fact == FactStatus.worked
                          ? 'По умолчанию: ${e.paidShiftHours} ч = ${e.paidShiftHours * 60} мин'
                          : 'Для этого статуса минуты = 0',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: commentController,
                    enabled: canEditNow,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Комментарий',
                      hintText: 'Например: причина, примечание…',
                    ),
                  ),
                  if (!canEditNow) ...[
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Режим просмотра: нет прав или день закрыт.'),
                    ),
                  ],
                ],
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

    if (saved != true) return;

    final comment = commentController.text.trim();
    final parsedMinutes = int.tryParse(workedMinutesController.text.trim());
    final minutesToSave = (fact == FactStatus.worked)
        ? (parsedMinutes ?? (e.paidShiftHours * 60))
        : 0;

    await _setFact(
      e,
      fact,
      comment: comment.isEmpty ? null : comment,
      workedMinutes: minutesToSave,
    );
  }

  Future<void> _closeDay() async {
    if (!_canEditAttendance) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Закрыть день?'),
        content: const Text(
          'После закрытия дня все, кто остался "Без факта", автоматически станут "Прогул".\n\nПродолжить?',
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

    final canEditNow = _canEditAttendance && !_closed;

    return AdaptiveScaffold(
      title: 'День: $title',
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
        NavItem(label: 'Ещё', icon: Icons.more_horiz, onTap: () {}),
      ],
      actions: [
        IconButton(
          tooltip: 'Обновить',
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
        if (!_loading && !_closed)
          FilledButton.icon(
            onPressed: (canEditNow && _planned.isNotEmpty) ? _closeDay : null,
            icon: const Icon(Icons.lock),
            label: const Text('Закрыть день'),
          ),
        if (!_loading && _closed) ...[
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
        padding: const EdgeInsets.all(12),
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
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          Text('По плану: $plannedCount'),
                          Text('Вышли: $workedCount'),
                          Text('Прогул: $absentCount'),
                          Text('Бол.: $sickCount'),
                          Text('Отп.: $vacationCount'),
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
                        : ListView.separated(
                            itemCount: _planned.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final e = _planned[index];
                              final fact = _factOf(e);

                              final minutes = _minutesFor(e, fact);
                              final hours = (minutes / 60)
                                  .toStringAsFixed(minutes % 60 == 0 ? 0 : 1);

                              final rec = _recordOf(e);
                              final comment = rec?.comment?.trim();
                              final hasComment =
                                  comment != null && comment.isNotEmpty;

                              return ListTile(
                                title: Text(e.fullName),
                                subtitle: Text(
                                  '${e.position} • ${_factLabel(fact)}${hasComment ? ' • $comment' : ''}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('$hours ч'),
                                    const SizedBox(width: 12),
                                    SegmentedButton<FactStatus>(
                                      segments: const [
                                        ButtonSegment(
                                          value: FactStatus.worked,
                                          label: Text('Вышел'),
                                          icon: Icon(Icons.check),
                                        ),
                                        ButtonSegment(
                                          value: FactStatus.absent,
                                          label: Text('Прогул'),
                                          icon: Icon(Icons.close),
                                        ),
                                      ],
                                      selected: {
                                        if (fact == FactStatus.worked)
                                          FactStatus.worked,
                                        if (fact == FactStatus.absent)
                                          FactStatus.absent,
                                      },
                                      emptySelectionAllowed: true,
                                      onSelectionChanged: canEditNow
                                          ? (set) async {
                                              if (set.isEmpty) {
                                                await _setFact(
                                                  e,
                                                  FactStatus.none,
                                                  workedMinutes:
                                                      e.paidShiftHours * 60,
                                                );
                                                return;
                                              }
                                              final v = set.first;
                                              final minutesToSave =
                                                  v == FactStatus.worked
                                                      ? (e.paidShiftHours * 60)
                                                      : 0;
                                              await _setFact(
                                                e,
                                                v,
                                                workedMinutes: minutesToSave,
                                              );
                                            }
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: 'Подробно',
                                      icon: const Icon(Icons.tune),
                                      onPressed: () => _edit(e),
                                    ),
                                  ],
                                ),
                                onTap: () => _edit(e),
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
