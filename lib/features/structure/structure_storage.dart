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
  static const _cacheLifetime = Duration(seconds: 20);
  static List<DepartmentModel>? _departmentsCache;
  static DateTime? _departmentsCachedAt;
  static Future<List<DepartmentModel>>? _departmentsInFlight;
  static List<GroupModel>? _groupsCache;
  static DateTime? _groupsCachedAt;
  static Future<List<GroupModel>>? _groupsInFlight;
  static String? _cacheUserId;

  void _ensureCacheOwner() {
    final userId = ApiClient.instance.currentUser?['id'] as String?;
    if (_cacheUserId == userId) return;
    _cacheUserId = userId;
    _departmentsCache = null;
    _departmentsCachedAt = null;
    _departmentsInFlight = null;
    _groupsCache = null;
    _groupsCachedAt = null;
    _groupsInFlight = null;
  }

  bool _isFresh(DateTime? cachedAt) =>
      cachedAt != null && DateTime.now().difference(cachedAt) < _cacheLifetime;

  Future<List<DepartmentModel>> loadDepartments({bool force = false}) async {
    _ensureCacheOwner();
    if (!force && _departmentsCache != null && _isFresh(_departmentsCachedAt)) {
      return List<DepartmentModel>.of(_departmentsCache!);
    }
    if (!force && _departmentsInFlight != null) {
      return List<DepartmentModel>.of(await _departmentsInFlight!);
    }

    final owner = _cacheUserId;
    final request = _loadDepartmentsRemote();
    _departmentsInFlight = request;
    try {
      final items = await request;
      if (_cacheUserId == owner) {
        _departmentsCache = List<DepartmentModel>.of(items);
        _departmentsCachedAt = DateTime.now();
      }
      return List<DepartmentModel>.of(items);
    } finally {
      if (identical(_departmentsInFlight, request)) {
        _departmentsInFlight = null;
      }
    }
  }

  Future<List<DepartmentModel>> _loadDepartmentsRemote() async {
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
    _departmentsCache = null;
    _departmentsCachedAt = null;
  }

  Future<List<GroupModel>> loadGroups({bool force = false}) async {
    _ensureCacheOwner();
    if (!force && _groupsCache != null && _isFresh(_groupsCachedAt)) {
      return List<GroupModel>.of(_groupsCache!);
    }
    if (!force && _groupsInFlight != null) {
      return List<GroupModel>.of(await _groupsInFlight!);
    }

    final owner = _cacheUserId;
    final request = _loadGroupsRemote();
    _groupsInFlight = request;
    try {
      final items = await request;
      if (_cacheUserId == owner) {
        _groupsCache = List<GroupModel>.of(items);
        _groupsCachedAt = DateTime.now();
      }
      return List<GroupModel>.of(items);
    } finally {
      if (identical(_groupsInFlight, request)) {
        _groupsInFlight = null;
      }
    }
  }

  Future<List<GroupModel>> _loadGroupsRemote() async {
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
    _groupsCache = null;
    _groupsCachedAt = null;
  }
}
