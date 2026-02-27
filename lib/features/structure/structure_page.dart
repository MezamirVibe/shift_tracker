import 'package:flutter/material.dart';

import 'structure_storage.dart';

class StructurePage extends StatefulWidget {
  const StructurePage({super.key});

  @override
  State<StructurePage> createState() => _StructurePageState();
}

class _StructurePageState extends State<StructurePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _storage = StructureStorage();

  bool _loading = true;
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final deps = await _storage.loadDepartments();
    final grps = await _storage.loadGroups();
    if (!mounted) return;
    setState(() {
      _departments = deps;
      _groups = grps;
      _loading = false;
    });
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<String?> _askName({
    required String title,
    String initial = '',
  }) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название'),
          onSubmitted: (_) => Navigator.of(context).pop(true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return null;
    final name = c.text.trim();
    if (name.isEmpty) return null;
    return name;
  }

  // ---------- Departments ----------

  Future<void> _addDepartment() async {
    final name = await _askName(title: 'Добавить подразделение');
    if (name == null) return;

    final dep = DepartmentModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
    );

    final next = [..._departments, dep]
      ..sort((a, b) => a.name.compareTo(b.name));
    setState(() => _departments = next);
    await _storage.saveDepartments(_departments);
    _snack('Подразделение добавлено');
  }

  Future<void> _renameDepartment(DepartmentModel dep) async {
    final name =
        await _askName(title: 'Переименовать подразделение', initial: dep.name);
    if (name == null) return;

    setState(() {
      _departments = _departments
          .map((d) => d.id == dep.id ? d.copyWith(name: name) : d)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    });
    await _storage.saveDepartments(_departments);
    _snack('Сохранено');
  }

  Future<void> _deleteDepartment(DepartmentModel dep) async {
    final linkedGroups = _groups.where((g) => g.departmentId == dep.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить подразделение?'),
        content: Text(
          linkedGroups > 0
              ? 'В этом подразделении есть групп: $linkedGroups.\nСначала удали/перенеси группы.'
              : 'Удалить "${dep.name}"?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
            onPressed:
                linkedGroups > 0 ? null : () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _departments = _departments.where((d) => d.id != dep.id).toList();
    });
    await _storage.saveDepartments(_departments);
    _snack('Удалено');
  }

  // ---------- Groups ----------

  Future<void> _addGroup() async {
    if (_departments.isEmpty) {
      _snack('Сначала создай подразделение');
      return;
    }

    DepartmentModel selected = _departments.first;

    final nameController = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить группу'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected.id,
                decoration: const InputDecoration(labelText: 'Подразделение'),
                items: _departments
                    .map((d) =>
                        DropdownMenuItem(value: d.id, child: Text(d.name)))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  selected = _departments.firstWhere((d) => d.id == v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Название группы'),
                autofocus: true,
                onSubmitted: (_) => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Создать')),
        ],
      ),
    );

    if (ok != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final g = GroupModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      departmentId: selected.id,
      name: name,
    );

    setState(() {
      _groups = [..._groups, g]..sort((a, b) => a.name.compareTo(b.name));
    });

    await _storage.saveGroups(_groups);
    _snack('Группа добавлена');
  }

  Future<void> _editGroup(GroupModel g) async {
    if (_departments.isEmpty) {
      _snack('Нет подразделений');
      return;
    }

    String depId = g.departmentId;
    final nameController = TextEditingController(text: g.name);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Редактировать группу'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: depId,
                decoration: const InputDecoration(labelText: 'Подразделение'),
                items: _departments
                    .map((d) =>
                        DropdownMenuItem(value: d.id, child: Text(d.name)))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  depId = v;
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Название группы'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Сохранить')),
        ],
      ),
    );

    if (ok != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _groups = _groups
          .map((x) =>
              x.id == g.id ? x.copyWith(departmentId: depId, name: name) : x)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    });

    await _storage.saveGroups(_groups);
    _snack('Сохранено');
  }

  Future<void> _deleteGroup(GroupModel g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить группу?'),
        content: Text('Удалить "${g.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Удалить')),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _groups = _groups.where((x) => x.id != g.id).toList();
    });
    await _storage.saveGroups(_groups);
    _snack('Удалено');
  }

  String _depName(String depId) {
    final d = _departments
        .where((x) => x.id == depId)
        .cast<DepartmentModel?>()
        .firstOrNull;
    return d?.name ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Структура'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Подразделения'),
            Tab(text: 'Группы'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                // Departments
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _addDepartment,
                        icon: const Icon(Icons.add),
                        label: const Text('Добавить подразделение'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._departments.map(
                      (d) => Card(
                        child: ListTile(
                          title: Text(d.name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Переименовать',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _renameDepartment(d),
                              ),
                              IconButton(
                                tooltip: 'Удалить',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _deleteDepartment(d),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_departments.isEmpty)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('Пока пусто'))),
                  ],
                ),

                // Groups
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _addGroup,
                        icon: const Icon(Icons.add),
                        label: const Text('Добавить группу'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._groups.map(
                      (g) => Card(
                        child: ListTile(
                          title: Text(g.name),
                          subtitle: Text(
                              'Подразделение: ${_depName(g.departmentId)}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Редактировать',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _editGroup(g),
                              ),
                              IconButton(
                                tooltip: 'Удалить',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _deleteGroup(g),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_groups.isEmpty)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('Пока пусто'))),
                  ],
                ),
              ],
            ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
