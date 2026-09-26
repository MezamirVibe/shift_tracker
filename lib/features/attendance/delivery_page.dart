import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../structure/structure_storage.dart';

class DeliveryPage extends StatefulWidget {
  const DeliveryPage({super.key});
  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  final _api = ApiClient.instance;
  late final int _epoch = _api.sessionEpoch;
  final _timezone = TextEditingController(text: 'Asia/Yekaterinburg');
  Map<String, dynamic>? _status, _pair;
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];
  String? _department, _group, _error;
  String _cadence = 'monthly', _period = 'previous';
  int _weekday = 1, _monthDay = 1;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  bool _enabled = false, _unfinished = false, _busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timezone.dispose();
    super.dispose();
  }

  Future<void> _load({bool restoreForm = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _api.checkSessionEpoch(_epoch);
      final status = Map<String, dynamic>.from(
          await _api.request('GET', '/api/v1/reports/delivery') as Map);
      final storage = StructureStorage();
      final departments = await storage.loadDepartments();
      final groups = await storage.loadGroups();
      _api.checkSessionEpoch(_epoch);
      if (!mounted) return;
      setState(() {
        _status = status;
        _departments = departments;
        _groups = groups;
        if (restoreForm) {
          final cfg = status['settings'] as Map;
          _enabled = status['enabled'] == true;
          _cadence = cfg['cadence'] as String;
          _period = cfg['period'] as String;
          _weekday = cfg['weekday'] as int;
          _monthDay = cfg['month_day'] as int;
          _time =
              TimeOfDay(hour: cfg['hour'] as int, minute: cfg['minute'] as int);
          _timezone.text = cfg['timezone'] as String;
          _unfinished = cfg['include_unfinished'] == true;
          _department = cfg['department_id'] as String?;
          _group = cfg['group_id'] as String?;
          if (!_departments.any((d) => d.id == _department)) _department = null;
          if (!_groups.any((g) => g.id == _group)) _group = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(String method, String path, {Object? body}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _api.checkSessionEpoch(_epoch);
      final result = await _api.request(method, '/api/v1/reports/delivery$path',
          body: body);
      if (!mounted) return;
      if (path == '/pair') {
        setState(() => _pair = Map<String, dynamic>.from(result as Map));
      }
      if (path == '/confirm' || method == 'DELETE') _pair = null;
      await _load(
          restoreForm:
              method == 'PUT' || method == 'DELETE' || path == '/confirm');
      if (method == 'PUT' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                _enabled ? 'Расписание сохранено' : 'Автоотправка выключена')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final chatId = _status?['candidate_chat_id'];
    final title = _status?['candidate_title'];
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('Подтвердить получателя?'),
              content: Text(
                  '«$title»\nID чата: $chatId\n\nТабель содержит ФИО и часы. Подтверждайте только свой чат или согласованного получателя. При смене чата автоотправка выключится.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Подтвердить'))
              ],
            ));
    if (accepted == true && mounted) {
      await _action('POST', '/confirm', body: {'chat_id': chatId});
    }
  }

  Future<void> _save() async {
    if (_enabled) {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                scrollable: true,
                title: const Text('Включить отправку табеля?'),
                content: Text(
                    'Получатель: ${_status?['chat_title']}. Время: ${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}, ${_timezone.text.trim()}.\n\nФайл Excel с ФИО, часами и отметками будет автоматически передаваться в Telegram по указанному расписанию. Денежные поля не передаются.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Включить'))
                ],
              ));
      if (accepted != true || !mounted) return;
    }
    await _action('PUT', '', body: {
      'enabled': _enabled,
      'cadence': _cadence,
      'weekday': _weekday,
      'month_day': _monthDay,
      'hour': _time.hour,
      'minute': _time.minute,
      'timezone': _timezone.text.trim(),
      'period': _period,
      'department_id': _department,
      'group_id': _group,
      'include_unfinished': _unfinished
    });
  }

  Widget _copyLink(String label, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton.icon(
          icon: const Icon(Icons.copy),
          label: Text(label),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Скопировано. Откройте ссылку в Telegram.')));
            }
          }));

  @override
  Widget build(BuildContext context) {
    final configured = _status?['configured'] == true;
    final connected = _status?['chat_id'] != null;
    return Scaffold(
      appBar: AppBar(
          title: const Text('Отправка табеля'),
          leading: BackButton(onPressed: () => context.go('/timesheet')),
          actions: [
            IconButton(
                tooltip: 'Проверить подключение',
                onPressed: _busy ? null : () => _load(restoreForm: false),
                icon: const Icon(Icons.refresh))
          ]),
      body: SafeArea(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Telegram-бот',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          if (_status != null && !configured)
                            const Text(
                                'Бот ещё не подключён на сервере вашей организации. Администратору нужно настроить токен и имя бота. Токен не вводится и не хранится в приложении.'),
                          if (configured) Text('@${_status!['bot_username']}'),
                          if (connected) ...[
                            const SizedBox(height: 12),
                            Text(
                                'Получатель: ${_status!['chat_title']}\nID чата: ${_status!['chat_id']}'),
                          ],
                          if (configured)
                            OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _action('POST', '/pair'),
                                icon: const Icon(Icons.link),
                                label: Text(connected
                                    ? 'Подключить другой чат'
                                    : 'Подключить чат')),
                          if (_pair != null) ...[
                            const Text(
                                'Ссылка действует 10 минут. Откройте её в Telegram, нажмите «Запустить», затем вернитесь сюда и проверьте подключение. Для группы нужен администратор группы.'),
                            _copyLink('Ссылка для личного чата',
                                '${_pair!['private_link']}'),
                            _copyLink('Ссылка для рабочей группы',
                                '${_pair!['group_link']}'),
                            _copyLink('Команда для уже добавленного бота',
                                '${_pair!['command']}'),
                            TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _load(restoreForm: false),
                                child: const Text('Проверить подключение')),
                          ],
                          if (_status?['candidate_chat_id'] != null)
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(
                                              'Найден чат: ${_status!['candidate_title']}\nID: ${_status!['candidate_chat_id']}'),
                                          const SizedBox(height: 8),
                                          FilledButton(
                                              onPressed:
                                                  _busy ? null : _confirm,
                                              child: const Text(
                                                  'Подтвердить получателя')),
                                        ]))),
                          if (connected) ...[
                            const SizedBox(height: 24),
                            const Text('Расписание',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Отправлять автоматически'),
                                value: _enabled,
                                subtitle: const Text(
                                    'Работает на сервере, даже если приложение закрыто'),
                                onChanged: _busy || !configured || !connected
                                    ? null
                                    : (v) => setState(() => _enabled = v)),
                            DropdownButtonFormField<String>(
                                key: ValueKey('cadence-$_cadence'),
                                initialValue: _cadence,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: 'Как часто'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'monthly',
                                      child: Text('Раз в месяц')),
                                  DropdownMenuItem(
                                      value: 'weekly',
                                      child: Text('Раз в неделю')),
                                  DropdownMenuItem(
                                      value: 'daily',
                                      child: Text('Каждый день'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _cadence = v!)),
                            const SizedBox(height: 12),
                            if (_cadence == 'monthly')
                              DropdownButtonFormField<int>(
                                  initialValue: _monthDay,
                                  key: ValueKey('day-$_monthDay'),
                                  decoration: const InputDecoration(
                                      labelText: 'Число месяца (1–28)'),
                                  items: [
                                    for (int n = 1; n <= 28; n++)
                                      DropdownMenuItem(
                                          value: n, child: Text('$n'))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _monthDay = v!)),
                            if (_cadence == 'weekly')
                              DropdownButtonFormField<int>(
                                  initialValue: _weekday,
                                  key: ValueKey('week-$_weekday'),
                                  decoration: const InputDecoration(
                                      labelText: 'День недели'),
                                  items: [
                                    for (final d in const {
                                      1: 'Понедельник',
                                      2: 'Вторник',
                                      3: 'Среда',
                                      4: 'Четверг',
                                      5: 'Пятница',
                                      6: 'Суббота',
                                      7: 'Воскресенье'
                                    }.entries)
                                      DropdownMenuItem(
                                          value: d.key, child: Text(d.value))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _weekday = v!)),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        final value = await showTimePicker(
                                            context: context,
                                            initialTime: _time);
                                        if (value != null && mounted) {
                                          setState(() => _time = value);
                                        }
                                      },
                                icon: const Icon(Icons.schedule),
                                label: Text(
                                    'Время: ${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}')),
                            const SizedBox(height: 12),
                            TextField(
                                controller: _timezone,
                                enabled: !_busy,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                    labelText: 'Часовой пояс',
                                    helperText:
                                        'Asia/Yekaterinburg или Europe/Moscow')),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                initialValue: _period,
                                key: ValueKey('period-$_period'),
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: 'За какой месяц'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'previous',
                                      child: Text('Предыдущий месяц')),
                                  DropdownMenuItem(
                                      value: 'current',
                                      child: Text('Текущий месяц'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _period = v!)),
                            if (_departments.length > 1) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String?>(
                                  initialValue: _department,
                                  key: ValueKey('department-$_department'),
                                  isExpanded: true,
                                  itemHeight: null,
                                  decoration:
                                      const InputDecoration(labelText: 'Отдел'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: null,
                                        child: Text('Все доступные отделы')),
                                    for (final d in _departments)
                                      DropdownMenuItem(
                                          value: d.id,
                                          child: Text(d.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() {
                                            _department = v;
                                            _group = null;
                                          })),
                            ],
                            if (_groups.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String?>(
                                  initialValue: _group,
                                  key: ValueKey('group-$_department-$_group'),
                                  isExpanded: true,
                                  itemHeight: null,
                                  decoration: const InputDecoration(
                                      labelText: 'Группа'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: null,
                                        child: Text('Все доступные группы')),
                                    for (final g in _groups.where((g) =>
                                        _department == null ||
                                        g.departmentId == _department))
                                      DropdownMenuItem(
                                          value: g.id,
                                          child: Text(g.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _group = v)),
                            ],
                            const SizedBox(height: 12),
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text(
                                    'Разрешить незавершённый табель'),
                                subtitle: const Text(
                                    'По умолчанию незаполненные и незакрытые дни блокируют отправку'),
                                value: _unfinished,
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _unfinished = v!)),
                            if (_status?['next_run_at'] != null)
                              Text(
                                  'Следующая отправка (UTC): ${_status!['next_run_at']}'),
                            if (_status?['last_status'] != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                      'Последний результат: ${_status!['last_status']}')),
                            const SizedBox(height: 8),
                            const Text(
                                'В подключённом чате: /time 09:30 — изменить время, /pause — остановить, /status — проверить. Команды принимает бот только от пользователя, который подключил чат.'),
                          ],
                          if (_error != null)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Text(_error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))),
                          if (_busy)
                            const Padding(
                                padding: EdgeInsets.all(12),
                                child: LinearProgressIndicator()),
                          if (connected)
                            FilledButton(
                                onPressed:
                                    _busy || _status == null ? null : _save,
                                child: const Text('Сохранить расписание')),
                          if (connected)
                            TextButton(
                                onPressed:
                                    _busy ? null : () => _action('DELETE', ''),
                                child: const Text(
                                    'Отключить чат и остановить отправку')),
                        ])),
              ))),
    );
  }
}
