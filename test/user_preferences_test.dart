import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/preferences/user_preferences.dart';

void main() {
  group('UserPreferences', () {
    test('round-trips theme and dashboard layouts', () {
      const original = UserPreferences(
        theme: AppThemeChoice.dim,
        desktopWidgets: [
          DashboardWidgetPreference(
            type: DashboardWidgetType.nextShift,
            size: DashboardWidgetSize.wide,
          ),
          DashboardWidgetPreference(
            type: DashboardWidgetType.profile,
            enabled: false,
          ),
        ],
        mobileWidgets: [
          DashboardWidgetPreference(
            type: DashboardWidgetType.weekSchedule,
            size: DashboardWidgetSize.compact,
          ),
        ],
        hiddenGroupIds: {'group-local'},
        adminHiddenGroupIds: {'group-admin'},
      );

      final restored = UserPreferences.fromJson(
        original.toJson(),
        fallback: UserPreferences.defaults(),
      );

      expect(restored.theme, AppThemeChoice.dim);
      expect(restored.desktopWidgets, hasLength(2));
      expect(restored.desktopWidgets.first.type, DashboardWidgetType.nextShift);
      expect(restored.desktopWidgets.first.size, DashboardWidgetSize.wide);
      expect(restored.desktopWidgets.last.enabled, isFalse);
      expect(
          restored.mobileWidgets.single.type, DashboardWidgetType.weekSchedule);
      expect(restored.hiddenGroupIds, {'group-local'});
      expect(restored.adminHiddenGroupIds, {'group-admin'});
    });

    test('ignores unknown and duplicate widget identifiers', () {
      final restored = UserPreferences.fromJson(
        {
          'theme': 'dark',
          'desktopDashboard': [
            {'type': 'unknown', 'enabled': true},
            {'type': 'profile', 'enabled': true},
            {'type': 'profile', 'enabled': false},
          ],
        },
        fallback: UserPreferences.defaults(),
      );

      expect(restored.theme, AppThemeChoice.dark);
      expect(restored.desktopWidgets, hasLength(1));
      expect(restored.desktopWidgets.single.type, DashboardWidgetType.profile);
      expect(restored.desktopWidgets.single.enabled, isTrue);
    });
  });
}
