import 'package:flutter/material.dart';

import '../../core/id.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../positions/positions_storage.dart';
import '../structure/structure_storage.dart';
import 'employees_storage.dart';

class EmployeeDraft {
  final String fullName;
  final String position;
  final int salary;
  final int bonus;

  final String? departmentId;
  final String? groupId;

  final ScheduleType scheduleType;
  final DateTime scheduleStartDate;
  final int shiftHours;
  final int breakHours;
  final List<int> customWorkdays;

  final String? login;
  final String? roleId;

  const EmployeeDraft({
    required this.fullName,
    required this.position,
    required this.salary,
    required this.bonus,
    required this.departmentId,
    required this.groupId,
    required this.scheduleType,
    required this.scheduleStartDate,
    required this.shiftHours,
    required this.breakHours,
    required this.customWorkdays,
    this.login,
    this.roleId,
  });
}

class EmployeeEditorDialog extends StatefulWidget {
  final EmployeeDraft? initial;
  final String title;
  final String confirmText;
  final bool showAccessFields;
  final VoidCallback? onDeactivate;

  const EmployeeEditorDialog({
    super.key,
    this.initial,
    this.title = 'Добавить сотрудника',
    this.confirmText = 'Добавить',
    this.showAccessFields = false,
    this.onDeactivate,
  });

  @override
  State<EmployeeEditorDialog> createState() => _EmployeeEditorDialogState();
}

class _EmployeeEditorDialogState extends State<EmployeeEditorDialog> {
  final _structureStorage = StructureStorage();
  final _positionsStorage = PositionsStorage();

  late final TextEditingController _nameController;
  late final TextEditingController _salaryController;
  late final TextEditingController _bonusController;
  late final TextEditingController _loginController;

  bool _loadingStructure = true;
  bool _loadingPositions = true;

  List<dynamic> _departments = <dynamic>[];
  List<dynamic> _groups = <dynamic>[];
  List<PositionModel> _positions = <PositionModel>[];

  String? _departmentId;
  String? _groupId;
  String? _roleId;
  String? _positionName;

  late ScheduleType _scheduleType;
  late DateTime _scheduleStartDate;
  late int _shiftHours;
  late int _breakHours;
  late List<int> _customWorkdays;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;

    _nameController = TextEditingController(text: init?.fullName ?? '');
    _salaryController =
        TextEditingController(text: (init?.salary ?? 70000).toString());
    _bonusController =
        TextEditingController(text: (init?.bonus ?? 10000).toString());
    _loginController = TextEditingController(text: init?.login ?? '');

    _departmentId = init?.departmentId;
    _groupId = init?.groupId;
    _roleId = init?.roleId ?? BuiltInRoleIds.worker;
    _positionName = init?.position;

    _scheduleType = init?.scheduleType ?? ScheduleType.twoTwo;
    _scheduleStartDate = init?.scheduleStartDate ?? DateTime.now();
    _shiftHours = init?.shiftHours ?? 12;
    _breakHours = init?.breakHours ?? 1;
    _customWorkdays = [...?init?.customWorkdays];
    if (_customWorkdays.isEmpty) {
      _customWorkdays = [1, 2, 3, 4, 5];
    }

