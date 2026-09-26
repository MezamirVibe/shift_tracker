import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/features/attendance/attendance_storage.dart';

void main() {
  test('attendance record keeps actual start and end time', () {
    final record = AttendanceRecord.fromJson({
      'fact': 'worked',
      'workedMinutes': 360,
      'actualStart': '08:30',
      'actualEnd': '15:30',
    });

    expect(record.fact, FactStatus.worked);
    expect(record.workedMinutes, 360);
    expect(record.actualStart, '08:30');
    expect(record.actualEnd, '15:30');
    expect(record.toJson()['actualStart'], '08:30');
    expect(record.toJson()['actualEnd'], '15:30');
  });
}
