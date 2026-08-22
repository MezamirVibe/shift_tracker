import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/schedule_utils.dart';
import '../onboarding/onboarding_page.dart';
import '../onboarding/onboarding_service.dart';
import '../preferences/preferences_service.dart';
import '../preferences/user_preferences.dart';
import 'dashboard_customizer.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();
  final _preferences = PreferencesService.instance;

  bool _loading = true;
  String? _error;
  List<EmployeeModel> _employees = const [];
  Map<String, dynamic> _attendance = const {};
  bool _onboardingCheckStarted = false;

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_onPreferencesChanged);
    unawaited(_load());
    _scheduleOnboardingCheck();
  }

  @override
  void dispose() {
    _preferences.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  void _onPreferencesChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleOnboardingCheck() {
    if (_onboardingCheckStarted) return;
    _onboardingCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final shouldShow =
          await OnboardingService.instance.shouldShowForCurrentUser();
      if (!mounted || !shouldShow) return;
      await OnboardingPage.show(context);
    });
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      if (_employees.isEmpty) _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _preferences.syncForCurrentUser(force: force),
        _employeesStorage.load(force: force),
        _attendanceStorage.loadRange(
          DateTime(DateTime.now().year, DateTime.now().month, 1),
          DateTime.now(),
          force: force,
        ),
      ]);
      if (!mounted) return;
      final allEmployees = results[1] as List<EmployeeModel>;
      setState(() {
        _employees = AuthService.instance
            .filterEmployeesByScope(allEmployees)
            .where(
              (employee) => _preferences.isGroupVisible(employee.groupId),
            )
            .toList();
        _attendance = results[2] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить данные главного экрана';
      });
    }
  }

  EmployeeModel? get _currentEmployee {
    final employeeId = AuthService.instance.currentUser?.employeeId;
    if (employeeId == null) return null;
    for (final employee in _employees) {
      if (employee.id == employeeId) return employee;
    }
    return null;
  }

  String _iso(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  AttendanceRecord? _record(DateTime day, String employeeId) {
    final dayMap = _attendance[_iso(day)];
    if (dayMap is! Map) return null;
    final raw = dayMap[employeeId];
    if (raw is! Map) return null;
    return AttendanceRecord.fromJson(Map<String, dynamic>.from(raw));
  }

  DateTime? _nextShift(EmployeeModel? employee) {
    if (employee == null) return null;
    final today = dateOnly(DateTime.now());
    for (var offset = 0; offset < 45; offset++) {
      final day = today.add(Duration(days: offset));
      if (isWorkDay(
        day: day,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      )) {
        return day;
      }
    }
    return null;
  }

  int get _workedMinutesThisMonth {
    final employee = _currentEmployee;
    if (employee == null) return 0;
    final now = DateTime.now();
    var total = 0;
    for (var day = 1; day <= now.day; day++) {
      final record = _record(DateTime(now.year, now.month, day), employee.id);
      if (record?.fact == FactStatus.worked) {
        total += record?.workedMinutes ?? employee.paidShiftHours * 60;
      }
    }
    return total;
  }

  int get _teamWorkingToday {
    final today = dateOnly(DateTime.now());
    return _employees.where((employee) {
      final fact = _record(today, employee.id)?.fact;
      if (fact == FactStatus.absent ||
          fact == FactStatus.sick ||
          fact == FactStatus.vacation) {
        return false;
      }
      return fact == FactStatus.worked ||
          isWorkDay(
            day: today,
            type: employee.scheduleType,
            startDate: employee.scheduleStartDate,
            customWorkdays: employee.customWorkdays,
          );
    }).length;
  }

  double get _attendanceProgress {
    final today = dateOnly(DateTime.now());
    final planned = _employees.where((employee) {
      return isWorkDay(
        day: today,
        type: employee.scheduleType,
        startDate: employee.scheduleStartDate,
        customWorkdays: employee.customWorkdays,
      );
    }).toList();
    if (planned.isEmpty) return 1;
    final filled = planned.where((employee) {
      final record = _record(today, employee.id);
      return record != null && record.fact != FactStatus.none;
    }).length;
    return filled / planned.length;
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    return AdaptiveScaffold(
      title: 'Главная',
      selectedRoute: '/',
      actions: [
        IconButton(
          tooltip: 'Обновить',
          onPressed: () => _load(force: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _content(isMobile),
    );
  }

  Widget _content(bool isMobile) {
    final user = AuthService.instance.currentUser;
    final firstName = user?.firstName.trim();
    final greetingName = (firstName == null || firstName.isEmpty)
        ? user?.login ?? 'пользователь'
        : firstName;
    final layout = _preferences
        .layoutFor(mobile: isMobile)
        .where((item) => item.enabled)
        .toList();

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(isMobile ? 12 : 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Добро пожаловать, $greetingName',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  DateFormat('EEEE, d MMMM', 'ru_RU').format(DateTime.now()),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 22),
                if (layout.isEmpty)
                  _EmptyDashboard(
                    onCustomize: () => DashboardCustomizer.show(
                      context,
                      mobile: isMobile,
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 16.0;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final item in layout)
                            SizedBox(
                              width: _widgetWidth(
                                constraints.maxWidth,
                                item.size,
                                isMobile,
                                gap,
                              ),
                              child: _dashboardWidget(item.type),
                            ),
                        ],
                      );
                    },
                  ),
                if (_preferences.lastError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _preferences.lastError!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.shiftColors.warning,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _widgetWidth(
    double available,
    DashboardWidgetSize size,
    bool mobile,
    double gap,
  ) {
    if (mobile || available < 720) return available;
    return switch (size) {
      DashboardWidgetSize.wide => available,
      DashboardWidgetSize.normal => (available - gap) / 2,
      DashboardWidgetSize.compact => (available - gap * 2) / 3,
    };
  }

  Widget _dashboardWidget(DashboardWidgetType type) => switch (type) {
        DashboardWidgetType.nextShift => _nextShiftCard(),
        DashboardWidgetType.weekSchedule => _weekCard(),
        DashboardWidgetType.workedHours => _hoursCard(),
        DashboardWidgetType.teamToday => _teamCard(),
        DashboardWidgetType.attendanceProgress => _attendanceCard(),
        DashboardWidgetType.quickActions => _quickActionsCard(),
        DashboardWidgetType.profile => _profileCard(),
      };

  Widget _nextShiftCard() {
    final employee = _currentEmployee;
    final next = _nextShift(employee);
    return _DashboardCard(
      accent: Theme.of(context).colorScheme.primary,
      icon: Icons.calendar_today_outlined,
      title: 'Ближайшая смена',
      child: employee == null || next == null
          ? const Text(
              'Привяжите учётную запись к сотруднику, чтобы видеть личный график.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DateFormat('d MMMM, EEEE', 'ru_RU').format(next),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  'Плановая смена · ${employee.shiftHours} ч · перерыв ${employee.breakHours} ч',
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => context.go('/schedule'),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Открыть график'),
                ),
              ],
            ),
    );
  }

  Widget _weekCard() {
    final employee = _currentEmployee;
    final now = dateOnly(DateTime.now());
    final start = now.subtract(Duration(days: now.weekday - 1));
    return _DashboardCard(
      accent: Theme.of(context).colorScheme.secondary,
      icon: Icons.view_week_outlined,
      title: 'Моя неделя',
      child: employee == null
          ? const Text('Личный график появится после привязки сотрудника.')
          : Row(
              children: [
                for (var offset = 0; offset < 7; offset++)
                  Expanded(
                    child: _WeekDay(
                      day: start.add(Duration(days: offset)),
                      work: isWorkDay(
                        day: start.add(Duration(days: offset)),
                        type: employee.scheduleType,
                        startDate: employee.scheduleStartDate,
                        customWorkdays: employee.customWorkdays,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _hoursCard() {
    final hours = _workedMinutesThisMonth / 60;
    return _MetricCard(
      icon: Icons.schedule_outlined,
      label: 'Отработано в этом месяце',
      value: '${hours.toStringAsFixed(hours % 1 == 0 ? 0 : 1)} ч',
      color: Theme.of(context).colorScheme.primary,
    );
  }

  Widget _teamCard() {
    return _MetricCard(
      icon: Icons.groups_2_outlined,
      label: 'Сегодня работают',
      value: '$_teamWorkingToday из ${_employees.length}',
      color: Theme.of(context).colorScheme.secondary,
      action: () => context.go('/employees'),
    );
  }

  Widget _attendanceCard() {
    final percent = (_attendanceProgress * 100).round();
    return _DashboardCard(
      accent: context.shiftColors.warning,
      icon: Icons.fact_check_outlined,
      title: 'Табель за сегодня',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$percent% заполнено',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _attendanceProgress, minHeight: 8),
          const SizedBox(height: 8),
          Text(
            _attendanceProgress >= 1
                ? 'Все плановые выходы отмечены'
                : 'Есть сотрудники без отметки факта',
          ),
        ],
      ),
    );
  }

  Widget _quickActionsCard() {
    final auth = AuthService.instance;
    final currentRole = auth.roleById(auth.currentUser?.roleId);
    final canOpenEmployees = currentRole?.scopeKind != ScopeKind.self &&
        auth.hasPerm(AppPermission.viewEmployees);
    return _DashboardCard(
      accent: Theme.of(context).colorScheme.tertiary,
      icon: Icons.bolt_outlined,
      title: 'Быстрые действия',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          OutlinedButton.icon(
            onPressed: () => context.go('/schedule'),
            icon: const Icon(Icons.calendar_month_outlined),
            label: const Text('График'),
          ),
          if (canOpenEmployees)
            OutlinedButton.icon(
              onPressed: () => context.go('/employees'),
              icon: const Icon(Icons.people_outline),
              label: const Text('Сотрудники'),
            ),
          if (auth.isCurrentUserSuperAdmin ||
              auth.hasPerm(AppPermission.manageUsers))
            OutlinedButton.icon(
              onPressed: () => context.go('/admin'),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Управление'),
            ),
          OutlinedButton.icon(
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.tune),
            label: const Text('Настройки'),
          ),
        ],
      ),
    );
  }

  Widget _profileCard() {
    final auth = AuthService.instance;
    final user = auth.currentUser;
    final role = auth.roleById(user?.roleId);
    return _DashboardCard(
      accent: Theme.of(context).colorScheme.primary,
      icon: Icons.person_outline,
      title: 'Моя учётная запись',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user?.fullName.trim().isNotEmpty == true
                ? user!.fullName
                : user?.login ?? '—',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(role?.name ?? roleLabelById(user?.roleId ?? '')),
          if (role != null) ...[
            const SizedBox(height: 4),
            Text(
              scopeKindLabel(role.scopeKind),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final Color accent;
  final IconData icon;
  final String title;
  final Widget child;

  const _DashboardCard({
    required this.accent,
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: accent, size: 21),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? action;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.withValues(alpha: 0.13),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text(value,
                        style: Theme.of(context).textTheme.headlineSmall),
                  ],
                ),
              ),
              if (action != null) const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekDay extends StatelessWidget {
  final DateTime day;
  final bool work;

  const _WeekDay({required this.day, required this.work});

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(day) == dateOnly(DateTime.now());
    final color = work
        ? Theme.of(context).colorScheme.primary
        : context.shiftColors.neutral;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 3),
      decoration: BoxDecoration(
        color: today
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(DateFormat('E', 'ru_RU').format(day)),
          const SizedBox(height: 4),
          Text('${day.day}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            work ? 'Д' : 'ОТ',
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  final VoidCallback onCustomize;

  const _EmptyDashboard({required this.onCustomize});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Column(
            children: [
              const Icon(Icons.dashboard_customize_outlined, size: 44),
              const SizedBox(height: 12),
              Text('Главный экран пуст',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('Выберите блоки, которые хотите видеть здесь.'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onCustomize,
                icon: const Icon(Icons.add),
                label: const Text('Добавить блоки'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 42),
              const SizedBox(height: 12),
              Text(message),
              const SizedBox(height: 14),
              FilledButton(onPressed: onRetry, child: const Text('Повторить')),
            ],
          ),
        ),
      ),
    );
  }
}
