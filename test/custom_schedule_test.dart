import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/features/employees/employees_storage.dart';
import 'package:shift_tracker/features/employees/schedule_utils.dart';

void main() {
  group('custom schedule', () {
    test('uses the selected weekdays', () {
      final monday = DateTime(2026, 8, 17);
      final tuesday = DateTime(2026, 8, 18);
      final saturday = DateTime(2026, 8, 22);

      expect(
        isWorkDay(
          day: monday,
          type: ScheduleType.custom,
          startDate: monday,
          customWorkdays: const [1, 3, 6],
        ),
        isTrue,
      );
      expect(
        isWorkDay(
          day: tuesday,
          type: ScheduleType.custom,
          startDate: monday,
          customWorkdays: const [1, 3, 6],
        ),
        isFalse,
      );
      expect(
        isWorkDay(
          day: saturday,
          type: ScheduleType.custom,
          startDate: monday,
          customWorkdays: const [1, 3, 6],
        ),
        isTrue,
      );
    });

    test('round-trips custom workdays in employee json', () {
      final employee = EmployeeModel(
        id: 'test',
        fullName: 'Тестовый Сотрудник',
        position: 'Специалист',
        salary: 0,
        bonus: 0,
        scheduleType: ScheduleType.custom,
        customWorkdays: const [2, 4, 7],
        shiftHours: 7,
        breakHours: 1,
      );

      final restored = EmployeeModel.fromJson(employee.toJson());

      expect(restored.scheduleType, ScheduleType.custom);
      expect(restored.customWorkdays, [2, 4, 7]);
      expect(restored.shiftHours, 7);
      expect(scheduleTypeLabel(restored.scheduleType), 'Произвольный');
    });
  });
}
