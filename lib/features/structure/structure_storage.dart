import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DepartmentModel {
  final String id;
  final String name;

  const DepartmentModel({required this.id, required this.name});

  DepartmentModel copyWith({String? name}) => DepartmentModel(
        id: id,
        name: name ?? this.name,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static DepartmentModel fromJson(Map json) => DepartmentModel(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
      );
}

class GroupModel {
  final String id;
  final String departmentId;
  final String name;

  const GroupModel({
    required this.id,
    required this.departmentId,
    required this.name,
  });

  GroupModel copyWith({String? departmentId, String? name}) => GroupModel(
        id: id,
        departmentId: departmentId ?? this.departmentId,
        name: name ?? this.name,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'departmentId': departmentId,
        'name': name,
      };

  static GroupModel fromJson(Map json) => GroupModel(
        id: json['id'] as String,
        departmentId: (json['departmentId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
      );
}

class StructureStorage {
  static const _departmentsFile = 'departments.json';
  static const _groupsFile = 'groups.json';

  Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<List<DepartmentModel>> loadDepartments() async {
    try {
      final f = await _file(_departmentsFile);
      if (!await f.exists()) return [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return [];
      final data = jsonDecode(text) as List;
      return data.map((e) => DepartmentModel.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDepartments(List<DepartmentModel> items) async {
    final f = await _file(_departmentsFile);
    await f.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  Future<List<GroupModel>> loadGroups() async {
    try {
      final f = await _file(_groupsFile);
      if (!await f.exists()) return [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return [];
      final data = jsonDecode(text) as List;
      return data.map((e) => GroupModel.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveGroups(List<GroupModel> items) async {
    final f = await _file(_groupsFile);
    await f.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }
}