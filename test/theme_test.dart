import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';

void main() {
  test('all three themes expose the shared status palette', () {
    for (final choice in AppThemeChoice.values) {
      final theme = AppTheme.forChoice(choice);
      expect(theme.useMaterial3, isTrue);
      expect(theme.extension<ShiftStatusColors>(), isNotNull);
      expect(theme.colorScheme.primary, isNot(Colors.transparent));
    }
  });

  test('light, dim and dark are visually distinct', () {
    final light = AppTheme.light();
    final dim = AppTheme.dim();
    final dark = AppTheme.dark();

    expect(light.brightness, Brightness.light);
    expect(dim.brightness, Brightness.dark);
    expect(dark.brightness, Brightness.dark);
    expect(dim.scaffoldBackgroundColor, isNot(dark.scaffoldBackgroundColor));
    expect(light.scaffoldBackgroundColor, isNot(dim.scaffoldBackgroundColor));
  });
}
