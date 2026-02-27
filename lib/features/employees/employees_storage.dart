import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Тип графика (пока минимум)
enum ScheduleType {
  twoTwo, // 2/2
  fiveTwo, // 5/2
}

ScheduleType scheduleTypeFromString(String? s) {
  switch (s) {
    case 'fiveTwo':
      return ScheduleType.fiveTwo;
    case 'twoTwo':
    default:
      return ScheduleType.twoTwo;
  }
}

String scheduleTypeToString(ScheduleType t) => t.name;

class EmployeeModel {
  final String id;
  final String fullName;
  final String position;
  final int salary;
  final int bonus;

  /// NEW: структура
  final String? departmentId;
  final String? groupId;

  /// график
  final ScheduleType scheduleType;
  final DateTime scheduleStartDate; // дата первой смены
  final int shiftHours; // 9 или 12
  final int breakHours; // 1

  EmployeeModel({
    required this.id,
    required this.fullName,
    required this.position,
    required this.salary,
    required this.bonus,
    this.departmentId,
    this.groupId,
    this.scheduleType = ScheduleType.twoTwo,
    DateTime? scheduleStartDate,
    this.shiftHours = 12,
    this.breakHours = 1,
  }) : scheduleStartDate = scheduleStartDate ?? DateTime.now();

  EmployeeModel copyWith({
    String? id,
    String? fullName,
    String? position,
    int? salary,
    int? bonus,
    String? departmentId,
    String? groupId,
    ScheduleType? scheduleType,
    DateTime? scheduleStartDate,
    int? shiftHours,
    int? breakHours,
    bool clearDepartment = false,
    bool clearGroup = false,
  }) {
    return EmployeeModel(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      position: position ?? this.position,
      salary: salary ?? this.salary,
      bonus: bonus ?? this.bonus,
      departmentId:
          clearDepartment ? null : (departmentId ?? this.departmentId),
      groupId: clearGroup ? null : (groupId ?? this.groupId),
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleStartDate: scheduleStartDate ?? this.scheduleStartDate,
      shiftHours: shiftHours ?? this.shiftHours,
      breakHours: breakHours ?? this.breakHours,
    );
  }

  int get paidShiftHours => (shiftHours - breakHours).clamp(0, 24);

  Map<String, dynamic> toJson() => {
        'id': id,
        'fullName': fullName,
        'position': position,
        'salary': salary,
        'bonus': bonus,

        // structure
        'departmentId': departmentId,
        'groupId': groupId,

        // schedule
        'scheduleType': scheduleTypeToString(scheduleType),
        'scheduleStartDate': scheduleStartDate.toIso8601String(),
        'shiftHours': shiftHours,
        'breakHours': breakHours,
      };

  static EmployeeModel fromJson(Map json) {
    // миграция графика
    final scheduleType =
        scheduleTypeFromString(json['scheduleType'] as String?);

    DateTime startDate;
    final startRaw = json['scheduleStartDate'];
    if (startRaw is String && startRaw.trim().isNotEmpty) {
      startDate = DateTime.tryParse(startRaw) ?? DateTime.now();
    } else {
      startDate = DateTime.now();
    }

    final shiftHours =
        (json['shiftHours'] is num) ? (json['shiftHours'] as num).toInt() : 12;
    final breakHours =
        (json['breakHours'] is num) ? (json['breakHours'] as num).toInt() : 1;

    // миграция структуры
    final depId = (json['departmentId'] as String?)?.trim();
    final grpId = (json['groupId'] as String?)?.trim();

    return EmployeeModel(
      id: json['id'] as String,
      fullName: json['fullName'] as String,
      position: json['position'] as String,
      salary: (json['salary'] as num).toInt(),
      bonus: (json['bonus'] as num).toInt(),
      departmentId: (depId == null || depId.isEmpty) ? null : depId,
      groupId: (grpId == null || grpId.isEmpty) ? null : grpId,
      scheduleType: scheduleType,
      scheduleStartDate: startDate,
      shiftHours: shiftHours,
      breakHours: breakHours,
    );
  }
}

class EmployeesStorage {
  static const _fileName = 'employees.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<List<EmployeeModel>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return [];
      final data = jsonDecode(text) as List;
      return data.map((e) => EmployeeModel.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<EmployeeModel> employees) async {
    final f = await _file();
    final text = jsonEncode(employees.map((e) => e.toJson()).toList());
    await f.writeAsString(text);
  }
}
