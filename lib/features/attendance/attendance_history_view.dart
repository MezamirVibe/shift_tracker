import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import 'hour_request_review_dialog.dart';
import 'hour_requests_storage.dart';

class AttendanceHistoryView extends StatefulWidget {
  final String employeeId;
  final DateTime? day;
  const AttendanceHistoryView({super.key, required this.employeeId, this.day});
  @override
  State<AttendanceHistoryView> createState() => _AttendanceHistoryViewState();
}

class _AttendanceHistoryViewState extends State<AttendanceHistoryView>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _items = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
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
  void didUpdateWidget(covariant AttendanceHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.employeeId != widget.employeeId ||
        oldWidget.day != widget.day) {
      _items = [];
      _lastUpdated = null;
      _nextCursor = null;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
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
      final query = Uri(queryParameters: {
        'employee_id': widget.employeeId,
        'page_size': '30',
        if (widget.day != null)
          'day': widget.day!.toIso8601String().split('T').first,
        if (more) 'cursor': _nextCursor!,
      }).query;
      final data = await ApiClient.instance
          .request('GET', '/api/v1/attendance/history?$query') as Map;
      final items = (data['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = more ? [..._items, ...items] : items;
        _nextCursor = data['next_cursor'] as String?;
        _loading = false;
        _loadingMore = false;
        _lastUpdated = DateTime.now();
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error is ApiException
            ? error.message
            : 'Не удалось загрузить историю. Проверьте соединение.';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  String _timeLabel(DateTime time) {
    final local = time.toLocal();
    return '${requestDateLabel(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _event(Map<String, dynamic> item) {
    final before = Map<String, dynamic>.from(item['before'] as Map? ?? {});
    final after = Map<String, dynamic>.from(item['after'] as Map? ?? {});
    final fields = attendanceChangeLabels.keys
        .where((field) =>
            before.containsKey(field) &&
            after.containsKey(field) &&
            before[field] != after[field])
        .toList();
    final changedHours = fields.contains('minutes');
    final label = switch (item['action']) {
      'close' => 'День закрыт',
      'reopen' => 'День переоткрыт',
      'close_unfilled' => 'Отметка при закрытии дня',
      'import' => 'Импорт табеля',
      'request_approved' => 'Одобрен запрос часов',
      _ => 'Изменение табеля',
    };
    final title = changedHours
        ? '${formatWorkDuration((before['minutes'] as num).toInt())} → ${formatWorkDuration((after['minutes'] as num).toInt())}'
        : label;
    final day = DateTime.tryParse(item['day'] as String? ?? '');
    final created = DateTime.tryParse(item['created_at'] as String? ?? '');
    final reason = item['reason'] as String?;
    final requestId = item['request_id'] as String?;
    return Card(
        child: ExpansionTile(
      leading: Icon(changedHours ? Icons.update : Icons.history),
      title: Text(
          '${day != null ? requestDateLabel(day) : 'Дата не записана'} · $title'),
      subtitle: Text(
          '${item['actor_name'] ?? 'Автор не записан'}${created == null ? '' : '\n${_timeLabel(created)}'}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (changedHours) Text(label),
        for (final field
            in fields.where((field) => !changedHours || field != 'minutes'))
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  '${attendanceChangeLabels[field]}: ${attendanceChangeValue(field, before[field])} → ${attendanceChangeValue(field, after[field])}')),
        if (fields.isEmpty)
          const Text('Подробности значений для этого события не записаны.'),
        if (reason?.trim().isNotEmpty == true)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Причина: $reason')),
        if (requestId != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _RelatedRequestDialog(id: requestId)),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Связанный запрос часов'),
              )),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (_loading || _loadingMore) const LinearProgressIndicator(),
        Expanded(
            child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Text('История учёта часов',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    const Text(
                        'Показаны только записанные изменения. Подробности прошлых изменений, которые не сохранялись, восстановить нельзя.'),
                    Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          if (_lastUpdated != null)
                            Text(
                                '${_error == null ? 'Обновлено' : 'Данные могут быть устаревшими · обновлено'} ${_timeLabel(_lastUpdated!)}',
                                style: Theme.of(context).textTheme.bodySmall),
                          TextButton.icon(
                              onPressed: _loading ? null : _load,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Обновить историю')),
                        ]),
                    if (_error != null)
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    if (!_loading && _error == null && _items.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Записанных изменений пока нет.',
                              textAlign: TextAlign.center)),
                    ..._items.map(_event),
                    if (_nextCursor != null)
                      OutlinedButton(
                          onPressed: _loading || _loadingMore
                              ? null
                              : () => _load(more: true),
                          child: const Text('Загрузить ещё')),
                  ],
                ))),
      ]);
}

class _RelatedRequestDialog extends StatefulWidget {
  final String id;
  const _RelatedRequestDialog({required this.id});
  @override
  State<_RelatedRequestDialog> createState() => _RelatedRequestDialogState();
}

class _RelatedRequestDialogState extends State<_RelatedRequestDialog> {
  late Future<HourRequest> _future = _load();
  Future<HourRequest> _load() async =>
      HourRequest.fromJson(await ApiClient.instance
          .request('GET', '/api/v1/hour-requests/${widget.id}') as Map);
  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Связанный запрос часов'),
        content: SizedBox(
            width: 420,
            child: FutureBuilder<HourRequest>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(snapshot.error is ApiException
                          ? (snapshot.error as ApiException).message
                          : 'Не удалось загрузить запрос.'),
                      TextButton(
                          onPressed: () => setState(() => _future = _load()),
                          child: const Text('Повторить')),
                    ]);
                  }
                  final item = snapshot.data;
                  if (item == null) return const LinearProgressIndicator();
                  return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${item.fullName} · ${item.dayLabel}'),
                        Text(item.daySummary),
                        Text('Причина: ${item.reason}'),
                        if (item.appliedMinutes != null)
                          Text(
                              'Учтено после одобрения: ${formatWorkDuration(item.appliedMinutes!)}'),
                        if (item.reviewComment?.trim().isNotEmpty == true)
                          Text('Ответ руководителя: ${item.reviewComment}'),
                      ]);
                })),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'))
        ],
      );
}
