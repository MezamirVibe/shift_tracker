import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
        if (comment != null && comment!.trim().isNotEmpty) 'comment': comment!.trim(),
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
    final migratedFact = oldStatus != null ? factStatusFromString(oldStatus) : fact;

    // comment / note
    final comment = (json['comment'] as String?) ?? (json['note'] as String?);

    final workedMinutes = (json['workedMinutes'] is int) ? json['workedMinutes'] as int : null;

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
  static const _fileName = 'attendance.json';
  static const _metaKey = '_meta';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Публично: читаем весь raw, чтобы календарь мог быстро посчитать месяц (без 31 чтения файла)
  Future<Map<String, dynamic>> loadAllRaw() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final text = await f.readAsString();
      if (text.trim().isEmpty) return {};
      final data = jsonDecode(text);
      if (data is Map<String, dynamic>) return data;
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveAllRaw(Map<String, dynamic> raw) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(raw));
  }

  Map<String, dynamic> _ensureDay(Map<String, dynamic> all, String dateIso) {
    final existing = all[dateIso];
    if (existing is Map<String, dynamic>) return existing;
    final created = <String, dynamic>{};
    all[dateIso] = created;
    return created;
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
    final all = await loadAllRaw();
    final day = _ensureDay(all, dateIso);

    day[employeeId] = AttendanceRecord(
      fact: fact,
      comment: comment,
      workedMinutes: workedMinutes,
      updatedAt: DateTime.now().toIso8601String(),
    ).toJson();

    await _saveAllRaw(all);
  }

  /// Закрыть день:
  /// - всем сотрудникам из списка plannedEmployeeIds:
  ///   - если записи нет или fact == none -> ставим absent
  /// - записываем meta.closed = true
  Future<void> closeDay({
    required String dateIso,
    required List<String> plannedEmployeeIds,
  }) async {
    final all = await loadAllRaw();
    final day = _ensureDay(all, dateIso);

    for (final id in plannedEmployeeIds) {
      final rec = day[id];

      if (rec is Map<String, dynamic>) {
        final r = AttendanceRecord.fromJson(rec);
        if (r.fact == FactStatus.none) {
          day[id] = AttendanceRecord(
            fact: FactStatus.absent,
            comment: r.comment,
            workedMinutes: 0,
            updatedAt: DateTime.now().toIso8601String(),
          ).toJson();
        } else {
          // норм — оставляем как есть
          // (но можно подправить workedMinutes если пусто — не делаем автоматически)
        }
      } else {
        day[id] = AttendanceRecord(
          fact: FactStatus.absent,
          workedMinutes: 0,
          updatedAt: DateTime.now().toIso8601String(),
        ).toJson();
      }
    }

    day[_metaKey] = <String, dynamic>{
      'closed': true,
      'closedAt': DateTime.now().toIso8601String(),
    };

    await _saveAllRaw(all);
  }

  Future<void> reopenDay({required String dateIso}) async {
    final all = await loadAllRaw();
    final day = all[dateIso];
    if (day is! Map<String, dynamic>) return;

    final meta = day[_metaKey];
    if (meta is Map<String, dynamic>) {
      day[_metaKey] = <String, dynamic>{
        ...meta,
        'closed': false,
        'reopenedAt': DateTime.now().toIso8601String(),
      };
    } else {
      day[_metaKey] = <String, dynamic>{
        'closed': false,
        'reopenedAt': DateTime.now().toIso8601String(),
      };
    }

    all[dateIso] = day;
    await _saveAllRaw(all);
  }
}
