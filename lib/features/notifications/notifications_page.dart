import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/route_observer.dart';
import 'notification_models.dart';
import 'notifications_service.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> with RouteAware {
  final _service = NotificationsService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_service.refresh());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() => unawaited(_service.refresh());

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Уведомления'),
          leading: BackButton(
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          ),
          actions: [
            IconButton(
              tooltip: 'Настройки уведомлений',
              onPressed: () => context.push('/settings/notifications'),
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _service,
            builder: (context, _) => NotificationsInboxContent(
              items: _service.items,
              unreadCount: _service.unreadCount,
              loading: _service.loading,
              loadingMore: _service.loadingMore,
              hasMore: _service.hasMore,
              error: _service.lastError,
              lastUpdated: _service.lastUpdated,
              onRefresh: _service.refresh,
              onLoadMore: _service.loadMore,
              onReadAll: _service.markAllRead,
              onOpen: _service.openItem,
            ),
          ),
        ),
      );
}

/// Presentation is independent of the session so narrow layouts can be tested
/// with long content without ever contacting the production server.
class NotificationsInboxContent extends StatelessWidget {
  const NotificationsInboxContent({
    super.key,
    required this.items,
    required this.unreadCount,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onReadAll,
    required this.onOpen,
    this.error,
    this.lastUpdated,
  });

  final List<InboxNotification> items;
  final int unreadCount;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? error;
  final DateTime? lastUpdated;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onReadAll;
  final ValueChanged<InboxNotification> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.all(12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(lastUpdated == null && items.isEmpty
                      ? 'История уведомлений'
                      : unreadCount == 0
                          ? 'Всё прочитано'
                          : 'Непрочитанных: $unreadCount'),
                  TextButton.icon(
                    onPressed: unreadCount == 0 || loading ? null : onReadAll,
                    icon: const Icon(Icons.done_all),
                    label: const Text('Прочитать все'),
                  ),
                ],
              ),
              NotificationSyncStatus(
                loading: loading,
                lastUpdated: lastUpdated,
                error: error,
                onRefresh: onRefresh,
              ),
              if (items.isEmpty && !loading && error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                  child: Column(
                    children: [
                      Icon(Icons.notifications_none, size: 44),
                      SizedBox(height: 12),
                      Text('Новых событий пока нет',
                          textAlign: TextAlign.center),
                      SizedBox(height: 8),
                      Text(
                        'Здесь появятся изменения графика, учтённых часов и ответы на запросы. Старые события не добавляются задним числом.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final item in items)
                Card(
                  key: ValueKey(item.id),
                  clipBehavior: Clip.antiAlias,
                  color: item.readAt == null ? scheme.primaryContainer : null,
                  child: InkWell(
                    onTap: () => onOpen(item),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(item.icon,
                              color: item.readAt == null
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DefaultTextStyle.merge(
                              style: TextStyle(
                                  color: item.readAt == null
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurface),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (item.readAt == null)
                                    const Text('Не прочитано',
                                        style: TextStyle(fontSize: 12)),
                                  Text(item.title,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  if (item.body.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(item.body),
                                  ],
                                  const SizedBox(height: 8),
                                  Text(
                                      DateFormat('dd.MM.yyyy, HH:mm')
                                          .format(item.createdAt.toLocal()),
                                      style: const TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (hasMore || loadingMore)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: OutlinedButton(
                    onPressed: loadingMore || loading ? null : onLoadMore,
                    child: Text(loadingMore ? 'Загружаем…' : 'Показать ещё'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationSyncStatus extends StatelessWidget {
  const NotificationSyncStatus({
    super.key,
    required this.loading,
    required this.onRefresh,
    this.lastUpdated,
    this.error,
    this.saving = false,
  });

  final bool loading;
  final bool saving;
  final DateTime? lastUpdated;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading || saving) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(saving ? 'Сохраняем настройки…' : 'Обновляем…'),
          ],
          if (lastUpdated != null)
            Text(
              'Обновлено: ${DateFormat('dd.MM.yyyy, HH:mm').format(lastUpdated!.toLocal())}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error!,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer)),
                    TextButton.icon(
                      onPressed: loading || saving ? null : onRefresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Повторить'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
      );
}
