import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/features/attendance/attendance_storage.dart';
import 'package:shift_tracker/features/day/attendance_edit_draft.dart';

AttendanceRecord save(AttendanceEditDraft draft,
        {FactStatus fact = FactStatus.worked,
        bool tripHours = true,
        int calculated = 720}) =>
    draft.build(
        fact: fact,
        tripHasHours: tripHours,
        calculatedMinutes: calculated,
        actualStart: '08:00',
        actualEnd: '20:00',
        comment: 'Changed comment');

void main() {
  test('comment-only edits preserve legacy hours without fabricating times',
      () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 660,
        original: const AttendanceRecord(
            fact: FactStatus.worked, workedMinutes: 360));
    final edited = save(draft);
    expect(edited.workedMinutes, 360);
    expect(edited.actualStart, isNull);
    expect(edited.actualEnd, isNull);
    expect(edited.comment, 'Changed comment');
  });
  test('schedule/break changes do not change existing actual minutes or times',
      () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 660,
        original: const AttendanceRecord(
            fact: FactStatus.worked,
            workedMinutes: 420,
            actualStart: '09:00',
            actualEnd: '17:00'));
    final edited = save(draft);
    expect(edited.workedMinutes, 420);
    expect(edited.actualStart, '09:00');
    expect(edited.actualEnd, '17:00');
  });
  test('explicit time or break edits recalculate hours', () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 660,
        original:
            const AttendanceRecord(fact: FactStatus.worked, workedMinutes: 360))
      ..timesChanged = true;
    expect(save(draft).workedMinutes, 720);
    expect(save(draft).actualStart, '08:00');
  });
  test('mixed marks preserve hours and switching to absence clears them', () {
    for (final status in [FactStatus.businessTrip, FactStatus.vacationWorked]) {
      final draft = AttendanceEditDraft(
          defaultMinutes: 480,
          original: AttendanceRecord(fact: status, workedMinutes: 660));
      expect(save(draft, fact: status).workedMinutes, 660);
      final absence = save(draft, fact: FactStatus.unpaid);
      expect(absence.workedMinutes, 0);
      expect(absence.actualStart, isNull);
    }
  });
  test('trip without hours stays K and enabling work uses the historical shift',
      () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 480,
        original: const AttendanceRecord(
            fact: FactStatus.businessTrip, workedMinutes: 0));
    expect(
        save(draft, fact: FactStatus.businessTrip, tripHours: false)
            .workedMinutes,
        0);
    expect(save(draft, fact: FactStatus.businessTrip).workedMinutes, 480);
  });
  test('zero-hour worked records are not replaced with a full shift', () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 480,
        original:
            const AttendanceRecord(fact: FactStatus.worked, workedMinutes: 0));
    expect(save(draft).workedMinutes, 0);
  });
  test('new records use paid shift hours and leave unknown clock times empty',
      () {
    final draft = AttendanceEditDraft(defaultMinutes: 480, original: null);
    expect(save(draft).workedMinutes, 480);
    expect(save(draft).actualStart, isNull);
  });

  test('editing only total hours keeps previously recorded arrival and exit',
      () {
    final draft = AttendanceEditDraft(
        defaultMinutes: 480,
        original: const AttendanceRecord(
            fact: FactStatus.worked,
            workedMinutes: 480,
            actualStart: '08:00',
            actualEnd: '17:00'));
    final edited = draft.build(
        fact: FactStatus.worked,
        tripHasHours: true,
        calculatedMinutes: 720,
        actualStart: '08:00',
        actualEnd: '20:00',
        manualMinutes: 660);
    expect(edited.workedMinutes, 660);
    expect(edited.actualStart, '08:00');
    expect(edited.actualEnd, '17:00');
  });
}
