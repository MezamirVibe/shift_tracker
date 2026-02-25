import 'employees_storage.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool isWorkDay({
  required DateTime day,
  required ScheduleType type,
  required DateTime startDate,
}) {
  final d = dateOnly(day);

  if (type == ScheduleType.fiveTwo) {
    // 5/2: Пн–Пт рабочие
    final wd = d.weekday; // 1..7 (Mon..Sun)
    return wd >= DateTime.monday && wd <= DateTime.friday;
  }

  // 2/2 от даты старта:
  final s = dateOnly(startDate);
  final diffDays = d.difference(s).inDays;

  if (diffDays < 0) return false; // до даты старта ещё нет смен

  final mod = diffDays % 4; // цикл: 2 работа + 2 выходных
  return mod == 0 || mod == 1;
}
