import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/id.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../employees/personal_schedule_storage.dart';
import 'attendance_storage.dart';
import 'hour_requests_storage.dart';
import 'hour_request_review_dialog.dart';

String _errorText(Object error) => error is ApiException
    ? error.message
    : 'Не удалось связаться с сервером. Повторите попытку.';
String _updatedLabel(DateTime time) =>
    'Обновлено ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

Future<bool> showHourRequestDialog(
  BuildContext context, {
  required DateTime day,
  int? baseMinutes,
  bool chooseDate = false,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HourRequestDialog(
          day: day, baseMinutes: baseMinutes, chooseDate: chooseDate),
    ) ??
    false;

class _HourRequestDialog extends StatefulWidget {
  final DateTime day;
  final int? baseMinutes;
  final bool chooseDate;
  const _HourRequestDialog(
      {required this.day, this.baseMinutes, required this.chooseDate});
  @override
  State<_HourRequestDialog> createState() => _HourRequestDialogState();
}

class _HourRequestDialogState extends State<_HourRequestDialog> {
  final _hours = TextEditingController();
  final _minutes = TextEditingController(text: '0');
  final _reason = TextEditingController();
  final _id = newUuidV4();
  late DateTime _day = widget.day;
  late int? _baseMinutes = widget.baseMinutes;
  bool _saving = false;
  bool _loading = true;
  bool _fresh = false;
  String? _error;
  HourRequest? _pending;
  int _generation = 0;
  int get _additional =>
      (int.tryParse(_hours.text) ?? 0) * 60 +
      (int.tryParse(_minutes.text) ?? 0);

  @override
  void initState() {
    super.initState();
    _hours.addListener(_updateTotal);
    _minutes.addListener(_updateTotal);
    _loadDay();
  }

  void _updateTotal() => setState(() {});
  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadDay() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _fresh = false;
      _error = null;
      _pending = null;
    });
    try {
      final requestsFuture =
          HourRequestsStorage.load(status: 'pending', day: _day, pageSize: 1);
      final scheduleFuture = PersonalScheduleStorage.load(_day, _day);
      // Both awaited together so a failed request cannot leave an unhandled future.
      final results =
          await Future.wait<Object>([requestsFuture, scheduleFuture]);
      final requests = results[0] as HourRequestPage;
      final schedule = await scheduleFuture;
      final records =
          schedule.attendance[_day.toIso8601String().split('T').first] as Map?;
      final employee = schedule.employees.first;
      final record = records?[employee.id] as Map?;
      final minutes =
          ['worked', 'businessTrip', 'vacationWorked'].contains(record?['fact'])
              ? (record?['workedMinutes'] as num?)?.toInt() ?? 0
              : 0;
      if (!mounted || generation != _generation) return;
      setState(() {
        _baseMinutes = minutes;
        _pending = requests.items.firstOrNull;
        _loading = false;
        _fresh = true;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _errorText(error);
      });
    }
  }

  Future<void> _submit() async {
    if (!_fresh || _pending != null || _saving) return;
    final minutes = int.tryParse(_minutes.text) ?? 0;
    if (minutes > 59 ||
        _additional < 1 ||
        (_baseMinutes ?? 0) + _additional > 1440 ||
        _reason.text.trim().length < 3) {
      setState(() => _error =
          'Укажите добавляемые часы и причину. Минуты — от 0 до 59, итог за день — не больше 24 часов.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiClient.instance.request('POST', '/api/v1/hour-requests', body: {
        'id': _id,
        'day': _day.toIso8601String().split('T').first,
        'additional_minutes': _additional,
        'reason': _reason.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _errorText(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: AlertDialog(
          scrollable: true,
          title: const Text('Запросить добавление часов'),
          content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('За ${requestDateLabel(_day)}',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (widget.chooseDate)
                    TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () async {
                              final date = await showDatePicker(
                                  context: context,
                                  initialDate: _day,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime.now());
                              if (date != null && mounted) {
                                setState(() => _day = date);
                                await _loadDay();
                              }
                            },
                      icon: const Icon(Icons.calendar_month),
                      label: const Text('Изменить дату'),
                    ),
                  const SizedBox(height: 12),
                  if (_loading) ...[
                    const LinearProgressIndicator(),
                    const Text('Проверяем учтённые часы и запросы…'),
                  ] else if (_pending != null) ...[
                    const Icon(Icons.hourglass_top),
                    Text(_pending!.daySummary),
                    const SizedBox(height: 8),
                    const Text(
                        'Новый запрос за этот день можно отправить после решения или отмены текущего.'),
                  ] else if (_fresh) ...[
                    Text(
                        'Сейчас ${formatWorkDuration(_baseMinutes ?? 0)} → добавить ${formatWorkDuration(_additional)} → после одобрения ${formatWorkDuration((_baseMinutes ?? 0) + _additional)}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                        'Часы изменятся только после одобрения руководителем.'),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                          child: TextField(
                        controller: _hours,
                        enabled: !_saving,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(2)
                        ],
                        decoration:
                            const InputDecoration(labelText: 'Добавить часов'),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                          child: TextField(
                        controller: _minutes,
                        enabled: !_saving,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(2)
                        ],
                        decoration: const InputDecoration(labelText: 'Минут'),
                      )),
                    ]),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _reason,
                      enabled: !_saving,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                          labelText: 'Причина',
                          hintText:
                              'Например, задержался на приёмке продукции'),
                    ),
                  ],
                  if (_error != null) ...[
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    if (!_fresh && !_loading)
                      TextButton(
                          onPressed: _loadDay,
                          child: const Text('Повторить проверку')),
                  ],
                ],
              )),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context, false),
                child: Text(_pending != null ? 'Закрыть' : 'Отмена')),
            if (_pending == null)
              FilledButton(
                onPressed: _saving || _loading || !_fresh ? null : _submit,
                child: Text(_saving ? 'Отправка…' : 'Отправить запрос'),
              ),
          ],
        ),
      );
}

