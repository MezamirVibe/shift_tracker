import 'package:flutter/material.dart';

const notificationKindLabels = <String, String>{
  'hours_closed': 'Закрытие и переоткрытие дня',
  'request_decision': 'Ответ на запрос часов',
  'schedule_changed': 'Изменение графика',
  'shift_reminder': 'Напомнить вечером о завтрашней смене',
  'request_created': 'Новый запрос часов',
  'unfilled_days': 'Сводка незаполненных дней',
  'delivery_failed': 'Ошибка отправки табеля',
};

class NotificationPreferences {
  final bool pushEnabled;
  final bool pushAvailable;
  final Map<String, bool> kinds;
  final bool quietHoursEnabled;
  final String quietStart;
  final String quietEnd;
  final String timezone;

  const NotificationPreferences({
    this.pushEnabled = false,
    this.pushAvailable = false,
    this.kinds = const {
      'hours_closed': true,
      'request_decision': true,
      'schedule_changed': true,
      'shift_reminder': false,
      'request_created': true,
      'unfilled_days': false,
      'delivery_failed': true,
    },
    this.quietHoursEnabled = true,
    this.quietStart = '22:00',
    this.quietEnd = '08:00',
    this.timezone = 'Asia/Yekaterinburg',
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    const defaults = NotificationPreferences();
    final rawKinds = json['kinds'];
    return NotificationPreferences(
      pushEnabled: json['push_enabled'] == true,
      pushAvailable: json['push_available'] == true,
      kinds: {
        ...defaults.kinds,
        if (rawKinds is Map)
          for (final key in notificationKindLabels.keys)
            if (rawKinds[key] is bool) key: rawKinds[key] as bool,
      },
      quietHoursEnabled: json['quiet_hours_enabled'] != false,
      quietStart: json['quiet_start'] as String? ?? defaults.quietStart,
      quietEnd: json['quiet_end'] as String? ?? defaults.quietEnd,
      timezone: json['timezone'] as String? ?? defaults.timezone,
    );
  }
}

class InboxNotification {
  final String id;
  final String kind;
  final String title;
  final String body;
  final String? day;
  final String? requestId;
  final DateTime createdAt;
  final DateTime? readAt;

  const InboxNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.day,
    this.requestId,
    this.readAt,
  });

  factory InboxNotification.fromJson(Map<String, dynamic> json) =>
      InboxNotification(
        id: json['id'] as String,
        kind: json['kind'] as String,
        title: json['title'] as String? ?? 'Уведомление',
        body: json['body'] as String? ?? '',
        day: json['day'] as String?,
        requestId: json['request_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt: DateTime.tryParse(json['read_at'] as String? ?? ''),
      );

  InboxNotification asRead() => InboxNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        day: day,
        requestId: requestId,
        createdAt: createdAt,
        readAt: readAt ?? DateTime.now(),
      );

  IconData get icon => switch (kind) {
        'hours_closed' => Icons.task_alt,
        'request_decision' => Icons.mark_chat_read_outlined,
        'request_created' => Icons.chat_bubble_outline,
        'schedule_changed' => Icons.event_repeat,
        'shift_reminder' => Icons.alarm,
        'unfilled_days' => Icons.edit_calendar_outlined,
        'delivery_failed' => Icons.error_outline,
        _ => Icons.notifications_outlined,
      };
}

class NativeNotificationStatus {
  final bool supported;
  final bool configured;
  final String permission;
  final String? installationId;
  final String? token;

  const NativeNotificationStatus({
    this.supported = false,
    this.configured = false,
    this.permission = 'not_requested',
    this.installationId,
    this.token,
  });

  factory NativeNotificationStatus.fromJson(Map<dynamic, dynamic> json) =>
      NativeNotificationStatus(
        supported: json['supported'] == true,
        configured: json['configured'] == true,
        permission: json['permission'] as String? ?? 'not_requested',
        installationId: json['installation_id'] as String?,
        token: json['token'] as String?,
      );
}
