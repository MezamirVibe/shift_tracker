import 'package:flutter/material.dart';

class EmployeeDraft {
  final String fullName;
  final String position;
  final int salary;
  final int bonus;

  const EmployeeDraft({
    required this.fullName,
    required this.position,
    required this.salary,
    required this.bonus,
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
  late final TextEditingController _nameController;
  late final TextEditingController _positionController;
  late final TextEditingController _salaryController;
  late final TextEditingController _bonusController;

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _positionController.dispose();
    _salaryController.dispose();
    _bonusController.dispose();
    super.dispose();
  }

  int _parseInt(String s) => int.tryParse(s.trim()) ?? 0;

  void _submit() {
    final name = _nameController.text.trim();
    final position = _positionController.text.trim();

    if (name.isEmpty || position.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполни ФИО и должность')),
      );
      return;
    }

    Navigator.of(context).pop(
      EmployeeDraft(
        fullName: name,
        position: position,
        salary: _parseInt(_salaryController.text),
        bonus: _parseInt(_bonusController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
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
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
          ],
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
