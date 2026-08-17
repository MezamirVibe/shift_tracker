import '../../core/api_client.dart';

/// Факт по дню
enum FactStatus {
  none, // факт не отмечен
  worked, // вышел
  absent, // прогул
  sick, // больничный
  vacation, // отпуск
}

FactStatus factStatusFromString(String? s) {
  switch (s) {
    case 'worked':
      return FactStatus.worked;
    case 'absent':
      return FactStatus.absent;
    case 'sick':
      return FactStatus.sick;
    case 'vacation':
      return FactStatus.vacation;

    // миграция со старых значений:
    case 'present':
      return FactStatus.worked;
    case 'planned':
      return FactStatus.none;

    case 'none':
    default:
      return FactStatus.none;
  }
}

String factStatusToString(FactStatus s) => s.name;

class AttendanceRecord {
  final FactStatus fact;
  final String? comment;
  final int? workedMinutes;
  final String? updatedAt;

  const AttendanceRecord({
    required this.fact,
    this.comment,
    this.workedMinutes,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'fact': factStatusToString(fact),
        if (comment != null && comment!.trim().isNotEmpty)
          'comment': comment!.trim(),
        if (workedMinutes != null) 'workedMinutes': workedMinutes,
        'updatedAt': updatedAt ?? DateTime.now().toIso8601String(),
      };

  /// поддерживает старый формат:
  /// { status: planned/present/absent, note?, updatedAt }
  static AttendanceRecord fromJson(Map<String, dynamic> json) {
    // Новый ключ
    final fact = factStatusFromString(json['fact'] as String?);

    // Старый ключ status
    final oldStatus = json['status'] as String?;
    final migratedFact =
        oldStatus != null ? factStatusFromString(oldStatus) : fact;

    // comment / note
    final comment = (json['comment'] as String?) ?? (json['note'] as String?);

    final workedMinutes =
        (json['workedMinutes'] is int) ? json['workedMinutes'] as int : null;

    return AttendanceRecord(
      fact: migratedFact,
      comment: comment,
      workedMinutes: workedMinutes,
      updatedAt: json['updatedAt'] as String?,
    );
  }
}

/// dateIso (yyyy-mm-dd) -> employeeId -> AttendanceRecord json
/// + служебный ключ "_meta": { closed: bool, closedAt: iso, reopenedAt?: iso }
class AttendanceStorage {
  static const _metaKey = '_meta';

  String _iso(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  Future<Map<String, dynamic>> loadRange(
    DateTime from,
    DateTime to,
  ) async {
    final data = await ApiClient.instance.request(
      'GET',
      '/api/v1/attendance?date_from=${_iso(from)}&date_to=${_iso(to)}',
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> loadMonth(int year, int month) {
    return loadRange(
      DateTime(year, month, 1),
      DateTime(year, month + 1, 0),
    );
  }

  /// Публично: читаем весь raw, чтобы календарь мог быстро посчитать месяц (без 31 чтения файла)
  Future<Map<String, dynamic>> loadAllRaw() async {
    final year = DateTime.now().year;
    final data = await ApiClient.instance.request(
      'GET',
      '/api/v1/attendance?date_from=${year - 5}-01-01&date_to=${year + 5}-12-31',
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<({Map<String, AttendanceRecord> records, bool closed})> loadDay(
    String dateIso,
  ) async {
    final all = await loadRange(
      DateTime.parse(dateIso),
      DateTime.parse(dateIso),
    );
    final rawDay = all[dateIso];
    if (rawDay is! Map) {
      return (records: <String, AttendanceRecord>{}, closed: false);
    }

    final day = Map<String, dynamic>.from(rawDay);
    final records = <String, AttendanceRecord>{};
    for (final entry in day.entries) {
      if (entry.key == _metaKey) continue;
      final value = entry.value;
      if (value is Map) {
        records[entry.key] =
            AttendanceRecord.fromJson(Map<String, dynamic>.from(value));
      }
    }
    return (records: records, closed: _isClosedFromDayMap(day));
  }

  bool _isClosedFromDayMap(Map<String, dynamic> day) {
    final meta = day[_metaKey];
    if (meta is Map<String, dynamic>) {
      return meta['closed'] == true;
    }
    return false;
  }

  Future<bool> isDayClosed(String dateIso) async {
    final all = await loadAllRaw();
    final day = all[dateIso];
    if (day is Map<String, dynamic>) {
      return _isClosedFromDayMap(day);
    }
    return false;
  }

  /// Записи факта по дню (без _meta)
  Future<Map<String, AttendanceRecord>> loadDayRecords(String dateIso) async {
    final all = await loadAllRaw();
    final day = all[dateIso];
    if (day is! Map<String, dynamic>) return {};

    final out = <String, AttendanceRecord>{};
    for (final entry in day.entries) {
      if (entry.key == _metaKey) continue;
      final employeeId = entry.key;
      final rec = entry.value;
      if (rec is Map<String, dynamic>) {
        out[employeeId] = AttendanceRecord.fromJson(rec);
      }
    }
    return out;
  }

  Future<void> setFact({
    required String dateIso,
    required String employeeId,
    required FactStatus fact,
    String? comment,
    int? workedMinutes,
  }) async {
    await ApiClient.instance.request(
      'PUT',
      '/api/v1/attendance/$dateIso/$employeeId',
      body: {
        'fact': factStatusToString(fact),
        'comment': comment,
        'worked_minutes': workedMinutes,
      },
    );
  }

  /// Закрыть день:
  /// - всем сотрудникам из списка plannedEmployeeIds:
  ///   - если записи нет или fact == none -> ставим absent
  /// - записываем meta.closed = true
  Future<void> closeDay({
    required String dateIso,
    required List<String> plannedEmployeeIds,
  }) async {
    await ApiClient.instance.request(
      'POST',
      '/api/v1/attendance/$dateIso/close',
      body: {'planned_employee_ids': plannedEmployeeIds},
    );
  }

  Future<void> reopenDay({required String dateIso}) async {
    await ApiClient.instance.request(
      'POST',
      '/api/v1/attendance/$dateIso/reopen',
    );
  }
}
