import '../../core/api_client.dart';
import '../../core/id.dart';

/// Тип графика (пока минимум)
enum ScheduleType {
  twoTwo, // 2/2
  fiveTwo, // 5/2
  custom, // произвольные дни недели
}

ScheduleType scheduleTypeFromString(String? s) {
  switch (s) {
    case 'fiveTwo':
      return ScheduleType.fiveTwo;
    case 'custom':
      return ScheduleType.custom;
    case 'twoTwo':
    default:
      return ScheduleType.twoTwo;
  }
}

String scheduleTypeToString(ScheduleType t) => t.name;

String scheduleTypeLabel(ScheduleType type) => switch (type) {
      ScheduleType.twoTwo => '2/2',
      ScheduleType.fiveTwo => '5/2',
      ScheduleType.custom => 'Произвольный',
    };

class EmployeeModel {
  final String id;
  final String fullName;
  final String position;
  final String? positionId;
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
  final List<int> customWorkdays; // 1..7, понедельник..воскресенье

  EmployeeModel({
    required this.id,
    required this.fullName,
    required this.position,
    this.positionId,
    required this.salary,
    required this.bonus,
    this.departmentId,
    this.groupId,
    this.scheduleType = ScheduleType.twoTwo,
    DateTime? scheduleStartDate,
    this.shiftHours = 12,
    this.breakHours = 1,
    this.customWorkdays = const [1, 2, 3, 4, 5],
  }) : scheduleStartDate = scheduleStartDate ?? DateTime.now();

  EmployeeModel copyWith({
    String? id,
    String? fullName,
    String? position,
    String? positionId,
    int? salary,
    int? bonus,
    String? departmentId,
    String? groupId,
    ScheduleType? scheduleType,
    DateTime? scheduleStartDate,
    int? shiftHours,
    int? breakHours,
    List<int>? customWorkdays,
    bool clearDepartment = false,
    bool clearGroup = false,
  }) {
    return EmployeeModel(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      position: position ?? this.position,
      positionId: positionId ?? this.positionId,
      salary: salary ?? this.salary,
      bonus: bonus ?? this.bonus,
      departmentId:
          clearDepartment ? null : (departmentId ?? this.departmentId),
      groupId: clearGroup ? null : (groupId ?? this.groupId),
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleStartDate: scheduleStartDate ?? this.scheduleStartDate,
      shiftHours: shiftHours ?? this.shiftHours,
      breakHours: breakHours ?? this.breakHours,
      customWorkdays: customWorkdays ?? this.customWorkdays,
    );
  }

  int get paidShiftHours => (shiftHours - breakHours).clamp(0, 24);

  Map<String, dynamic> toJson() => {
        'id': id,
        'fullName': fullName,
        'position': position,
        'positionId': positionId,
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
        'customWorkdays': customWorkdays,
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
    final customWorkdays = (json['customWorkdays'] as List?)
            ?.whereType<num>()
            .map((day) => day.toInt())
            .toList() ??
        const [1, 2, 3, 4, 5];

    // миграция структуры
    final depId = (json['departmentId'] as String?)?.trim();
    final grpId = (json['groupId'] as String?)?.trim();

    return EmployeeModel(
      id: json['id'] as String,
      fullName: json['fullName'] as String,
      position: json['position'] as String,
      positionId: json['positionId'] as String?,
      salary: (json['salary'] as num).toInt(),
      bonus: (json['bonus'] as num).toInt(),
      departmentId: (depId == null || depId.isEmpty) ? null : depId,
      groupId: (grpId == null || grpId.isEmpty) ? null : grpId,
      scheduleType: scheduleType,
      scheduleStartDate: startDate,
      shiftHours: shiftHours,
      breakHours: breakHours,
      customWorkdays: customWorkdays,
    );
  }
}

class EmployeesStorage {
  static List<EmployeeModel>? _cachedEmployees;
  static DateTime? _cachedAt;
  static Future<List<EmployeeModel>>? _loadInFlight;

  Future<List<EmployeeModel>> load({bool force = false}) {
    final cached = _cachedEmployees;
    final cachedAt = _cachedAt;
    if (!force &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 20)) {
      return Future.value(List<EmployeeModel>.of(cached));
    }

    final active = _loadInFlight;
    if (!force && active != null) {
      return active.then(List<EmployeeModel>.of);
    }

