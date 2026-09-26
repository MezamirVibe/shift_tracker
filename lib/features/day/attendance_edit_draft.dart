import '../attendance/attendance_storage.dart';

/// Opening a record must not infer new hours or fabricate actual clock times.
class AttendanceEditDraft {
  final AttendanceRecord? original;
  final int defaultMinutes;
  bool timesChanged = false;

  AttendanceEditDraft({required this.original, required this.defaultMinutes});

  AttendanceRecord build({
    required FactStatus fact,
    required bool tripHasHours,
    required int calculatedMinutes,
    required String actualStart,
    required String actualEnd,
    int? manualMinutes,
    String? comment,
  }) {
    final saveHours =
        fact.mayHaveHours && (fact != FactStatus.businessTrip || tripHasHours);
    final previous = original;
    final keepOriginal =
        !timesChanged &&
        previous != null &&
        previous.fact.mayHaveHours &&
        (previous.fact != FactStatus.businessTrip || previous.hasWorked) &&
        (fact != FactStatus.vacationWorked || previous.hasWorked);
    return AttendanceRecord(
      fact: fact,
      comment: comment,
      workedMinutes: !saveHours
          ? 0
          : manualMinutes ??
                (timesChanged
                    ? calculatedMinutes
                    : keepOriginal
                    ? previous.workedMinutes ?? defaultMinutes
                    : defaultMinutes),
      actualStart: !saveHours
          ? null
          : timesChanged
          ? actualStart
          : keepOriginal
          ? previous.actualStart
          : null,
      actualEnd: !saveHours
          ? null
          : timesChanged
          ? actualEnd
          : keepOriginal
          ? previous.actualEnd
          : null,
      updatedAt: previous?.updatedAt,
      closed: previous?.closed ?? false,
    );
  }
}
