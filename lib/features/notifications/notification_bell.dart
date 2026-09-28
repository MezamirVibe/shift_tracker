import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'notifications_service.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final service = NotificationsService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final count = service.unreadCount;
        return IconButton(
          tooltip:
              count == 0 ? 'Уведомления' : 'Уведомления: $count непрочитанных',
          onPressed: () => context.push('/notifications'),
          icon: Badge(
            isLabelVisible: count > 0,
            label: Text(count > 99 ? '99+' : '$count'),
            child: const Icon(Icons.notifications_outlined),
          ),
        );
      },
    );
  }
}
