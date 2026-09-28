import 'package:flutter/material.dart';
import 'dart:io';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import 'timesheet_service.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

class MonthReportPage extends StatefulWidget {
  final int year;
  final int month;
  final TimesheetService? service;
  const MonthReportPage(
      {super.key, required this.year, required this.month, this.service});
  @override
  State<MonthReportPage> createState() => _MonthReportPageState();
}

class _MonthReportPageState extends State<MonthReportPage> {
  late final TimesheetService _service = widget.service ?? TimesheetService();
  late DateTime _month = DateTime(widget.year, widget.month);
  Map<String, dynamic>? _report;
  String? _department;
  String? _group;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  int _requestId = 0;
  final _horizontalScroll = ScrollController();
  List<Map<String, dynamic>> get _allRows => (_report?['rows'] as List? ?? [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  List<Map<String, dynamic>> get _rows => _allRows
      .where((row) =>
          (_department == null || row['department_id'] == _department) &&
          (_group == null || row['group_id'] == _group))
      .toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _horizontalScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.load(_month.year, _month.month);
      if (!mounted || request != _requestId) return;
      setState(() {
        _report = result;
        if (_allRows
                    .map((r) => r['department_id'])
                    .whereType<String>()
                    .toSet()
                    .length <=
                1 ||
            !_allRows.any((r) => r['department_id'] == _department)) {
          _department = null;
        }
        if (_allRows
                    .where((r) =>
                        _department == null ||
                        r['department_id'] == _department)
                    .map((r) => r['group_id'])
                    .whereType<String>()
                    .toSet()
                    .length <=
                1 ||
            !_allRows.any((r) => r['group_id'] == _group)) {
          _group = null;
        }
      });
    } catch (error) {
      if (!mounted || request != _requestId) return;
      setState(() => _error = error is ApiException && error.statusCode == 404
          ? 'Для табеля требуется обновление сервера до версии с выгрузкой Excel.'
          : 'Не удалось загрузить табель. Проверьте подключение и повторите.\n$error');
    } finally {
      if (mounted && request == _requestId) setState(() => _loading = false);
    }
  }

