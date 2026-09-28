import 'dart:async';

import 'package:flutter/material.dart';

import '../preferences/preferences_service.dart';
import 'app_update_service.dart';

Future<void> showAppUpdateDialog(BuildContext context) async {
  final service = AppUpdateService.instance;
  unawaited(service.check(force: true));
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppUpdateDialog(service: service));
}

class AppUpdateTile extends StatelessWidget {
  const AppUpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AppUpdateService.instance;
    if (!service.supported) return const SizedBox.shrink();
    return ListenableBuilder(
        listenable: service,
        builder: (context, _) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(service.hasUpdate
                  ? Icons.system_update
                  : Icons.system_update_outlined),
              title: Text(service.hasUpdate
                  ? 'Доступна версия ${service.release!.version}'
                  : 'Обновление приложения'),
              subtitle: Text(service.installedVersion == null
                  ? 'Проверить новую версию'
                  : 'Установлена ${service.installedVersion} · проверить обновления'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAppUpdateDialog(context),
            ));
  }
}

class AppUpdateDialog extends StatelessWidget {
  final AppUpdateService service;
  const AppUpdateDialog({super.key, required this.service});

  Future<void> _install(BuildContext context) async {
    if (PreferencesService.instance.saving) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Подождите, настройки ещё сохраняются.')));
      return;
    }
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('Установить обновление?'),
              content: Text(service.platform == 'windows'
                  ? 'Сохраните незавершённые изменения. «Череда» закроется и откроется после обновления. Сохранённые табели и настройки останутся на месте.'
                  : 'Откроется системный установщик. Подтвердите обновление «Череды». Удалять прежнюю версию не нужно: сохранённые табели и настройки останутся на месте.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Позже')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Установить')),
              ],
            ));
    if (confirm == true && context.mounted) await service.install();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final phase = service.phase;
          final next = service.release;
          return PopScope(
            canPop: phase != UpdatePhase.installing,
            child: AlertDialog(
              scrollable: true,
              title: const Text('Обновление «Череды»'),
              content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (service.installedVersion != null)
                        Text(
                            'Установлена: ${service.installedVersion} (${service.installedBuild})'),
                      if (next != null) ...[
                        const SizedBox(height: 12),
                        Text('Новая версия: ${next.version}',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text('${(next.size / 1048576).toStringAsFixed(1)} МБ'),
                        const SizedBox(height: 8),
                        for (final note in next.notes)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text('• $note')),
                      ],
                      if (phase == UpdatePhase.checking ||
                          phase == UpdatePhase.installing) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(phase == UpdatePhase.checking
                            ? 'Проверяем версию…'
                            : 'Проверяем файл и готовим установку…'),
                      ],
                      if (phase == UpdatePhase.downloading) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: service.progress),
                        const SizedBox(height: 8),
                        Text(
                            'Загрузка: ${(service.progress * 100).toStringAsFixed(0)}%'),
                      ],
                      if (service.message != null) ...[
                        const SizedBox(height: 12),
                        Text(service.message!),
                      ],
                      if (service.installNotice != null) ...[
                        const SizedBox(height: 12),
                        Text(service.installNotice!),
                      ],
                      if (service.error != null) ...[
                        const SizedBox(height: 12),
                        Text(service.error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ],
                      if (service.checkedAt != null) ...[
                        const SizedBox(height: 12),
                        Text('Проверено: ${_time(service.checkedAt!)}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  )),
              actions: [
                TextButton(
                    onPressed: phase == UpdatePhase.installing
                        ? null
                        : () => Navigator.pop(context),
                    child: Text(phase == UpdatePhase.downloading
                        ? 'Свернуть'
                        : 'Закрыть')),
                if (phase == UpdatePhase.downloading)
                  TextButton(
                      onPressed: service.cancelDownload,
                      child: const Text('Отменить загрузку')),
                if (!service.busy && phase != UpdatePhase.ready && next == null)
                  FilledButton(
                      onPressed: () => service.check(force: true),
                      child: const Text('Проверить')),
                if (!service.busy && phase != UpdatePhase.ready && next != null)
                  FilledButton(
                      onPressed: service.download,
                      child: const Text('Скачать обновление')),
                if (phase == UpdatePhase.ready)
                  TextButton(
                      onPressed: service.retryDownload,
                      child: const Text('Скачать заново')),
                if (phase == UpdatePhase.ready)
                  FilledButton(
                      onPressed: () => _install(context),
                      child: const Text('Установить')),
              ],
            ),
          );
        },
      );

  String _time(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