    final future = _loadAndCache();
    _loadInFlight = future;
    return future;
  }

  Future<List<EmployeeModel>> _loadAndCache() async {
    try {
      final loaded = await _loadRemote();
      _cachedEmployees = List<EmployeeModel>.unmodifiable(loaded);
      _cachedAt = DateTime.now();
      return List<EmployeeModel>.of(loaded);
    } finally {
      _loadInFlight = null;
    }
  }

  Future<List<EmployeeModel>> _loadRemote() async {
    final api = ApiClient.instance;
    final results = await Future.wait([
      api.request('GET', '/api/v1/employees'),
      api.request('GET', '/api/v1/positions'),
    ]);
    final positions = <String, String>{};
    for (final item in (results[1] as List).whereType<Map>()) {
      final json = Map<String, dynamic>.from(item);
      positions[json['id'] as String] = json['name'] as String;
    }
    return (results[0] as List).whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      final positionId = json['position_id'] as String?;
      return EmployeeModel(
        id: json['id'] as String,
        fullName: json['full_name'] as String,
        position: positionId == null ? '' : (positions[positionId] ?? ''),
        positionId: positionId,
        salary: (json['salary'] as num).toInt(),
        bonus: (json['bonus'] as num).toInt(),
        departmentId: json['department_id'] as String?,
        groupId: json['group_id'] as String?,
        scheduleType: scheduleTypeFromString(json['schedule_type'] as String?),
        scheduleStartDate:
            DateTime.parse(json['schedule_start_date'] as String),
        shiftHours: (json['shift_hours'] as num).toInt(),
        breakHours: (json['break_hours'] as num).toInt(),
        customWorkdays: (json['custom_workdays'] as List?)
                ?.whereType<num>()
                .map((day) => day.toInt())
                .toList() ??
            const [1, 2, 3, 4, 5],
      );
    }).toList();
  }

  Future<String?> _resolvePositionId(EmployeeModel employee) async {
    final positionName = employee.position.trim();
    if (positionName.isEmpty) return null;

    final positionData =
        await ApiClient.instance.request('GET', '/api/v1/positions') as List;
    for (final item in positionData.whereType<Map>()) {
      final json = Map<String, dynamic>.from(item);
      if ((json['name'] as String).trim().toLowerCase() ==
          positionName.toLowerCase()) {
        return json['id'] as String;
      }
    }

    final positionId = newUuidV4();
    await ApiClient.instance.request(
      'POST',
      '/api/v1/positions',
      body: {'id': positionId, 'name': positionName},
    );
    return positionId;
  }

  Map<String, dynamic> _body(
    EmployeeModel employee,
    String? positionId, {
    required bool includeId,
  }) {
    return {
      if (includeId) 'id': employee.id,
      'full_name': employee.fullName,
      'position_id': positionId,
      'department_id': employee.departmentId,
      'group_id': employee.groupId,
      'salary': employee.salary,
      'bonus': employee.bonus,
      'schedule_type': scheduleTypeToString(employee.scheduleType),
      'schedule_start_date':
          employee.scheduleStartDate.toIso8601String().split('T').first,
      'shift_hours': employee.shiftHours,
      'break_hours': employee.breakHours,
      'custom_workdays': employee.customWorkdays,
    };
  }

  Future<void> create(EmployeeModel employee) async {
    final positionId = await _resolvePositionId(employee);
    await ApiClient.instance.request(
      'POST',
      '/api/v1/employees',
      body: _body(employee, positionId, includeId: true),
    );
    _invalidateCache();
  }

  Future<void> update(EmployeeModel employee) async {
    final positionId = await _resolvePositionId(employee);
    await ApiClient.instance.request(
      'PATCH',
      '/api/v1/employees/${employee.id}',
      body: _body(employee, positionId, includeId: false),
    );
    _invalidateCache();
  }

  Future<void> deactivate(String employeeId) async {
    await ApiClient.instance.request(
      'DELETE',
      '/api/v1/employees/$employeeId',
    );
    _invalidateCache();
  }

  void _invalidateCache() {
    _cachedEmployees = null;
    _cachedAt = null;
  }

  Future<void> save(List<EmployeeModel> employees) async {
    final api = ApiClient.instance;
    final existing = {for (final item in await load()) item.id: item};
    final wanted = {for (final item in employees) item.id: item};
    final positionData = await api.request('GET', '/api/v1/positions') as List;
    final positionsByName = <String, String>{};
    for (final item in positionData.whereType<Map>()) {
      final json = Map<String, dynamic>.from(item);
      positionsByName[(json['name'] as String).trim().toLowerCase()] =
          json['id'] as String;
    }

    for (final employee in employees) {
      var positionId = employee.positionId;
      final positionName = employee.position.trim();
      if (positionName.isNotEmpty) {
        positionId = positionsByName[positionName.toLowerCase()];
        if (positionId == null) {
          positionId = newUuidV4();
          await api.request(
            'POST',
            '/api/v1/positions',
            body: {'id': positionId, 'name': positionName},
          );
          positionsByName[positionName.toLowerCase()] = positionId;
        }
      }
      final body = {
        if (!existing.containsKey(employee.id)) 'id': employee.id,
        'full_name': employee.fullName,
        'position_id': positionId,
        'department_id': employee.departmentId,
        'group_id': employee.groupId,
        'salary': employee.salary,
        'bonus': employee.bonus,
        'schedule_type': scheduleTypeToString(employee.scheduleType),
        'schedule_start_date':
            employee.scheduleStartDate.toIso8601String().split('T').first,
        'shift_hours': employee.shiftHours,
        'break_hours': employee.breakHours,
        'custom_workdays': employee.customWorkdays,
      };
      await api.request(
        existing.containsKey(employee.id) ? 'PATCH' : 'POST',
        existing.containsKey(employee.id)
            ? '/api/v1/employees/${employee.id}'
            : '/api/v1/employees',
        body: body,
      );
    }
    for (final id in existing.keys.where((id) => !wanted.containsKey(id))) {
      await api.request('DELETE', '/api/v1/employees/$id');
    }
    _invalidateCache();
  }
}
