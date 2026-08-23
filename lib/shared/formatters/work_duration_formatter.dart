/// Форматирует рабочее время без дробных часов.
///
/// Примеры: 60 -> «1 ч», 93 -> «1 ч 33 мин», 45 -> «45 мин».
String formatWorkDuration(int minutes) {
  final safeMinutes = minutes < 0 ? 0 : minutes;
  final hours = safeMinutes ~/ 60;
  final remainder = safeMinutes % 60;

  if (hours == 0) return '$remainder мин';
  if (remainder == 0) return '$hours ч';
  return '$hours ч $remainder мин';
}