class HourRequestsPage extends StatefulWidget {
  const HourRequestsPage({super.key});
  @override
  State<HourRequestsPage> createState() => _HourRequestsPageState();
}

class _HourRequestsPageState extends State<HourRequestsPage>
    with WidgetsBindingObserver {
  bool get _personal => PersonalScheduleStorage.applies;
  bool _loading = true;
  bool _busy = false;
  bool _loadingMore = false;
  String? _error;
  bool _pendingOnly = !PersonalScheduleStorage.applies;
  List<HourRequest> _items = [];
  String? _nextCursor;
  DateTime? _lastUpdated;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _loadingMore || _nextCursor == null)) return;
    final generation = more ? _generation : ++_generation;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final page = await HourRequestsStorage.load(
          status: _pendingOnly ? 'pending' : 'all',
          cursor: more ? _nextCursor : null);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = more ? [..._items, ...page.items] : page.items;
        _nextCursor = page.nextCursor;
        _lastUpdated = DateTime.now();
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = _errorText(error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _review(HourRequest item, bool approve) async {
    setState(() => _busy = true);
    try {
      final preview =
          approve ? await HourRequestsStorage.preview(item.id) : null;
      if (!mounted) return;
      final result = await showDialog<HourReviewDecision>(
          context: context,
          builder: (_) => HourRequestReviewDialog(
              item: item, preview: preview, approve: approve));
      if (result == null || !mounted) return;
      await ApiClient.instance
          .request('POST', '/api/v1/hour-requests/${item.id}/review', body: {
        'decision': approve ? 'approved' : 'rejected',
        'comment': result.comment,
        if (preview != null) 'revision': preview.revision,
        if (result.confirmedMinutes != null)
          'confirmed_minutes': result.confirmedMinutes,
      });
      AttendanceStorage().invalidateCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                approve ? 'Часы добавлены' : 'Ответ отправлен сотруднику')));
        await _load();
      }
    } catch (error) {
      // A stale approval is never retried automatically. Reopening fetches a
      // new preview and requires a fresh explicit confirmation.
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(HourRequest item) async {
    setState(() => _busy = true);
    try {
      await ApiClient.instance
          .request('POST', '/api/v1/hour-requests/${item.id}/cancel', body: {});
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(HourRequest item) {
    final colors = Theme.of(context).colorScheme;
    final color = item.status == 'rejected' ? colors.error : colors.primary;
    final icon = switch (item.status) {
      'approved' => Icons.check_circle_outline,
      'rejected' => Icons.cancel_outlined,
      'cancelled' => Icons.remove_circle_outline,
      _ => Icons.hourglass_top,
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_personal)
                  Text(item.fullName,
                      style: Theme.of(context).textTheme.titleMedium),
                Text(
                    '${item.dayLabel} · +${formatWorkDuration(item.additionalMinutes)}',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('При отправке: ${formatWorkDuration(item.baseMinutes)}'),
                Text(item.reason),
                const SizedBox(height: 10),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(item.statusLabel,
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.w700))),
                ]),
                if (item.appliedMinutes != null)
                  Text(
                      'Учтено после одобрения: ${formatWorkDuration(item.appliedMinutes!)}'),
                if (item.reviewComment?.trim().isNotEmpty == true)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Ответ руководителя: ${item.reviewComment}')),
                if (item.pending)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(spacing: 8, runSpacing: 8, children: [
                        if (_personal)
                          OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _cancel(item),
                              child: const Text('Отменить запрос')),
                        if (!_personal) ...[
                          FilledButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _review(item, true),
                              child: const Text('Рассмотреть')),
                          OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _review(item, false),
                              child: const Text('Отклонить')),
                        ],
                      ])),
              ],
            )));
  }

  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
        title: _personal ? 'Мои запросы' : 'Запросы часов',
        selectedRoute: '/hour-requests',
        leading: IconButton(
            tooltip: 'Назад',
            icon: const Icon(Icons.arrow_back),
            onPressed: _busy
                ? null
                : () {
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go('/schedule');
                    }
                  }),
        child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                      label: const Text('Только ожидающие'),
                      selected: _pendingOnly,
                      onSelected: _busy
                          ? null
                          : (value) {
                              setState(() {
                                _pendingOnly = value;
                                _items = [];
                              });
                              _load();
                            }),
                  IconButton(
                      tooltip: 'Обновить запросы',
                      onPressed: _busy || _loading ? null : _load,
                      icon: const Icon(Icons.refresh)),
                  if (_personal)
                    FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                await showHourRequestDialog(context,
                                    day: DateTime.now(), chooseDate: true);
                                if (mounted) await _load();
                              },
                        icon: const Icon(Icons.add),
                        label: const Text('Новый запрос')),
                ],
              )),
          if (_busy || _loading || _loadingMore)
            const LinearProgressIndicator(),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _busy
                    ? 'Сохранение / проверка актуальных данных…'
                    : _error != null && _lastUpdated != null
                        ? 'Данные могут быть устаревшими · ${_updatedLabel(_lastUpdated!)}'
                        : _lastUpdated != null
                            ? _updatedLabel(_lastUpdated!)
                            : 'Загрузка запросов…',
                style: Theme.of(context).textTheme.bodySmall,
              )),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Text(_error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center),
                  TextButton(
                      onPressed: _busy || _loading ? null : _load,
                      child: const Text('Обновить данные')),
                ])),
          Expanded(
              child: RefreshIndicator(
                  onRefresh: _busy ? () async {} : _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (!_loading && _error == null && _items.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Запросов пока нет',
                                textAlign: TextAlign.center)),
                      ..._items.map(_card),
                      if (_nextCursor != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: OutlinedButton(
                              onPressed: _busy || _loading || _loadingMore
                                  ? null
                                  : () => _load(more: true),
                              child: Text(
                                  _loadingMore ? 'Загрузка…' : 'Загрузить ещё'),
                            )),
                    ],
                  ))),
        ]),
      );
}