  void _moveMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta);
    if (next.year < 2000 || next.year > 2100) return;
    setState(() => _month = next);
    _load();
  }

  Future<void> _pickMonth() async {
    final value = await showDatePicker(
        context: context,
        initialDate: _month,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100, 12, 31),
        helpText: 'Выберите любую дату нужного месяца');
    if (value == null || !mounted) return;
    setState(() => _month = DateTime(value.year, value.month));
    await _load();
  }

  int _sum(String key) =>
      _rows.fold(0, (sum, row) => sum + (row[key] as num).toInt());

  Future<void> _export({bool share = false}) async {
    if (_saving || _loading || _rows.isEmpty) return;
    final missing = _sum('missing_days');
    final open = _sum('open_days');
    if (missing > 0 || open > 0) {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                scrollable: true,
                title: const Text('Выгрузить незавершённый табель?'),
                content: Text(
                    'Не заполнено плановых дней: $missing. Не закрыто дней: $open. '
                    'Пустые отметки останутся пустыми; предупреждение будет в примечаниях.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Вернуться')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Выгрузить'))
                ],
              ));
      if (accepted != true || !mounted) return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _saving = true);
    try {
      final export = share ? _service.share : _service.save;
      final message = await export(
          year: _month.year,
          month: _month.month,
          departmentId: _department,
          groupId: _group,
          shareOrigin: origin);
      if (mounted && message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось сохранить табель: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _filters() {
    final departments = <String, String>{
      for (final row in _allRows)
        if (row['department_id'] != null)
          row['department_id'] as String: row['department'] as String
    };
    final groups = <String, String>{
      for (final row in _allRows)
        if (row['group_id'] != null &&
            (_department == null || row['department_id'] == _department))
          row['group_id'] as String: row['group'] as String
    };
    return Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: 'Предыдущий месяц',
                onPressed: _saving ? null : () => _moveMonth(-1),
                icon: const Icon(Icons.chevron_left)),
            Flexible(
                child: TextButton.icon(
                    onPressed: _saving ? null : _pickMonth,
                    icon: const Icon(Icons.calendar_month),
                    label: Text(
                        '${_month.month.toString().padLeft(2, '0')}.${_month.year}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis))),
            IconButton(
                tooltip: 'Следующий месяц',
                onPressed: _saving ? null : () => _moveMonth(1),
                icon: const Icon(Icons.chevron_right)),
          ]),
          if (departments.length > 1)
            SizedBox(
                width: 240,
                child: DropdownButtonFormField<String?>(
                  itemHeight: null,
                  key: ValueKey(
                      'department-$_department-${departments.keys.join()}'),
                  initialValue: _department,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Отдел'),
                  items: [
                    const DropdownMenuItem(
                        value: null,
                        child: Text('Все доступные отделы',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    for (final item in departments.entries)
                      DropdownMenuItem(
                          value: item.key,
                          child: Text(item.value,
                              overflow: TextOverflow.ellipsis, maxLines: 1))
                  ],
                  onChanged: _saving || _loading
                      ? null
                      : (value) => setState(() {
                            _department = value;
                            _group = null;
                          }),
                )),
          if (groups.length > 1)
            SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  itemHeight: null,
                  key: ValueKey('group-$_group-${groups.keys.join()}'),
                  initialValue: _group,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Группа'),
                  items: [
                    const DropdownMenuItem(
                        value: null,
                        child: Text('Все группы',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    for (final item in groups.entries)
                      DropdownMenuItem(
                          value: item.key,
                          child: Text(item.value,
                              overflow: TextOverflow.ellipsis, maxLines: 1))
                  ],
                  onChanged: _saving || _loading
                      ? null
                      : (value) => setState(() => _group = value),
                )),
          FilledButton.icon(
              onPressed: _loading || _saving || _rows.isEmpty || _error != null
                  ? null
                  : () => _export(share: true),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.share_outlined),
              label: Text(_saving ? 'Подготовка…' : 'Поделиться табелем')),
        ]);
  }

  String _value(dynamic entry) {
    if (entry == null || entry['value'] == null) return '—';
    final value = entry['value'];
    return value is num
        ? value
            .toString()
            .replaceFirst(RegExp(r'\.0$'), '')
            .replaceAll('.', ',')
        : '$value';
  }

  ({Color background, Color foreground, String label}) _dayAppearance(
      dynamic entry) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fact = entry?['fact'] as String? ?? 'none';
    if (entry?['missing'] == true) {
      return (background: dark ? const Color(0xFF6B2930) : const Color(0xFFFFDFE0),
          foreground: dark ? Colors.white : const Color(0xFF651C24), label: 'Не заполнено');
    }
    switch (fact) {
      case 'worked':
        return (background: dark ? const Color(0xFF194B39) : const Color(0xFFD9F4E4),
            foreground: dark ? Colors.white : const Color(0xFF12432D), label: 'Работа');
      case 'vacationWorked':
        return (background: dark ? const Color(0xFF35635D) : const Color(0xFFCFF2EA),
            foreground: dark ? Colors.white : const Color(0xFF174B45), label: 'Работа в отпуске');
      case 'businessTrip':
        return (background: dark ? const Color(0xFF25466D) : const Color(0xFFDCEBFF),
            foreground: dark ? Colors.white : const Color(0xFF173A63), label: 'Командировка');
      case 'vacation':
        return (background: dark ? const Color(0xFF655019) : const Color(0xFFFFEFC3),
            foreground: dark ? Colors.white : const Color(0xFF60470B), label: 'Отпуск');
      case 'sick':
        return (background: dark ? const Color(0xFF513A68) : const Color(0xFFEEDFFF),
            foreground: dark ? Colors.white : const Color(0xFF4C2869), label: 'Больничный');
      case 'unpaid':
        return (background: dark ? const Color(0xFF66422E) : const Color(0xFFFFE4D1),
            foreground: dark ? Colors.white : const Color(0xFF683A21), label: 'Без содержания');
      case 'absent':
        return (background: dark ? const Color(0xFF6B2930) : const Color(0xFFFFDFE0),
            foreground: dark ? Colors.white : const Color(0xFF651C24), label: 'Неявка');
      default:
        return (background: Theme.of(context).colorScheme.surfaceContainerHighest,
            foreground: Theme.of(context).colorScheme.onSurface, label: entry?['planned'] == true ? 'По плану' : 'Выходной');
    }
  }

  Widget _legendItem(String fact, String label, {bool missing = false}) {
    final style = _dayAppearance({'fact': fact, 'missing': missing});
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 13, height: 13,
          decoration: BoxDecoration(color: style.background,
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant))),
      const SizedBox(width: 5),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _dayCell(dynamic entry, int day, {double width = 46}) {
    final scheme = Theme.of(context).colorScheme;
    final appearance = _dayAppearance(entry);
    return Tooltip(
        message:
            '${day.toString().padLeft(2, '0')}.${_month.month.toString().padLeft(2, '0')}: ${appearance.label}, ${_value(entry)}${entry?['closed'] == true ? ', день закрыт' : ''}',
        child: InkWell(
            onTap: entry == null
                ? null
                : () async {
                    await context.push('/day/${entry['date']}');
                    if (mounted) await _load();
                  },
            child: Container(
                width: width,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: appearance.background,
                    border:
                        Border.all(color: entry?['closed'] == true ? scheme.outline : scheme.outlineVariant, width: entry?['closed'] == true ? 1.2 : 0.5)),
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(_value(entry),
                            style: TextStyle(fontSize: width < 32 ? 11 : 12,
                                color: appearance.foreground,
                                fontWeight: FontWeight.w600)))))));
  }

  Widget _grid() {
    final rows = _rows;
    final days = (_report?['days_in_month'] as num?)?.toInt() ?? 31;
    return LayoutBuilder(builder: (context, constraints) {
      final employeeWidth = constraints.maxWidth >= 1300 ? 270.0 : 200.0;
      const totalWidth = 80.0;
      // Fit the complete month where marks can remain readable. Narrow windows
      // keep a minimum cell width and expose explicit horizontal navigation.
      final dayWidth = ((constraints.maxWidth - employeeWidth - totalWidth) / days)
          .clamp(22.0, 46.0).toDouble();
      final gridWidth = employeeWidth + days * dayWidth + totalWidth;
      final overflows = gridWidth > constraints.maxWidth + 0.5;
      void scrollTo(bool end) {
        if (!_horizontalScroll.hasClients) return;
        _horizontalScroll.animateTo(
            end ? _horizontalScroll.position.maxScrollExtent : 0,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
      return Column(children: [
        if (overflows)
          Row(children: [
            IconButton(tooltip: 'К началу месяца',
                onPressed: () => scrollTo(false),
                icon: const Icon(Icons.first_page)),
            Expanded(child: Text('Все $days дней — прокрутите вправо',
                style: Theme.of(context).textTheme.bodySmall)),
            TextButton.icon(onPressed: () => scrollTo(true),
                icon: const Icon(Icons.last_page),
                label: const Text('Конец месяца')),
          ]),
        Expanded(child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            controller: _horizontalScroll,
            thumbVisibility: true,
            trackVisibility: true,
            thickness: 10,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              key: const ValueKey('timesheet-horizontal-scroll'),
              controller: _horizontalScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 20),
              child: SizedBox(
                width: gridWidth,
                child: Column(children: [
            Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Row(children: [
                  SizedBox(
                      width: employeeWidth,
                      height: 40,
                      child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text('Сотрудник / отдел'))),
                  for (int d = 1; d <= days; d++)
                    SizedBox(key: ValueKey('timesheet-header-day-$d'),
                        width: dayWidth, child: Center(child: Text('$d',
                            style: TextStyle(fontSize: dayWidth < 32 ? 11 : 14)))),
                  const SizedBox(
                      key: ValueKey('timesheet-total-header'),
                      width: totalWidth, child: Center(child: Text('Часы'))),
                ])),
            Expanded(
                child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final entries = row['days'] as List;
                      return Row(children: [
                        SizedBox(
                            width: employeeWidth,
                            height: 72,
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(child: Text(row['full_name'] as String,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis)),
                                      Text(
                                          '${row['department']} · ${row['group']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall),
                                    ]))),
                        for (int d = 1; d <= days; d++)
                          _dayCell(entries[d - 1], d, width: dayWidth),
                        SizedBox(
                            width: totalWidth,
                            child: Center(
                                child: Text(formatWorkDuration(
                                    (row['total_minutes'] as num).toInt())))),
                      ]);
                    })),
                ]),
              ),
            ),
          ),
        )),
      ]);
    });
  }

  Widget _mobileList() => ListView(children: [
        for (final row in _rows)
          Card(
              child: ExpansionTile(
            title: Text(row['full_name'] as String),
            subtitle: Text(
                '${row['department']} · ${formatWorkDuration((row['total_minutes'] as num).toInt())}'),
            childrenPadding: const EdgeInsets.all(12),
            children: [
              Wrap(spacing: 4, runSpacing: 8, children: [
                for (int d = 1; d <= (row['days'] as List).length; d++)
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('$d', style: Theme.of(context).textTheme.bodySmall),
                    _dayCell(row['days'][d - 1], d)
                  ]),
              ])
            ],
          ))
      ]);

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 700;
    return AdaptiveScaffold(
      title: 'Табель',
      selectedRoute: '/timesheet',
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Действия с табелем',
          enabled: !_saving,
          onSelected: (action) {
            if (action == 'save') _export();
            if (action == 'refresh') _load();
            if (action == 'import') context.push('/timesheet/import');
            if (action == 'delivery') context.push('/timesheet/delivery');
          },
          itemBuilder: (_) => [
            if (!Platform.isAndroid && !Platform.isIOS)
              PopupMenuItem(
                  value: 'save',
                  enabled: !_loading && _rows.isNotEmpty && _error == null,
                  child: const Text('Сохранить Excel')),
            if (AuthService.instance.hasPerm(AppPermission.editEmployees) &&
                AuthService.instance.hasPerm(AppPermission.editAttendance))
              const PopupMenuItem(
                  value: 'import', child: Text('Импортировать старый табель')),
            if (AuthService.instance.hasPerm(AppPermission.viewAttendance))
              const PopupMenuItem(
                  value: 'delivery', child: Text('Отправка по расписанию')),
            PopupMenuItem(
                value: 'refresh',
                enabled: !_loading,
                child: const Text('Обновить табель')),
          ],
        ),
      ],
      child: Padding(
          padding: EdgeInsets.all(phone ? 12 : 20),
          child: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverToBoxAdapter(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    _filters(),
                    const SizedBox(height: 12),
                    const Text('Часы и отметки · Excel без денежных полей'),
                    const SizedBox(height: 8),
                    if (!_loading && _error == null)
                      Wrap(spacing: 12, runSpacing: 4, children: [
                        Chip(label: Text('Строк: ${_rows.length}')),
                        Chip(
                            label: Text(
                                'Всего: ${formatWorkDuration(_sum('total_minutes'))}')),
                        Chip(
                            label:
                                Text('Не заполнено: ${_sum('missing_days')}')),
                      ]),
                    if (!_loading && _error == null && _rows.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(spacing: 14, runSpacing: 6, children: [
                          _legendItem('worked', 'Работа'),
                          _legendItem('businessTrip', 'Командировка'),
                          _legendItem('vacation', 'Отпуск'),
                          _legendItem('vacationWorked', 'Работа в отпуске'),
                          _legendItem('sick', 'Больничный'),
                          _legendItem('unpaid', 'Без содержания'),
                          _legendItem('absent', 'Неявка'),
                          _legendItem('none', 'Выходной'),
                          _legendItem('none', 'Не заполнено', missing: true),
                        ]),
                      ),
                    const SizedBox(height: 8),
                  ])),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: _load, child: const Text('Повторить'))
                      ]))
                    : _rows.isEmpty
                        ? const Center(
                            child: Text(
                                'За этот месяц нет сотрудников в выбранном отделе.'))
                        : phone
                            ? _mobileList()
                            : _grid(),
          )),
    );
  }
}
