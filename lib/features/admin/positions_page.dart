import 'package:flutter/material.dart';

import '../../core/id.dart';

import '../employees/employees_storage.dart';
import '../positions/positions_storage.dart';

class PositionsPage extends StatefulWidget {
  const PositionsPage({super.key});

  @override
  State<PositionsPage> createState() => _PositionsPageState();
}

class _PositionsPageState extends State<PositionsPage> {
  final _positionsStorage = PositionsStorage();
  final _employeesStorage = EmployeesStorage();

  bool _loading = true;
  List<PositionModel> _positions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() => _loading = true);
    }

    final positions = await _positionsStorage.loadPositions();

    if (!mounted) return;

    setState(() {
      _positions = positions;
      _loading = false;
    });
  }

  bool _existsByName(String name, {String? excludeId}) {
    final normalized = name.trim().toLowerCase();
    return _positions.any(
      (p) => p.id != excludeId && p.name.trim().toLowerCase() == normalized,
    );
  }

  Future<void> _createPosition() async {
    final ctrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новая должность'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название должности',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );

    if (ok != true) {
      ctrl.dispose();
      return;
    }

    final name = ctrl.text.trim();
    ctrl.dispose();

    if (name.isEmpty) {
      _snack('Название должности пустое');
      return;
    }

    if (_existsByName(name)) {
      _snack('Такая должность уже есть');
      return;
    }

    final item = PositionModel(
      id: newUuidV4(),
      name: name,
    );

    final updated = [..._positions, item]
      ..sort((a, b) => a.name.compareTo(b.name));
    await _positionsStorage.savePositions(updated);

    if (!mounted) return;
    setState(() => _positions = updated);
    _snack('Должность добавлена');
  }

  Future<void> _renamePosition(PositionModel item) async {
    final ctrl = TextEditingController(text: item.name);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переименовать должность'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название должности',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (ok != true) {
      ctrl.dispose();
      return;
    }

    final name = ctrl.text.trim();
    ctrl.dispose();

    if (name.isEmpty) {
      _snack('Название должности пустое');
      return;
    }

    if (_existsByName(name, excludeId: item.id)) {
      _snack('Такая должность уже есть');
      return;
    }

    final updated = _positions
        .map((p) => p.id == item.id ? p.copyWith(name: name) : p)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    await _positionsStorage.savePositions(updated);

    if (!mounted) return;
    setState(() => _positions = updated);
    _snack('Должность обновлена');
  }

  Future<void> _deletePosition(PositionModel item) async {
    final employees = await _employeesStorage.load();
    final inUse = employees.any(
      (e) => e.position.trim().toLowerCase() == item.name.trim().toLowerCase(),
    );

    if (inUse) {
      _snack(
        'Нельзя удалить должность, потому что она уже используется у сотрудников',
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить должность?'),
        content: Text('Удалить "${item.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final updated = _positions.where((p) => p.id != item.id).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    await _positionsStorage.savePositions(updated);

    if (!mounted) return;
    setState(() => _positions = updated);
    _snack('Должность удалена');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Справочник должностей',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  'Здесь задаётся список должностей. При создании сотрудника должность будет выбираться из этого списка.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _createPosition,
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить должность'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_positions.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Справочник должностей пока пуст. Добавь первую должность.',
              ),
            ),
          )
        else
          ..._positions.map(
            (item) => Card(
              child: ListTile(
                title: Text(item.name),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Переименовать',
                      onPressed: () => _renamePosition(item),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: () => _deletePosition(item),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
