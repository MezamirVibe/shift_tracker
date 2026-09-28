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

/// Поле часов принимает «8», «8:30» или «8,5» без экранного циферблата.
int? parseWorkDurationInput(String raw) {
  final value = raw.trim().replaceAll(',', '.');
  final clock = RegExp(r'^(\d{1,2}):([0-5]\d)$').firstMatch(value);
  if (clock != null) {
    final minutes =
        int.parse(clock.group(1)!) * 60 + int.parse(clock.group(2)!);
    return minutes <= 1440 ? minutes : null;
  }
  if (!RegExp(r'^\d{1,2}(?:\.\d{1,2})?$').hasMatch(value)) return null;
  final hours = double.parse(value);
  if (hours > 24) return null;
  return (hours * 60).round();
}

String formatWorkDurationInput(int minutes) {
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0
      ? '$hours'
      : '$hours:${remainder.toString().padLeft(2, '0')}';
}
