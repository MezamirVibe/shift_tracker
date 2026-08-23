import 'package:flutter/foundation.dart';

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
  final String? actualStart;
  final String? actualEnd;
  final String? updatedAt;

  const AttendanceRecord({
    required this.fact,
    this.comment,
    this.workedMinutes,
    this.actualStart,
    this.actualEnd,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'fact': factStatusToString(fact),
        if (comment != null && comment!.trim().isNotEmpty)
          'comment': comment!.trim(),
        if (workedMinutes != null) 'workedMinutes': workedMinutes,
        if (actualStart != null) 'actualStart': actualStart,
        if (actualEnd != null) 'actualEnd': actualEnd,
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
      actualStart:
          (json['actualStart'] as String?) ?? (json['actual_start'] as String?),
      actualEnd:
          (json['actualEnd'] as String?) ?? (json['actual_end'] as String?),
      updatedAt: json['updatedAt'] as String?,
    );
  }
}

class _AttendanceCacheEntry {
  final DateTime loadedAt;
  final String userId;
  final DateTime from;
  final DateTime to;
  final Map<String, dynamic> data;

  const _AttendanceCacheEntry({
    required this.loadedAt,
    required this.userId,
    required this.from,
    required this.to,
    required this.data,
  });
}

/// dateIso (yyyy-mm-dd) -> employeeId -> AttendanceRecord json
/// + служебный ключ "_meta": { closed: bool, closedAt: iso, reopenedAt?: iso }
class AttendanceStorage {
  static const _metaKey = '_meta';
  static const _cacheLifetime = Duration(minutes: 5);
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static final Map<String, _AttendanceCacheEntry> _rangeCache = {};
  static final Map<String, Future<Map<String, dynamic>>> _rangeInFlight = {};
  static int _cacheGeneration = 0;

  void _markChanged() {
    _cacheGeneration++;
    _rangeCache.clear();
    _rangeInFlight.clear();
    changes.value++;
  }

  String _iso(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  Future<Map<String, dynamic>> loadRange(
    DateTime from,
    DateTime to, {
    bool force = false,
  }) {
    final userId = ApiClient.instance.currentUser?['id'] as String? ?? 'none';
    final key = '$userId|${_iso(from)}|${_iso(to)}';
    final cached = _rangeCache[key];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.loadedAt) < _cacheLifetime) {
      return Future.value(Map<String, dynamic>.from(cached.data));
    }
    if (!force) {
      for (final candidate in _rangeCache.values) {
        final fresh =
            DateTime.now().difference(candidate.loadedAt) < _cacheLifetime;
        final coversRange = !from.isBefore(candidate.from) &&
            !to.isAfter(candidate.to) &&
            candidate.userId == userId;
        if (fresh && coversRange) {
          final startIso = _iso(from);
          final endIso = _iso(to);
          return Future.value({
            for (final entry in candidate.data.entries)
              if (entry.key.compareTo(startIso) >= 0 &&
                  entry.key.compareTo(endIso) <= 0)
                entry.key: entry.value,
          });
        }
      }
    }

    final active = _rangeInFlight[key];
    if (active != null) {
      return active.then(Map<String, dynamic>.from);
    }

    final generation = _cacheGeneration;
    final request = _loadRangeRemote(from, to).then((data) {
      if (generation == _cacheGeneration) {
        _rangeCache[key] = _AttendanceCacheEntry(
          loadedAt: DateTime.now(),
          userId: userId,
          from: from,
          to: to,
          data: Map<String, dynamic>.from(data),
        );
      }
      return data;
    });
    _rangeInFlight[key] = request;
    return request.whenComplete(() {
      if (identical(_rangeInFlight[key], request)) {
        _rangeInFlight.remove(key);
      }
    });
  }

  Future<Map<String, dynamic>> _loadRangeRemote(
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

  /// Служебный полный диапазон. Не используйте для чтения одного дня:
  /// на сервере это одиннадцать лет данных.
  Future<Map<String, dynamic>> loadAllRaw() async {
    final year = DateTime.now().year;
    return loadRange(
      DateTime(year - 5, 1, 1),
      DateTime(year + 5, 12, 31),
    );
  }

  Future<({Map<String, AttendanceRecord> records, bool closed})> loadDay(
    String dateIso, {
    bool force = false,
  }) async {
    final all = await loadRange(
      DateTime.parse(dateIso),
      DateTime.parse(dateIso),
      force: force,
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
    final day = await loadDay(dateIso);
    return day.closed;
  }

  /// Записи факта по дню (без _meta)
  Future<Map<String, AttendanceRecord>> loadDayRecords(String dateIso) async {
    final day = await loadDay(dateIso);
    return day.records;
  }

  Future<void> setFact({
    required String dateIso,
    required String employeeId,
    required FactStatus fact,
    String? comment,
    int? workedMinutes,
    String? actualStart,
    String? actualEnd,
  }) async {
    await ApiClient.instance.request(
      'PUT',
      '/api/v1/attendance/$dateIso/$employeeId',
      body: {
        'fact': factStatusToString(fact),
        'comment': comment,
        'worked_minutes': workedMinutes,
        'actual_start': actualStart,
        'actual_end': actualEnd,
      },
    );
    _markChanged();
  }

  Future<void> setFacts({
    required String dateIso,
    required Map<String, AttendanceRecord> recordsByEmployeeId,
  }) async {
    if (recordsByEmployeeId.isEmpty) return;
    await ApiClient.instance.request(
      'PUT',
      '/api/v1/attendance/$dateIso',
      body: {
        'records': [
          for (final entry in recordsByEmployeeId.entries)
            {
              'employee_id': entry.key,
              'fact': factStatusToString(entry.value.fact),
              'comment': entry.value.comment,
              'worked_minutes': entry.value.workedMinutes,
              'actual_start': entry.value.actualStart,
              'actual_end': entry.value.actualEnd,
            },
        ],
      },
    );
    _markChanged();
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
    _markChanged();
  }

  Future<void> reopenDay({required String dateIso}) async {
    await ApiClient.instance.request(
      'POST',
      '/api/v1/attendance/$dateIso/reopen',
    );
    _markChanged();
  }
}
