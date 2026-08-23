import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/features/day/attendance_deviation.dart';

void main() {
  test('detects a late arrival and overtime', () {
    final result = calculateAttendanceDeviation(
      plannedStartMinutes: 8 * 60,
      plannedEndMinutes: 16 * 60,
      actualStartMinutes: 8 * 60 + 20,
      actualEndMinutes: 17 * 60,
    );

    expect(result.lateMinutes, 20);
    expect(result.earlyLeaveMinutes, 0);
    expect(result.overtimeMinutes, 60);
  });

  test('detects an early leave', () {
    final result = calculateAttendanceDeviation(
      plannedStartMinutes: 8 * 60,
      plannedEndMinutes: 16 * 60,
      actualStartMinutes: 8 * 60,
      actualEndMinutes: 15 * 60 + 30,
    );

    expect(result.lateMinutes, 0);
    expect(result.earlyLeaveMinutes, 30);
    expect(result.overtimeMinutes, 0);
  });

  test('handles a shift that ends on the next day', () {
    final result = calculateAttendanceDeviation(
      plannedStartMinutes: 20 * 60,
      plannedEndMinutes: 8 * 60,
      actualStartMinutes: 20 * 60 + 15,
      actualEndMinutes: 9 * 60,
    );

    expect(result.lateMinutes, 15);
    expect(result.earlyLeaveMinutes, 0);
    expect(result.overtimeMinutes, 60);
  });
}
