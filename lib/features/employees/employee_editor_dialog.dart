import 'package:flutter/material.dart';

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
  });
}

class EmployeeEditorDialog extends StatefulWidget {
  final EmployeeDraft? initial;
  final String title;
  final String confirmText;

  const EmployeeEditorDialog({
    super.key,
    this.initial,
    this.title = 'Добавить сотрудника',
    this.confirmText = 'Добавить',
  });

  @override
  State<EmployeeEditorDialog> createState() => _EmployeeEditorDialogState();
}

class _EmployeeEditorDialogState extends State<EmployeeEditorDialog> {
  final _structureStorage = StructureStorage();

  late final TextEditingController _nameController;
  late final TextEditingController _positionController;
  late final TextEditingController _salaryController;
  late final TextEditingController _bonusController;

  bool _loadingStructure = true;

  List<dynamic> _departments = <dynamic>[];
  List<dynamic> _groups = <dynamic>[];

  String? _departmentId;
  String? _groupId;

  late ScheduleType _scheduleType;
  late DateTime _scheduleStartDate;
  late int _shiftHours;
  late int _breakHours;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;

    _nameController = TextEditingController(text: init?.fullName ?? '');
    _positionController = TextEditingController(text: init?.position ?? '');
    _salaryController =
        TextEditingController(text: (init?.salary ?? 70000).toString());
    _bonusController =
        TextEditingController(text: (init?.bonus ?? 10000).toString());

    _departmentId = init?.departmentId;
    _groupId = init?.groupId;
    _scheduleType = init?.scheduleType ?? ScheduleType.twoTwo;
    _scheduleStartDate = init?.scheduleStartDate ?? DateTime.now();
    _shiftHours = init?.shiftHours ?? 12;
    _breakHours = init?.breakHours ?? 1;

    _loadStructure();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _positionController.dispose();
    _salaryController.dispose();
    _bonusController.dispose();
    super.dispose();
  }

  Future<void> _loadStructure() async {
    setState(() => _loadingStructure = true);

    final deps = await _structureStorage.loadDepartments();
    final groups = await _structureStorage.loadGroups();

    deps.sort((a, b) => a.name.compareTo(b.name));
    groups.sort((a, b) => a.name.compareTo(b.name));

    if (!mounted) return;

    setState(() {
      _departments = deps;
      _groups = groups;
      _loadingStructure = false;
    });

    _normalizeSelectedGroup();
  }

  int _parseInt(String s, {required int fallback}) {
    final v = int.tryParse(s.trim());
    return v ?? fallback;
  }

  void _normalizeSelectedGroup() {
    if (_groupId == null) return;
    final g = _groups.cast<dynamic?>().firstWhere(
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

  void _submit() {
    final name = _nameController.text.trim();
    final position = _positionController.text.trim();

    if (name.isEmpty || position.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполни ФИО и должность')),
      );
      return;
    }

    final salary = _parseInt(_salaryController.text, fallback: 0);
    final bonus = _parseInt(_bonusController.text, fallback: 0);

    if (_shiftHours <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Длительность смены должна быть больше 0')),
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

    Navigator.of(context).pop(
      EmployeeDraft(
        fullName: name,
        position: position,
        salary: salary,
        bonus: bonus,
        departmentId: _departmentId,
        groupId: _groupId,
        scheduleType: _scheduleType,
        scheduleStartDate: _scheduleStartDate,
        shiftHours: _shiftHours,
        breakHours: _breakHours,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupsForSelectedDepartment;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'ФИО'),
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: _positionController,
                decoration: const InputDecoration(labelText: 'Должность'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _salaryController,
                decoration: const InputDecoration(labelText: 'Оклад (₽)'),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
              ),
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
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _scheduleType = v);
                },
              ),
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
                items: const [
                  DropdownMenuItem(value: 9, child: Text('9 часов')),
                  DropdownMenuItem(value: 12, child: Text('12 часов')),
                ],
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