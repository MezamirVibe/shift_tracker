import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../employees/employees_storage.dart';
import '../positions/positions_storage.dart';
import '../structure/structure_storage.dart';
import 'attendance_storage.dart';

class ImportTimesheetPage extends StatefulWidget {
  final Future<XFile?> Function()? pickFile;
  const ImportTimesheetPage({super.key, this.pickFile});
  @override
  State<ImportTimesheetPage> createState() => _ImportTimesheetPageState();
}

class _ImportTimesheetPageState extends State<ImportTimesheetPage> {
  final _api = ApiClient.instance;
  late final int _epoch = _api.sessionEpoch;
  final _shift = TextEditingController(text: '9');
  final _break = TextEditingController(text: '1');
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _file, _data, _sheet, _department, _group, _sourceFilter;
  String _schedule = 'fiveTwo';
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];
  Map<String, dynamic>? _preview;
  final Set<int> _selected = {};
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStructure();
  }

  @override
  void dispose() {
    _shift.dispose();
    _break.dispose();
    super.dispose();
  }

  Future<void> _loadStructure() async {
    try {
      final storage = StructureStorage();
      _departments = await storage.loadDepartments(force: true);
      _api.checkSessionEpoch(_epoch);
      _groups = await storage.loadGroups(force: true);
      _api.checkSessionEpoch(_epoch);
      if (_departments.length == 1) _department = _departments.single.id;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Map<String, dynamic> _payload() => {
        'file_base64': _data,
        'year': _month.year,
        'month': _month.month,
        'sheet': _sheet,
        'department_id': _department,
        'group_id': _group,
        'schedule_type': _schedule,
        'shift_hours': int.tryParse(_shift.text),
        'break_hours': int.tryParse(_break.text),
      };

  Future<void> _pickFile() async {
    try {
      final file = await (widget.pickFile?.call() ??
          openFile(acceptedTypeGroups: [
            const XTypeGroup(label: 'Табель Excel', extensions: [
              'xlsx'
            ], mimeTypes: [
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            ])
          ]));
      if (file == null || !mounted) return;
      if (await file.length() > 3 * 1024 * 1024) {
        throw const FormatException('Файл должен быть не больше 3 МБ.');
      }
      final data = base64Encode(await file.readAsBytes());
      _api.checkSessionEpoch(_epoch);
      if (!mounted) return;
      setState(() {
        _file = file.name;
        _data = data;
        _sheet = null;
        _preview = null;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _check() async {
    if (_busy || _data == null || _department == null) return;
    final shift = int.tryParse(_shift.text), pause = int.tryParse(_break.text);
    if (shift == null ||
        pause == null ||
        shift < 1 ||
        shift > 24 ||
        pause < 0 ||
        pause >= shift) {
      setState(() => _error =
          'Укажите длительность смены от 1 до 24 часов и перерыв короче смены.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      _api.checkSessionEpoch(_epoch);
      final result = Map<String, dynamic>.from(await _api.request(
              'POST', '/api/v1/imports/timesheet/preview', body: _payload())
          as Map);
      if (!mounted) return;
      setState(() {
        _preview = result;
        _selected
            .clear(); // Explicit selection prevents importing every department by accident.
        _sourceFilter = null;
        if (result['sheet'] != null) _sheet = result['sheet'] as String;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    if (_busy || _selected.isEmpty || _preview?['preview_token'] == null) {
      return;
    }
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('Импортировать выбранные строки?'),
              content: Text(
                  'Строк: ${_selected.length}. Отдел: ${_preview!['department']}. Период: ${_month.month.toString().padLeft(2, '0')}.${_month.year}.\n\nСуществующие и закрытые отметки сохранятся. Новые сотрудники появятся в активном списке. Архив не изменится.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Импортировать'))
              ],
            ));
    if (accepted != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _api.checkSessionEpoch(_epoch);
      final result =
          await _api.request('POST', '/api/v1/imports/timesheet/commit', body: {
        ..._payload(),
        'preview_token': _preview!['preview_token'],
        'selected_rows': _selected.toList()..sort(),
      }) as Map;
      EmployeesStorage().invalidateCache();
      PositionsStorage().invalidateCache();
      AttendanceStorage().invalidateCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Добавлено сотрудников: ${result['created_employees']}, отметок: ${result['written_marks']}. Сохранено существующих: ${result['preserved_marks']}.')));
      context.go('/timesheet?year=${_month.year}&month=${_month.month}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed(VoidCallback change) => setState(() {
        change();
        _preview = null;
        _selected.clear();
      });

  @override
  Widget build(BuildContext context) {
    final rows = (_preview?['rows'] as List? ?? []).cast<Map>();
    final visible = rows
        .where((row) =>
            _sourceFilter == null || row['source_department'] == _sourceFilter)
        .toList();
    final sources = rows
        .map((r) => '${r['source_department']}')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Импорт табеля'),
              leading: BackButton(
                  onPressed: _busy ? null : () => context.go('/timesheet'))),
          body: SafeArea(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text('1. Выберите старый табель',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            const Text(
                                'Формат .xlsx: ФИО, должность и дни месяца в одной строке. Зарплаты и другие денежные поля не загружаются.'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                                onPressed: _busy ? null : _pickFile,
                                icon: const Icon(Icons.upload_file),
                                label: Text(_file ?? 'Выбрать Excel',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis)),
                            const SizedBox(height: 20),
                            const Text('2. Укажите период и отдел',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        final date = await showDatePicker(
                                            context: context,
                                            initialDate: _month,
                                            firstDate: DateTime(2000),
                                            lastDate: DateTime(2100, 12, 31),
                                            helpText:
                                                'Выберите любую дату месяца табеля');
                                        if (date != null && mounted) {
                                          _changed(() => _month =
                                              DateTime(date.year, date.month));
                                        }
                                      },
                                icon: const Icon(Icons.calendar_month),
                                label: Text(
                                    '${_month.month.toString().padLeft(2, '0')}.${_month.year}')),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                initialValue: _department,
                                isExpanded: true,
                                itemHeight: null,
                                key: ValueKey(
                                    'department-$_department-${_departments.length}'),
                                decoration: const InputDecoration(
                                    labelText: 'Добавить сотрудников в отдел'),
                                items: [
                                  for (final d in _departments)
                                    DropdownMenuItem(
                                        value: d.id,
                                        child: Text(d.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => _changed(() {
                                          _department = v;
                                          _group = null;
                                        })),
                            if (_departments.isEmpty && !_busy)
                              const Text(
                                  'Сначала создайте отдел в настройках организации.'),
                            if (_groups
                                .any((g) => g.departmentId == _department)) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String?>(
                                  initialValue: _group,
                                  isExpanded: true,
                                  itemHeight: null,
                                  key: ValueKey('group-$_department-$_group'),
                                  decoration: const InputDecoration(
                                      labelText: 'Группа'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: null, child: Text('Без группы')),
                                    for (final g in _groups.where(
                                        (g) => g.departmentId == _department))
                                      DropdownMenuItem(
                                          value: g.id,
                                          child: Text(g.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => _changed(() => _group = v)),
                            ],
                            if ((_preview?['sheets'] as List? ?? []).length >
                                1) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  initialValue: _sheet,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                      labelText: 'Лист книги'),
                                  items: [
                                    for (final sheet
                                        in _preview!['sheets'] as List)
                                      DropdownMenuItem(
                                          value: '$sheet',
                                          child: Text('$sheet'))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() {
                                            _sheet = v;
                                            _preview!['preview_token'] = null;
                                          })),
                            ],
                            const SizedBox(height: 12),
                            ExpansionTile(
                                title: const Text('График новых сотрудников'),
                                subtitle: Text(
                                    '${_schedule == 'fiveTwo' ? '5/2' : '2/2'}, смена ${_shift.text} ч, перерыв ${_break.text} ч'),
                                childrenPadding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                children: [
                                  const Text(
                                      'Табель содержит факт, а не будущий график. Для новых сотрудников начало графика — первое число выбранного месяца. Позже его можно изменить в карточке.'),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                      initialValue: _schedule,
                                      decoration: const InputDecoration(
                                          labelText: 'График'),
                                      items: const [
                                        DropdownMenuItem(
                                            value: 'fiveTwo',
                                            child: Text(
                                                '5/2 — понедельник–пятница')),
                                        DropdownMenuItem(
                                            value: 'twoTwo',
                                            child: Text(
                                                '2/2 — два рабочих, два выходных'))
                                      ],
                                      isExpanded: true,
                                      itemHeight: null,
                                      onChanged: _busy
                                          ? null
                                          : (v) =>
                                              _changed(() => _schedule = v!)),
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: _shift,
                                      enabled: !_busy,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                          labelText: 'Длительность смены, ч'),
                                      onChanged: (_) => _changed(() {})),
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: _break,
                                      enabled: !_busy,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                          labelText: 'Перерыв, ч'),
                                      onChanged: (_) => _changed(() {})),
                                ]),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                                onPressed: _busy ||
                                        _data == null ||
                                        _department == null
                                    ? null
                                    : _check,
                                child: const Text('Проверить файл')),
                            if (_busy)
                              const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: LinearProgressIndicator()),
                            if (_error != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            for (final error
                                in _preview?['errors'] as List? ?? [])
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: Text(
                                      '${error['cell']}: ${error['message']}',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            if (_preview?['detected_period'] != null &&
                                (_preview!['detected_period']['year'] !=
                                        _month.year ||
                                    _preview!['detected_period']['month'] !=
                                        _month.month))
                              TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _changed(() {
                                            final detected =
                                                _preview!['detected_period'];
                                            _month = DateTime(
                                                detected['year'] as int,
                                                detected['month'] as int);
                                          }),
                                  child: Text(
                                      'Выбрать период листа: ${_preview!['detected_period']['month']}.${_preview!['detected_period']['year']}')),
                            if (rows.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              const Text('3. Выберите сотрудников',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 8),
                              const Text(
                                  'Будут добавлены только выбранные строки. Существующие отметки и закрытые дни не перезаписываются. Неоднозначные ФИО нужно исправить в исходном файле.'),
                              if (sources.length > 1) ...[
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String?>(
                                    initialValue: _sourceFilter,
                                    isExpanded: true,
                                    itemHeight: null,
                                    decoration: const InputDecoration(
                                        labelText: 'Отдел в старом файле'),
                                    items: [
                                      const DropdownMenuItem(
                                          value: null,
                                          child: Text(
                                              'Все отделы исходного файла')),
                                      for (final source in sources)
                                        DropdownMenuItem(
                                            value: source,
                                            child: Text(source,
                                                maxLines: 2,
                                                overflow:
                                                    TextOverflow.ellipsis))
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) =>
                                            setState(() => _sourceFilter = v)),
                              ],
                              Wrap(spacing: 8, children: [
                                TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() => _selected.addAll(
                                            visible
                                                .where((r) =>
                                                    r['action'] != 'blocked')
                                                .map((r) => r['row'] as int))),
                                    child: const Text('Выбрать показанных')),
                                TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => setState(_selected.clear),
                                    child: const Text('Снять выбор')),
                              ]),
                              for (final row in visible)
                                CheckboxListTile(
                                    value: _selected.contains(row['row']),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('${row['full_name']}'),
                                    subtitle: Text(row['reason'] as String? ??
                                        '${row['action'] == 'create' ? 'Новый сотрудник' : 'Найден в приложении'} · ${row['position']}\n'
                                            'Новых отметок: ${row['new_marks']}; совпадают: ${row['same_marks']}; сохранятся прежние: ${(row['conflicts'] as int) + (row['locked'] as int)}'
                                            '${row['archived_namesake'] == true ? '\nВ архиве есть такое ФИО. Будет создан отдельный новый сотрудник.' : ''}'),
                                    onChanged: _busy ||
                                            row['action'] == 'blocked'
                                        ? null
                                        : (v) => setState(() {
                                              v == true
                                                  ? _selected
                                                      .add(row['row'] as int)
                                                  : _selected
                                                      .remove(row['row']);
                                            })),
                              const SizedBox(height: 12),
                              FilledButton(
                                  onPressed: _busy ||
                                          _selected.isEmpty ||
                                          _preview?['preview_token'] == null
                                      ? null
                                      : _commit,
                                  child: Text(
                                      'Импортировать (${_selected.length})')),
                            ],
                          ],
                        )),
                  ))),
        ));
  }
}
