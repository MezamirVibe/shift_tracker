import 'package:flutter/material.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import 'hour_requests_storage.dart';

class HourReviewDecision {
  final String comment;
  final int? confirmedMinutes;
  const HourReviewDecision(this.comment, this.confirmedMinutes);
}

String attendanceChangeValue(String field, dynamic value) {
  if (field == 'minutes') {
    return formatWorkDuration((value as num?)?.toInt() ?? 0);
  }
  if (field == 'closed') {
    return value == true ? 'День закрыт' : 'День не закрыт';
  }
  if (field == 'exists') return value == true ? 'Есть запись' : 'Нет записи';
  if (field == 'fact') {
    return switch (value) {
      'worked' => 'Работал',
      'absent' => 'Неявка',
      'sick' => 'Больничный',
      'vacation' => 'Отпуск',
      'vacationWorked' => 'Работа в отпуске',
      'businessTrip' => 'Командировка',
      'unpaid' => 'Без содержания',
      _ => 'Не заполнено',
    };
  }
  return value?.toString().trim().isNotEmpty == true ? value.toString() : '—';
}

const attendanceChangeLabels = {
  'minutes': 'Учтено',
  'fact': 'Статус',
  'start': 'Приход',
  'end': 'Уход',
  'comment': 'Комментарий',
  'closed': 'Закрытие дня',
  'exists': 'Запись',
};

class HourRequestReviewDialog extends StatefulWidget {
  final HourRequest item;
  final HourRequestPreview? preview;
  final bool approve;
  const HourRequestReviewDialog(
      {super.key,
      required this.item,
      required this.preview,
      required this.approve});
  @override
  State<HourRequestReviewDialog> createState() =>
      _HourRequestReviewDialogState();
}

class _HourRequestReviewDialogState extends State<HourRequestReviewDialog> {
  final _comment = TextEditingController();
  bool _confirmed = false;
  String? _error;
  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.approve && _comment.text.trim().length < 3) {
      setState(() => _error = 'Объясните сотруднику причину отклонения.');
      return;
    }
    if (widget.preview?.hoursChanged == true && !_confirmed) {
      setState(
          () => _error = 'Подтвердите новый итог с учётом изменившихся часов.');
      return;
    }
    Navigator.pop(
        context,
        HourReviewDecision(
            _comment.text.trim(),
            widget.preview?.hoursChanged == true
                ? widget.preview!.proposedMinutes
                : null));
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return AlertDialog(
      scrollable: true,
      title: Text(
          widget.approve ? 'Добавить часы в табель?' : 'Отклонить запрос?'),
      content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.item.fullName} · ${widget.item.dayLabel}'),
              const SizedBox(height: 8),
              Text('Причина: ${widget.item.reason}'),
              if (preview != null) ...[
                const SizedBox(height: 12),
                Text(
                    'Сейчас ${formatWorkDuration((preview.current['minutes'] as num).toInt())} → добавить ${formatWorkDuration(widget.item.additionalMinutes)} → после одобрения ${formatWorkDuration(preview.proposedMinutes)}',
                    style: Theme.of(context).textTheme.titleMedium),
                if (preview.changes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('После отправки запроса табель изменился:',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  ...preview.changes.map((change) {
                    final field = change['field'] as String;
                    return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            '${attendanceChangeLabels[field] ?? field}: ${attendanceChangeValue(field, change['before'])} → ${attendanceChangeValue(field, change['after'])}'));
                  }),
                ],
                if (preview.hoursChanged)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _confirmed,
                    onChanged: (value) =>
                        setState(() => _confirmed = value ?? false),
                    title: Text(
                        'Подтверждаю актуальный итог: ${formatWorkDuration(preview.proposedMinutes)}'),
                  ),
                const SizedBox(height: 12),
                const Text(
                    'Время прихода и ухода не изменится. Закрытый день останется закрытым.'),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _comment,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                    labelText: widget.approve
                        ? 'Ответ сотруднику (необязательно)'
                        : 'Причина отклонения (обязательно)'),
              ),
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          )),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Назад')),
        FilledButton(
            onPressed: _submit,
            child: Text(widget.approve ? 'Добавить часы' : 'Отклонить')),
      ],
    );
  }
}
