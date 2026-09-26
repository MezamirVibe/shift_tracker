class AttendanceDeviation {
  final int lateMinutes;
  final int earlyLeaveMinutes;
  final int overtimeMinutes;

  const AttendanceDeviation({
    required this.lateMinutes,
    required this.earlyLeaveMinutes,
    required this.overtimeMinutes,
  });

  bool get hasDeviations =>
      lateMinutes > 0 || earlyLeaveMinutes > 0 || overtimeMinutes > 0;
}

AttendanceDeviation calculateAttendanceDeviation({
  required int plannedStartMinutes,
  required int plannedEndMinutes,
  required int actualStartMinutes,
  required int actualEndMinutes,
}) {
  var normalizedPlannedEnd = plannedEndMinutes;
  if (normalizedPlannedEnd <= plannedStartMinutes) {
    normalizedPlannedEnd += 24 * 60;
  }

  var normalizedActualStart = actualStartMinutes;
  var normalizedActualEnd = actualEndMinutes;
  if (normalizedActualEnd <= normalizedActualStart) {
    normalizedActualEnd += 24 * 60;
  }
  if (normalizedActualStart < plannedStartMinutes - 12 * 60) {
    normalizedActualStart += 24 * 60;
  }

  return AttendanceDeviation(
    lateMinutes:
        (normalizedActualStart - plannedStartMinutes).clamp(0, 24 * 60),
    earlyLeaveMinutes:
        (normalizedPlannedEnd - normalizedActualEnd).clamp(0, 24 * 60),
    overtimeMinutes:
        (normalizedActualEnd - normalizedPlannedEnd).clamp(0, 24 * 60),
  );
}
