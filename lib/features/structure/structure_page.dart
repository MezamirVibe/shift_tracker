import 'package:flutter/material.dart';

import '../../core/id.dart';
import '../employees/employees_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

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
  bool _saving = false;
  String? _loadError;
  List<DepartmentModel> _departments = [];
  List<GroupModel> _groups = [];

  bool get _canEdit =>
      !_saving && AuthService.instance.hasPerm(AppPermission.editEmployees);
  ScopeKind? get _scope => AuthService.instance
      .roleById(AuthService.instance.currentUser?.roleId)
      ?.scopeKind;
  bool get _global =>
      AuthService.instance.isCurrentUserSuperAdmin || _scope == ScopeKind.all;
  bool get _canCreateDepartment => _canEdit && _global;
  bool get _canCreateGroup =>
      _canEdit && (_global || _scope == ScopeKind.department);
  bool _canEditDepartment(DepartmentModel department) =>
      _canEdit &&
      (_global ||
          (_scope == ScopeKind.department &&
              AuthService.instance.currentUser?.departmentId == department.id));
  bool _canEditGroup(GroupModel group) =>
      _canEdit &&
      (_global ||
          (_scope == ScopeKind.department &&
              AuthService.instance.currentUser?.departmentId ==
                  group.departmentId) ||
          (_scope == ScopeKind.group &&
              AuthService.instance.currentUser?.groupId == group.id));

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
    try {
      final deps = await _storage.loadDepartments(force: true);
      final grps = await _storage.loadGroups(force: true);
      if (!mounted) return;
      setState(() {
        _departments = deps;
        _groups = grps;
        _loadError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = 'Не удалось загрузить структуру: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _persist(Future<void> Function() save, String message) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await save();
      EmployeesStorage().invalidateCache();
      if (mounted) await _load();
      if (mounted) _snack(message);
    } catch (error) {
      if (mounted) {
        _snack('Не удалось сохранить: $error');
        await _load();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<String?> _askName({required String title, String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Сохранить'),
          ),
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

    final dep = DepartmentModel(id: newUuidV4(), name: name);

    final next = [..._departments, dep]
      ..sort((a, b) => a.name.compareTo(b.name));
    setState(() => _departments = next);
    await _persist(
      () => _storage.saveDepartments(_departments),
      'Подразделение добавлено',
    );
  }

  Future<void> _renameDepartment(DepartmentModel dep) async {
    final name = await _askName(
      title: 'Переименовать подразделение',
      initial: dep.name,
    );
    if (name == null) return;

    setState(() {
      _departments =
          _departments
              .map((d) => d.id == dep.id ? d.copyWith(name: name) : d)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
    });
    await _persist(() => _storage.saveDepartments(_departments), 'Сохранено');
  }

  Future<void> _deleteDepartment(DepartmentModel dep) async {
    final linkedGroups = _groups.where((g) => g.departmentId == dep.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Удалить подразделение?'),
        content: Text(
          'Удалить «${dep.name}»${linkedGroups > 0 ? ' и все его группы ($linkedGroups)' : ''}? '
          'Сотрудники останутся в организации без подразделения. Их часы и старые табели сохранятся. '
          'Привязанный доступ пользователей сначала нужно изменить в разделе «Пользователи».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _departments = _departments.where((d) => d.id != dep.id).toList();
    });
    await _persist(
      () => _storage.deleteDepartment(dep.id),
      'Подразделение удалено, сотрудники сохранены',
    );
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
        scrollable: true,
        title: const Text('Добавить группу'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                itemHeight: null,
                isExpanded: true,
                initialValue: selected.id,
                decoration: const InputDecoration(labelText: 'Подразделение'),
                items: _departments
                    .map(
                      (d) => DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Создать'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final g = GroupModel(
      id: newUuidV4(),
      departmentId: selected.id,
      name: name,
    );

    setState(() {
      _groups = [..._groups, g]..sort((a, b) => a.name.compareTo(b.name));
    });

    await _persist(() => _storage.saveGroups(_groups), 'Группа добавлена');
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
        scrollable: true,
        title: const Text('Редактировать группу'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                itemHeight: null,
                isExpanded: true,
                initialValue: depId,
                decoration: const InputDecoration(labelText: 'Подразделение'),
                items: _departments
                    .map(
                      (d) => DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: !_global
                    ? null
                    : (v) {
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _groups =
          _groups
              .map(
                (x) => x.id == g.id
                    ? x.copyWith(departmentId: depId, name: name)
                    : x,
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
    });

    await _persist(() => _storage.saveGroups(_groups), 'Сохранено');
  }

  Future<void> _deleteGroup(GroupModel g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Удалить группу?'),
        content: Text(
          'Удалить «${g.name}»? Сотрудники останутся в своём подразделении без группы. '
          'Часы и старые табели сохранятся. Привязанный доступ пользователей сначала нужно изменить в разделе «Пользователи».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _groups = _groups.where((x) => x.id != g.id).toList();
    });
    await _persist(
      () => _storage.deleteGroup(g.id),
      'Группа удалена, сотрудники сохранены',
    );
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
          : _loadError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_loadError!),
                  TextButton(onPressed: _load, child: const Text('Повторить')),
                ],
              ),
            )
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
                        onPressed: _canCreateDepartment ? _addDepartment : null,
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
                                onPressed: _canEditDepartment(d)
                                    ? () => _renameDepartment(d)
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Удалить',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _canEditDepartment(d)
                                    ? () => _deleteDepartment(d)
                                    : null,
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
                          child: Text('Пока пусто'),
                        ),
                      ),
                  ],
                ),

                // Groups
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _canCreateGroup ? _addGroup : null,
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
                            'Подразделение: ${_depName(g.departmentId)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Редактировать',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: _canEditGroup(g)
                                    ? () => _editGroup(g)
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Удалить',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _canEditGroup(g)
                                    ? () => _deleteGroup(g)
                                    : null,
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
                          child: Text('Пока пусто'),
                        ),
                      ),
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
