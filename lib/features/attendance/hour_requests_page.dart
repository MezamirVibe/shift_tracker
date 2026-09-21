import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/id.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../employees/personal_schedule_storage.dart';
import 'attendance_storage.dart';

String _dateLabel(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';
String _errorText(Object error) => error is ApiException
    ? error.message
    : 'Не удалось связаться с сервером. Повторите попытку.';

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
        day: day,
        baseMinutes: baseMinutes,
        chooseDate: chooseDate,
      ),
    ) ??
    false;

class _HourRequestDialog extends StatefulWidget {
  final DateTime day;
  final int? baseMinutes;
  final bool chooseDate;
  const _HourRequestDialog({
    required this.day,
    this.baseMinutes,
    required this.chooseDate,
  });
  @override
  State<_HourRequestDialog> createState() => _HourRequestDialogState();
}

class _HourRequestDialogState extends State<_HourRequestDialog> {
  final _hours = TextEditingController();
  final _minutes = TextEditingController(text: '0');
  final _reason = TextEditingController();
  final _id = newUuidV4();
  late DateTime _day = widget.day;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final hours = int.tryParse(_hours.text) ?? 0;
    final minutes = int.tryParse(_minutes.text) ?? 0;
    final total = hours * 60 + minutes;
    if (minutes > 59 ||
        total < 1 ||
        total > 1440 ||
        _reason.text.trim().length < 3) {
      setState(
        () => _error =
            'Укажите часы (минуты от 0 до 59) и причину. Максимум — 24 часа.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiClient.instance.request(
        'POST',
        '/api/v1/hour-requests',
        body: {
          'id': _id,
          'day': _day.toIso8601String().split('T').first,
          'additional_minutes': total,
          'reason': _reason.text.trim(),
        },
      );
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
                Text(
                  'За ${_dateLabel(_day)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (widget.chooseDate)
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: _day,
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now(),
                            );
                            if (date != null && mounted) {
                              setState(() => _day = date);
                            }
                          },
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('Изменить дату'),
                  ),
                const SizedBox(height: 12),
                if (widget.baseMinutes != null)
                  Text(
                      'Сейчас учтено: ${formatWorkDuration(widget.baseMinutes!)}'),
                const Text(
                  'Укажите, сколько добавить сверх уже учтённого. Часы изменятся только после одобрения руководителем.',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _hours,
                        enabled: !_saving,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(2),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Добавить часов',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _minutes,
                        enabled: !_saving,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(2),
                        ],
                        decoration: const InputDecoration(labelText: 'Минут'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _reason,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: 'Причина',
                    hintText: 'Например, задержался на приёмке продукции',
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: _saving ? null : _submit,
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

class _HourRequestsPageState extends State<HourRequestsPage> {
  bool get _personal => PersonalScheduleStorage.applies;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool _pendingOnly = !PersonalScheduleStorage.applies;
  List<Map<String, dynamic>> _items = [];
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.instance.request(
        'GET',
        '/api/v1/hour-requests?status=${_pendingOnly ? 'pending' : 'all'}',
      ) as List;
      if (mounted && generation == _generation) {
        setState(() {
          _items =
              data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _errorText(error);
          _loading = false;
        });
      }
    }
  }

  Future<void> _review(Map<String, dynamic> item, String decision) async {
    final added = formatWorkDuration(item['additional_minutes'] as int);
    final total = formatWorkDuration(
      (item['base_minutes'] as int) + (item['additional_minutes'] as int),
    );
    final comment = await showDialog<String>(
      context: context,
      builder: (_) => _ReviewDialog(
        approve: decision == 'approved',
        description:
            '${item['full_name']} · ${_dateLabel(DateTime.parse(item['day'] as String))}\n'
            'Добавить $added. Итог по запросу: $total.\nЗакрытый день останется закрытым; время прихода и ухода не изменится.',
      ),
    );
    if (comment == null || !mounted) return;
    await _action('/api/v1/hour-requests/${item['id']}/review', {
      'decision': decision,
      'comment': comment,
    });
  }

  Future<void> _action(String path, Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      await ApiClient.instance.request('POST', path, body: body);
      AttendanceStorage().invalidateCache();
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
        title: _personal ? 'Мои запросы' : 'Запросы часов',
        selectedRoute: '/hour-requests',
        leading: IconButton(
          tooltip: 'Назад',
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/schedule');
            }
          },
        ),
        child: Column(
          children: [
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
                            setState(() => _pendingOnly = value);
                            _load();
                          },
                  ),
                  IconButton(
                    tooltip: 'Обновить запросы',
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                  if (_personal)
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              if (await showHourRequestDialog(
                                    context,
                                    day: DateTime.now(),
                                    chooseDate: true,
                                  ) &&
                                  mounted) {
                                await _load();
                              }
                            },
                      icon: const Icon(Icons.add),
                      label: const Text('Новый запрос'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Повторить'),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(12),
                            itemCount: _items.isEmpty ? 1 : _items.length,
                            itemBuilder: (context, index) {
                              if (_items.isEmpty) {
                                return const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Запросов пока нет',
                                    textAlign: TextAlign.center,
                                  ),
                                );
                              }
                              final item = _items[index];
                              final status = item['status'] as String;
                              final label = switch (status) {
                                'approved' => 'Одобрено · часы добавлены',
                                'rejected' => 'Отклонено',
                                'cancelled' => 'Отменено',
                                _ => 'Ожидает решения',
                              };
                              final color = switch (status) {
                                'approved' => Colors.green,
                                'rejected' =>
                                  Theme.of(context).colorScheme.error,
                                'cancelled' => Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                _ => Theme.of(context).colorScheme.primary,
                              };
                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (!_personal)
                                        Text(
                                          item['full_name'] as String,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      Text(
                                        '${_dateLabel(DateTime.parse(item['day'] as String))} · добавить ${formatWorkDuration(item['additional_minutes'] as int)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Было при отправке: ${formatWorkDuration(item['base_minutes'] as int)}',
                                      ),
                                      Text(item['reason'] as String),
                                      const SizedBox(height: 10),
                                      Text(
                                        label,
                                        style: TextStyle(
                                          color: color,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (item['review_comment'] != null)
                                        Text(
                                            'Ответ: ${item['review_comment']}'),
                                      if (status == 'pending')
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 12),
                                          child: Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              if (_personal)
                                                OutlinedButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () => _action(
                                                            '/api/v1/hour-requests/${item['id']}/cancel',
                                                            {},
                                                          ),
                                                  child: const Text(
                                                      'Отменить запрос'),
                                                ),
                                              if (!_personal) ...[
                                                FilledButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () => _review(
                                                          item, 'approved'),
                                                  child: const Text(
                                                    'Одобрить и добавить',
                                                  ),
                                                ),
                                                OutlinedButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () => _review(
                                                          item, 'rejected'),
                                                  child:
                                                      const Text('Отклонить'),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      );
}

class _ReviewDialog extends StatefulWidget {
  final bool approve;
  final String description;
  const _ReviewDialog({required this.approve, required this.description});
  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _comment = TextEditingController();
  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(
          widget.approve ? 'Добавить часы в табель?' : 'Отклонить запрос?',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.description),
              const SizedBox(height: 16),
              TextField(
                controller: _comment,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration:
                    const InputDecoration(labelText: 'Ответ сотруднику'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Назад'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _comment.text.trim()),
            child: Text(widget.approve ? 'Добавить часы' : 'Отклонить'),
          ),
        ],
      );
}
