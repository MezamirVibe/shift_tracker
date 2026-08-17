import 'package:flutter/material.dart';

import '../preferences/preferences_service.dart';
import '../preferences/user_preferences.dart';

class DashboardCustomizer extends StatefulWidget {
  final bool initialMobile;

  const DashboardCustomizer({
    super.key,
    required this.initialMobile,
  });

  static Future<void> show(
    BuildContext context, {
    required bool mobile,
  }) async {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 700) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.92,
          child: DashboardCustomizer(initialMobile: mobile),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 720,
          height: 720,
          child: DashboardCustomizer(initialMobile: mobile),
        ),
      ),
    );
  }

  @override
  State<DashboardCustomizer> createState() => _DashboardCustomizerState();
}

class _DashboardCustomizerState extends State<DashboardCustomizer> {
  final _service = PreferencesService.instance;
  late bool _mobile;
  late List<DashboardWidgetPreference> _items;

  @override
  void initState() {
    super.initState();
    _mobile = widget.initialMobile;
    _reload();
  }

  void _reload() {
    final current = _service.layoutFor(mobile: _mobile);
    final byType = {for (final item in current) item.type: item};
    _items = [
      ...current,
      for (final type in _service.allowedWidgets)
        if (!byType.containsKey(type))
          DashboardWidgetPreference(type: type, enabled: false),
    ];
  }

  void _switchMode(bool mobile) {
    setState(() {
      _mobile = mobile;
      _reload();
    });
  }

  Future<void> _save() async {
    await _service.updateLayout(mobile: _mobile, items: _items);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Настроить главный экран',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Закрыть',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Включайте блоки, меняйте их порядок и размер. Настройки сохраняются для вашей учётной записи.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.desktop_windows_outlined),
                label: Text('Компьютер'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.smartphone_outlined),
                label: Text('Телефон'),
              ),
            ],
            selected: {_mobile},
            onSelectionChanged: (value) => _switchMode(value.first),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _items.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _items.removeAt(oldIndex);
                  _items.insert(newIndex, item);
                });
              },
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  key: ValueKey(item.type),
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_indicator),
                          ),
                        ),
                        Checkbox(
                          value: item.enabled,
                          onChanged: (value) {
                            setState(() {
                              _items[index] = item.copyWith(
                                enabled: value ?? false,
                              );
                            });
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.type.label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.type.description,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (!_mobile)
                          DropdownButton<DashboardWidgetSize>(
                            value: item.size,
                            underline: const SizedBox.shrink(),
                            onChanged: item.enabled
                                ? (size) {
                                    if (size == null) return;
                                    setState(() {
                                      _items[index] = item.copyWith(size: size);
                                    });
                                  }
                                : null,
                            items: [
                              for (final size in DashboardWidgetSize.values)
                                DropdownMenuItem(
                                  value: size,
                                  child: Text(size.label),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  await _service.resetLayout(mobile: _mobile);
                  if (!mounted) return;
                  setState(_reload);
                },
                icon: const Icon(Icons.restart_alt),
                label: const Text('По умолчанию'),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check),
                label: const Text('Сохранить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
