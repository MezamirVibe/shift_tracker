import '../../app/theme.dart';

enum DashboardWidgetType {
  nextShift,
  weekSchedule,
  workedHours,
  teamToday,
  attendanceProgress,
  quickActions,
  profile,
}

extension DashboardWidgetTypeX on DashboardWidgetType {
  String get label => switch (this) {
        DashboardWidgetType.nextShift => 'Ближайшая смена',
        DashboardWidgetType.weekSchedule => 'График на неделю',
        DashboardWidgetType.workedHours => 'Часы за месяц',
        DashboardWidgetType.teamToday => 'Команда сегодня',
        DashboardWidgetType.attendanceProgress => 'Заполнение табеля',
        DashboardWidgetType.quickActions => 'Быстрые действия',
        DashboardWidgetType.profile => 'Моя учётная запись',
      };

  String get description => switch (this) {
        DashboardWidgetType.nextShift =>
          'Дата и продолжительность ближайшей плановой смены',
        DashboardWidgetType.weekSchedule => 'Рабочие и выходные дни недели',
        DashboardWidgetType.workedHours => 'Фактически учтённые часы за месяц',
        DashboardWidgetType.teamToday => 'Сколько сотрудников работает сегодня',
        DashboardWidgetType.attendanceProgress =>
          'Соотношение плана и заполненных фактов',
        DashboardWidgetType.quickActions => 'Переходы к основным разделам',
        DashboardWidgetType.profile => 'Роль и область доступа пользователя',
      };

