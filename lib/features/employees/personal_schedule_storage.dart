import '../../core/api_client.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'employees_storage.dart';

class PersonalScheduleStorage {
  static bool get applies {
    final auth = AuthService.instance;
    return auth.roleById(auth.currentUser?.roleId)?.scopeKind == ScopeKind.self;
  }

  static Future<
          ({List<EmployeeModel> employees, Map<String, dynamic> attendance})>
      load(DateTime from, DateTime to) async {
    String iso(DateTime date) => date.toIso8601String().split('T').first;
    final data = await ApiClient.instance.request('GET',
            '/api/v1/self/schedule?date_from=${iso(from)}&date_to=${iso(to)}')
        as Map;
    final e = data['employee'] as Map;
    final employee = EmployeeModel(
      id: e['id'] as String,
      fullName: e['full_name'] as String,
      position: e['position_name'] as String? ?? '',
      positionId: e['position_id'] as String?,
      salary: 0,
      bonus: 0,
      departmentId: e['department_id'] as String?,
      groupId: e['group_id'] as String?,
      scheduleType: scheduleTypeFromString(e['schedule_type'] as String?),
      scheduleStartDate: DateTime.parse(e['schedule_start_date'] as String),
      shiftHours: (e['shift_hours'] as num).toInt(),
      breakHours: (e['break_hours'] as num).toInt(),
      customWorkdays: (e['custom_workdays'] as List)
          .map((v) => (v as num).toInt())
          .toList(),
    );
    return (
      employees: [employee],
      attendance: Map<String, dynamic>.from(data['attendance'] as Map)
    );
  }
}
