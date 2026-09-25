import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'notification_models.dart';
import 'notifications_page.dart';
import 'notifications_service.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final _service = NotificationsService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_service.refresh());
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Уведомления'),
          leading: BackButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/settings'),
          ),
        ),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _service,
            builder: (context, _) => NotificationSettingsContent(
              preferences: _service.preferences,
              visibleKinds: _service.visibleKinds,
              enabled: _service.preferencesLoaded && !_service.saving,
              loading: _service.loading,
              saving: _service.saving,
              lastUpdated: _service.lastUpdated,
              error: _service.lastError ?? _service.deviceError,
              deliveryStatus: _service.deliveryStatus,
              canRequestPermission: _service.nativeStatus.supported &&
                  _service.nativeStatus.configured &&
                  _service.preferences.pushAvailable &&
                  _service.preferences.pushEnabled &&
                  _service.nativeStatus.permission != 'granted',
              onRefresh: _service.refresh,
              onPermission: _service.requestPermission,
              onChanged: (patch) => _service.savePreferences(patch,
                  askPermission: patch['push_enabled'] == true),
            ),
          ),
        ),
      );
}

class NotificationSettingsContent extends StatelessWidget {
  const NotificationSettingsContent({
    super.key,
    required this.preferences,
    required this.visibleKinds,
    required this.enabled,
    required this.loading,
    required this.saving,
    required this.deliveryStatus,
    required this.canRequestPermission,
    required this.onRefresh,
    required this.onPermission,
    required this.onChanged,
    this.error,
    this.lastUpdated,
  });

  final NotificationPreferences preferences;
  final List<String> visibleKinds;
  final bool enabled;
  final bool loading;
  final bool saving;
  final String deliveryStatus;
  final bool canRequestPermission;
  final String? error;
  final DateTime? lastUpdated;
  final VoidCallback onRefresh;
  final VoidCallback onPermission;
  final ValueChanged<Map<String, dynamic>> onChanged;

  Future<void> _pickTime(BuildContext context, {required bool start}) async {
    final value = start ? preferences.quietStart : preferences.quietEnd;
    final parts = value.split(':');
    final selected = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (selected == null || !context.mounted) return;
    final text =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    final other = start ? preferences.quietEnd : preferences.quietStart;
    if (text == other) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Начало и конец тихих часов должны отличаться.')));
      return;
    }
    onChanged({start ? 'quiet_start' : 'quiet_end': text});
  }

  Future<void> _pickTimezone(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _TimezoneDialog(initial: preferences.timezone),
    );
    if (selected != null && context.mounted) onChanged({'timezone': selected});
  }

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              NotificationSyncStatus(
                loading: loading,
                saving: saving,
                lastUpdated: lastUpdated,
                error: error,
                onRefresh: onRefresh,
              ),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('Пуш-уведомления'),
                      subtitle: const Text(
                          'Сообщения вне приложения. Можно выключить все сразу.'),
                      value: preferences.pushEnabled,
                      onChanged: enabled
                          ? (value) => onChanged({'push_enabled': value})
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(deliveryStatus),
                    ),
                    if (canRequestPermission)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: FilledButton.tonal(
                          onPressed: enabled ? onPermission : null,
                          child: const Text('Разрешить на устройстве'),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: TextButton.icon(
                        onPressed: loading || saving ? null : onRefresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Обновить статус'),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
                child: Text('Какие уведомления присылать',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Card(
                child: Column(
                  children: [
                    for (final kind in visibleKinds)
                      SwitchListTile.adaptive(
                        title: Text(notificationKindLabels[kind] ?? kind),
                        subtitle: switch (kind) {
                          'shift_reminder' =>
                            const Text('В 20:00, если завтра рабочий день'),
                          'unfilled_days' => const Text(
                              'В 18:00, только если есть незаполненные или незакрытые дни'),
                          _ => null,
                        },
                        value: preferences.kinds[kind] ?? false,
                        onChanged: enabled
                            ? (value) => onChanged({
                                  'kinds': {kind: value}
                                })
                            : null,
                      ),
                    if (visibleKinds.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'Для вашей роли пока нет доступных типов уведомлений.'),
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                    'История изменений часов, графика и запросов остаётся в приложении даже без пушей. Выключенные напоминания по расписанию не создаются.'),
              ),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: const Text('Не беспокоить'),
                  subtitle: Text(preferences.quietHoursEnabled
                      ? '${preferences.quietStart}–${preferences.quietEnd} · ${preferences.timezone}'
                      : 'Тихие часы выключены'),
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('Тихие часы'),
                      subtitle: const Text(
                          'Пуши придут позже, если событие ещё актуально'),
                      value: preferences.quietHoursEnabled,
                      onChanged: enabled
                          ? (value) => onChanged({'quiet_hours_enabled': value})
                          : null,
                    ),
                    ListTile(
                      title: const Text('Начало'),
                      trailing: Text(preferences.quietStart),
                      enabled: enabled && preferences.quietHoursEnabled,
                      onTap: () => _pickTime(context, start: true),
                    ),
                    ListTile(
                      title: const Text('Конец'),
                      trailing: Text(preferences.quietEnd),
                      enabled: enabled && preferences.quietHoursEnabled,
                      onTap: () => _pickTime(context, start: false),
                    ),
                    ListTile(
                      title: const Text('Часовой пояс'),
                      subtitle: Text(preferences.timezone),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: enabled,
                      onTap: () => _pickTimezone(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _TimezoneDialog extends StatefulWidget {
  const _TimezoneDialog({required this.initial});
  final String initial;

  @override
  State<_TimezoneDialog> createState() => _TimezoneDialogState();
}

class _TimezoneDialogState extends State<_TimezoneDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Часовой пояс'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Название часового пояса',
                  helperText: 'Например, Europe/Moscow или Asia/Yekaterinburg',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final zone in const {
                    'Москва': 'Europe/Moscow',
                    'Екатеринбург': 'Asia/Yekaterinburg',
                    'Новосибирск': 'Asia/Novosibirsk',
                  }.entries)
                    ActionChip(
                        label: Text(zone.key),
                        onPressed: () => _controller.text = zone.value),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final value = _controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('Сохранить'),
          ),
        ],
      );
}