  static DashboardWidgetType? parse(Object? value) {
    for (final type in DashboardWidgetType.values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

enum DashboardWidgetSize { compact, normal, wide }

extension DashboardWidgetSizeX on DashboardWidgetSize {
  String get label => switch (this) {
        DashboardWidgetSize.compact => 'Компактный',
        DashboardWidgetSize.normal => 'Обычный',
        DashboardWidgetSize.wide => 'Широкий',
      };

  static DashboardWidgetSize parse(Object? value) {
    for (final size in DashboardWidgetSize.values) {
      if (size.name == value) return size;
    }
    return DashboardWidgetSize.normal;
  }
}

class DashboardWidgetPreference {
  final DashboardWidgetType type;
  final DashboardWidgetSize size;
  final bool enabled;

  const DashboardWidgetPreference({
    required this.type,
    this.size = DashboardWidgetSize.normal,
    this.enabled = true,
  });

  DashboardWidgetPreference copyWith({
    DashboardWidgetSize? size,
    bool? enabled,
  }) {
    return DashboardWidgetPreference(
      type: type,
      size: size ?? this.size,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'size': size.name,
        'enabled': enabled,
      };

  static DashboardWidgetPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = DashboardWidgetTypeX.parse(raw['type']);
    if (type == null) return null;
    return DashboardWidgetPreference(
      type: type,
      size: DashboardWidgetSizeX.parse(raw['size']),
      enabled: raw['enabled'] != false,
    );
  }
}

class UserPreferences {
  final AppThemeChoice theme;
  final List<DashboardWidgetPreference> desktopWidgets;
  final List<DashboardWidgetPreference> mobileWidgets;
  final Set<String> hiddenGroupIds;
  final Set<String> adminHiddenGroupIds;

  const UserPreferences({
    required this.theme,
    required this.desktopWidgets,
    required this.mobileWidgets,
    this.hiddenGroupIds = const {},
    this.adminHiddenGroupIds = const {},
  });

  factory UserPreferences.defaults({bool showTeamWidgets = false}) {
    final desktop = <DashboardWidgetPreference>[
      const DashboardWidgetPreference(
        type: DashboardWidgetType.nextShift,
        size: DashboardWidgetSize.wide,
      ),
      const DashboardWidgetPreference(
        type: DashboardWidgetType.weekSchedule,
        size: DashboardWidgetSize.wide,
      ),
      const DashboardWidgetPreference(
        type: DashboardWidgetType.workedHours,
      ),
      if (showTeamWidgets)
        const DashboardWidgetPreference(type: DashboardWidgetType.teamToday),
      if (showTeamWidgets)
        const DashboardWidgetPreference(
          type: DashboardWidgetType.attendanceProgress,
        ),
      const DashboardWidgetPreference(
        type: DashboardWidgetType.quickActions,
        size: DashboardWidgetSize.wide,
      ),
      const DashboardWidgetPreference(type: DashboardWidgetType.profile),
    ];
    final mobile = <DashboardWidgetPreference>[
      const DashboardWidgetPreference(
        type: DashboardWidgetType.nextShift,
        size: DashboardWidgetSize.wide,
      ),
      const DashboardWidgetPreference(
        type: DashboardWidgetType.weekSchedule,
        size: DashboardWidgetSize.wide,
      ),
      const DashboardWidgetPreference(type: DashboardWidgetType.workedHours),
      if (showTeamWidgets)
        const DashboardWidgetPreference(type: DashboardWidgetType.teamToday),
      const DashboardWidgetPreference(
        type: DashboardWidgetType.quickActions,
        size: DashboardWidgetSize.wide,
      ),
    ];
    return UserPreferences(
      theme: AppThemeChoice.light,
      desktopWidgets: desktop,
      mobileWidgets: mobile,
      hiddenGroupIds: const {},
      adminHiddenGroupIds: const {},
    );
  }

  UserPreferences copyWith({
    AppThemeChoice? theme,
    List<DashboardWidgetPreference>? desktopWidgets,
    List<DashboardWidgetPreference>? mobileWidgets,
    Set<String>? hiddenGroupIds,
    Set<String>? adminHiddenGroupIds,
  }) {
    return UserPreferences(
      theme: theme ?? this.theme,
      desktopWidgets: desktopWidgets ?? this.desktopWidgets,
      mobileWidgets: mobileWidgets ?? this.mobileWidgets,
      hiddenGroupIds: hiddenGroupIds ?? this.hiddenGroupIds,
      adminHiddenGroupIds: adminHiddenGroupIds ?? this.adminHiddenGroupIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'theme': theme.storageValue,
        'desktopDashboard':
            desktopWidgets.map((item) => item.toJson()).toList(),
        'mobileDashboard': mobileWidgets.map((item) => item.toJson()).toList(),
        'hidden_group_ids': hiddenGroupIds.toList()..sort(),
        'admin_hidden_group_ids': adminHiddenGroupIds.toList()..sort(),
      };

  static UserPreferences fromJson(
    Object? raw, {
    required UserPreferences fallback,
  }) {
    if (raw is! Map) return fallback;

    List<DashboardWidgetPreference> parseList(
      Object? value,
      List<DashboardWidgetPreference> defaultValue,
    ) {
      if (value is! List) return defaultValue;
      final seen = <DashboardWidgetType>{};
      final parsed = <DashboardWidgetPreference>[];
      for (final rawItem in value) {
        final item = DashboardWidgetPreference.fromJson(rawItem);
        if (item != null && seen.add(item.type)) parsed.add(item);
      }
      return parsed.isEmpty ? defaultValue : parsed;
    }

    Set<String> parseIds(Object? value, Set<String> defaultValue) {
      if (value is! List) return defaultValue;
      return value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    }

    return UserPreferences(
      theme: AppThemeChoiceX.parse(raw['theme']),
      desktopWidgets:
          parseList(raw['desktopDashboard'], fallback.desktopWidgets),
      mobileWidgets: parseList(raw['mobileDashboard'], fallback.mobileWidgets),
      hiddenGroupIds: parseIds(
        raw['hidden_group_ids'] ?? raw['hiddenGroupIds'],
        fallback.hiddenGroupIds,
      ),
      adminHiddenGroupIds: parseIds(
        raw['admin_hidden_group_ids'] ?? raw['adminHiddenGroupIds'],
        fallback.adminHiddenGroupIds,
      ),
    );
  }
}
