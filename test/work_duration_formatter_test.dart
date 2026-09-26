import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/shared/formatters/work_duration_formatter.dart';

void main() {
  test('formats whole and partial work hours without decimals', () {
    expect(formatWorkDuration(0), '0 мин');
    expect(formatWorkDuration(45), '45 мин');
    expect(formatWorkDuration(60), '1 ч');
    expect(formatWorkDuration(93), '1 ч 33 мин');
    expect(formatWorkDuration(1308), '21 ч 48 мин');
  });

  test('does not display a negative duration', () {
    expect(formatWorkDuration(-15), '0 мин');
  });

  test('accepts direct hours, minutes and Russian decimal separator', () {
    expect(parseWorkDurationInput('11'), 660);
    expect(parseWorkDurationInput('8:30'), 510);
    expect(parseWorkDurationInput('8,5'), 510);
    expect(formatWorkDurationInput(510), '8:30');
    expect(parseWorkDurationInput('25'), isNull);
    expect(parseWorkDurationInput('8:75'), isNull);
  });
}