    _loadData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _salaryController.dispose();
    _bonusController.dispose();
    _loginController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loadingStructure = true;
      _loadingPositions = true;
    });

    final results = await Future.wait([
      _structureStorage.loadDepartments(),
      _structureStorage.loadGroups(),
      _positionsStorage.loadPositions(),
    ]);
    final deps = results[0] as List<DepartmentModel>;
    final groups = results[1] as List<GroupModel>;
    final positions = results[2] as List<PositionModel>;

    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));
    positions.sort((a, b) => a.name.compareTo(b.name));

    if (!mounted) return;

    setState(() {
      _departments = deps;
      _groups = groups;
      _positions = positions;
      _loadingStructure = false;
      _loadingPositions = false;
    });

    _normalizeSelectedGroup();

    if (_positionName != null &&
        _positionName!.trim().isNotEmpty &&
        !_positions.any((p) => p.name == _positionName)) {
      setState(() {
        _positionName = null;
      });
    }
  }

  int _parseInt(String s, {required int fallback}) {
    final v = int.tryParse(s.trim());
    return v ?? fallback;
  }

  void _normalizeSelectedGroup() {
    if (_groupId == null) return;
    final g = _groups.cast<dynamic>().firstWhere(
          (x) => x?.id == _groupId,
          orElse: () => null,
        );
    if (g == null) {
      setState(() => _groupId = null);
      return;
    }
    if (_departmentId == null || g.departmentId != _departmentId) {
      setState(() => _groupId = null);
    }
  }

  List<dynamic> get _groupsForSelectedDepartment {
    final depId = _departmentId;
    if (depId == null) return const [];
    return _groups.where((g) => g.departmentId == depId).toList();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: _scheduleStartDate,
    );

    if (picked == null) return;

    setState(() {
      _scheduleStartDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<void> _showAddPositionDialog() async {
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

    if (!mounted) {
      ctrl.dispose();
      return;
    }

    if (ok != true) {
      ctrl.dispose();
      return;
    }

    final name = ctrl.text.trim();
    ctrl.dispose();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Название должности пустое')),
      );
      return;
    }

    final exists = _positions.any(
      (p) => p.name.trim().toLowerCase() == name.toLowerCase(),
    );
    if (exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Такая должность уже есть')),
      );
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

    setState(() {
      _positions = updated;
      _positionName = name;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Должность добавлена')),
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    final login = _loginController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполни ФИО')),
      );
      return;
    }

    if (_positionName == null || _positionName!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбери должность')),
      );
      return;
    }

    if (widget.showAccessFields) {
      if (login.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Заполни логин для входа')),
        );
        return;
      }
      if (_roleId == null || _roleId!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Выбери роль')),
        );
        return;
      }
    }

    final salary = _parseInt(_salaryController.text, fallback: 0);
    final bonus = _parseInt(_bonusController.text, fallback: 0);

    if (_shiftHours <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Длительность смены должна быть больше 0')),
      );
      return;
    }

    if (_breakHours < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Перерыв не может быть отрицательным')),
      );
      return;
    }

    if (_breakHours >= _shiftHours) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Перерыв должен быть меньше длительности смены'),
        ),
      );
      return;
    }

    if (_scheduleType == ScheduleType.custom && _customWorkdays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбери хотя бы один рабочий день')),
      );
      return;
    }

    Navigator.of(context).pop(
      EmployeeDraft(
        fullName: name,
        position: _positionName!,
        salary: salary,
        bonus: bonus,
        departmentId: _departmentId,
        groupId: _groupId,
        scheduleType: _scheduleType,
        scheduleStartDate: _scheduleStartDate,
        shiftHours: _shiftHours,
        breakHours: _breakHours,
        customWorkdays: [..._customWorkdays]..sort(),
        login: widget.showAccessFields ? login : null,
        roleId: widget.showAccessFields ? _roleId : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupsForSelectedDepartment;
    final roles = AuthService.instance.roles.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'ФИО'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              if (_loadingPositions)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                )
              else ...[
                LayoutBuilder(
                  builder: (context, constraints) {
                    final field = DropdownButtonFormField<String>(
                      initialValue: _positionName,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Должность',
                        border: OutlineInputBorder(),
                      ),
                      items: _positions
                          .map(
                            (p) => DropdownMenuItem<String>(
                              value: p.name,
                              child: Text(
                                p.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() => _positionName = value);
                      },
                    );
                    final addButton = FilledButton.tonalIcon(
                      onPressed: _showAddPositionDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить должность'),
                    );

                    if (constraints.maxWidth < 460) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          field,
                          const SizedBox(height: 8),
                          addButton,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: field),
                        const SizedBox(width: 8),
                        addButton,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Должность выбирается из справочника.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _salaryController,
                decoration: const InputDecoration(labelText: 'Оклад (₽)'),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bonusController,
                decoration: const InputDecoration(labelText: 'Премия (₽)'),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              if (_loadingStructure)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                DropdownButtonFormField<String?>(
                  initialValue: _departmentId,
                  decoration: const InputDecoration(
                    labelText: 'Подразделение',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('— не выбрано —'),
                    ),
                    ..._departments.map(
                      (d) => DropdownMenuItem<String?>(
                        value: d.id as String?,
                        child: Text(d.name as String),
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _departmentId = v;
                      _groupId = null;
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _groupId,
                  decoration: const InputDecoration(
                    labelText: 'Группа',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('— не выбрано —'),
                    ),
                    ...groups.map(
                      (g) => DropdownMenuItem<String?>(
                        value: g.id as String?,
                        child: Text(g.name as String),
                      ),
                    ),
                  ],
                  onChanged: (_departmentId == null)
                      ? null
                      : (v) => setState(() => _groupId = v),
                ),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<ScheduleType>(
                initialValue: _scheduleType,
                decoration: const InputDecoration(
                  labelText: 'График',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ScheduleType.twoTwo,
                    child: Text('2/2'),
                  ),
                  DropdownMenuItem(
                    value: ScheduleType.fiveTwo,
                    child: Text('5/2'),
                  ),
                  DropdownMenuItem(
                    value: ScheduleType.custom,
                    child: Text('Произвольный'),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _scheduleType = v);
                },
              ),
              if (_scheduleType == ScheduleType.custom) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Рабочие дни недели',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      (1, 'Пн'),
                      (2, 'Вт'),
                      (3, 'Ср'),
                      (4, 'Чт'),
                      (5, 'Пт'),
                      (6, 'Сб'),
                      (7, 'Вс'),
                    ].map((item) {
                      return FilterChip(
                        label: Text(item.$2),
                        selected: _customWorkdays.contains(item.$1),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _customWorkdays.add(item.$1);
                            } else {
                              _customWorkdays.remove(item.$1);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickStartDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Дата старта графика',
                    border: OutlineInputBorder(),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_scheduleStartDate.day.toString().padLeft(2, '0')}.'
                          '${_scheduleStartDate.month.toString().padLeft(2, '0')}.'
                          '${_scheduleStartDate.year}',
                        ),
                      ),
                      const Icon(Icons.calendar_today_outlined, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _shiftHours,
                decoration: const InputDecoration(
                  labelText: 'Длительность смены',
                  border: OutlineInputBorder(),
                ),
                items: List.generate(
                  24,
                  (index) => DropdownMenuItem(
                    value: index + 1,
                    child: Text('${index + 1} ч'),
                  ),
                ),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _shiftHours = v;
                    if (_breakHours >= _shiftHours) {
                      _breakHours = _shiftHours - 1;
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _breakHours,
                decoration: const InputDecoration(
                  labelText: 'Перерыв',
                  border: OutlineInputBorder(),
                ),
                items: List.generate(
                  _shiftHours,
                  (i) => DropdownMenuItem<int>(
                    value: i,
                    child: Text('$i час(а)'),
                  ),
                ),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _breakHours = v);
                },
              ),
              if (widget.showAccessFields) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Учётная запись создастся автоматически вместе с сотрудником.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _loginController,
                          decoration: const InputDecoration(
                            labelText: 'Логин для входа',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _roleId,
                          decoration: const InputDecoration(
                            labelText: 'Роль',
                            border: OutlineInputBorder(),
                          ),
                          items: roles
                              .map(
                                (r) => DropdownMenuItem<String>(
                                  value: r.id,
                                  child: Text(r.name),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setState(() => _roleId = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Пароль будет сгенерирован автоматически в формате 6 букв + 4 цифры.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.onDeactivate != null) ...[
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: widget.onDeactivate,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.person_off_outlined),
                    label: const Text('Уволить сотрудника'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
