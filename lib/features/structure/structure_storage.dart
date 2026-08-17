import '../../core/api_client.dart';

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
  Future<List<DepartmentModel>> loadDepartments() async {
    final data =
        await ApiClient.instance.request('GET', '/api/v1/departments') as List;
    return data.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      return DepartmentModel(
          id: json['id'] as String, name: json['name'] as String);
    }).toList();
  }

  Future<void> saveDepartments(List<DepartmentModel> items) async {
    final existing = {
      for (final item in await loadDepartments()) item.id: item
    };
    final wanted = {for (final item in items) item.id: item};
    for (final item in items) {
      await ApiClient.instance.request(
        existing.containsKey(item.id) ? 'PATCH' : 'POST',
        existing.containsKey(item.id)
            ? '/api/v1/departments/${item.id}'
            : '/api/v1/departments',
        body: {'id': item.id, 'name': item.name},
      );
    }
    for (final id in existing.keys.where((id) => !wanted.containsKey(id))) {
      await ApiClient.instance.request('DELETE', '/api/v1/departments/$id');
    }
  }

  Future<List<GroupModel>> loadGroups() async {
    final data =
        await ApiClient.instance.request('GET', '/api/v1/groups') as List;
    return data.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      return GroupModel(
        id: json['id'] as String,
        departmentId: json['department_id'] as String,
        name: json['name'] as String,
      );
    }).toList();
  }

  Future<void> saveGroups(List<GroupModel> items) async {
    final existing = {for (final item in await loadGroups()) item.id: item};
    final wanted = {for (final item in items) item.id: item};
    for (final item in items) {
      await ApiClient.instance.request(
        existing.containsKey(item.id) ? 'PATCH' : 'POST',
        existing.containsKey(item.id)
            ? '/api/v1/groups/${item.id}'
            : '/api/v1/groups',
        body: {
          'id': item.id,
          'department_id': item.departmentId,
          'name': item.name,
        },
      );
    }
    for (final id in existing.keys.where((id) => !wanted.containsKey(id))) {
      await ApiClient.instance.request('DELETE', '/api/v1/groups/$id');
    }
  }
}
