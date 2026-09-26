import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/route_observer.dart';
import '../../app/theme.dart';
import '../../core/api_client.dart';
import '../../shared/formatters/work_duration_formatter.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../attendance/attendance_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../employees/employees_storage.dart';
import '../employees/personal_schedule_storage.dart';
import '../employees/schedule_utils.dart';
import '../onboarding/onboarding_page.dart';
import '../onboarding/onboarding_service.dart';
import '../preferences/preferences_service.dart';
import '../preferences/user_preferences.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver, RouteAware {
  final _employeesStorage = EmployeesStorage();
  final _attendanceStorage = AttendanceStorage();
  final _preferences = PreferencesService.instance;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _requestsError;
  DateTime? _updatedAt;
  int? _pendingRequests;
  List<Map<String, dynamic>> _responses = const [];
  List<({DateTime day, int unfilled, int unclosed})> _actionDays = const [];
  List<EmployeeModel> _employees = const [];
  Map<String, dynamic> _attendance = const {};
  Timer? _refreshTimer;
  int _generation = 0;
  ModalRoute<void>? _route;

  bool get _personal => PersonalScheduleStorage.applies;
  bool get _canReview =>
      !_personal && AuthService.instance.hasPerm(AppPermission.editAttendance);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _preferences.addListener(_onPreferencesChanged);
    AttendanceStorage.changes.addListener(_attendanceChanged);
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final shouldShow =
          await OnboardingService.instance.shouldShowForCurrentUser();
      if (!mounted || !shouldShow) return;
      await OnboardingPage.show(context);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() => _attendanceChanged();

  @override
  void dispose() {
    _generation++;
    _refreshTimer?.cancel();
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _preferences.removeListener(_onPreferencesChanged);
    AttendanceStorage.changes.removeListener(_attendanceChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _attendanceChanged();
  }

  void _onPreferencesChanged() {
    if (mounted) setState(() {});
  }

  void _attendanceChanged() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) unawaited(_load());
    });
  }

  void _open(String route) => context.push(route);

  Future<void> _load() async {
    final generation = ++_generation;
    final scope = ApiClient.instance.cacheUserKey;
    final now = DateTime.now();
    setState(() {
      _refreshing = true;
      _error = null;
      _requestsError = null;
    });
    try {
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 0);
      final personalRangeEnd = now.add(const Duration(days: 45));
      final loadTo =
          personalRangeEnd.isAfter(monthEnd) ? personalRangeEnd : monthEnd;
      final personal =
          _personal ? PersonalScheduleStorage.load(monthStart, loadTo) : null;
      final results = await Future.wait([
        _preferences.syncForCurrentUser(force: true),
        personal?.then((data) => data.employees) ??
            _employeesStorage.load(force: true),
        personal?.then((data) => data.attendance) ??
            _attendanceStorage.loadRange(monthStart, now, force: true),
        if (_canReview)
          ApiClient.instance.request('GET',
              '/api/v1/attendance/action-days?date_from=${_iso(monthStart)}&date_to=${_iso(now)}'),
      ]);
      if (!mounted ||
          generation != _generation ||
          scope != ApiClient.instance.cacheUserKey) {
        return;
      }
      setState(() {
        _employees = AuthService.instance
            .filterEmployeesByScope(results[1] as List<EmployeeModel>)
            .where((employee) => _preferences.isGroupVisible(employee.groupId))
            .toList();
        _attendance = results[2] as Map<String, dynamic>;
        if (_canReview) {
          _actionDays = (((results[3] as Map)['days']) as List).map((raw) {
            final item = raw as Map;
            return (
              day: DateTime.parse(item['day'] as String),
              unfilled: (item['unfilled'] as num).toInt(),
              unclosed: (item['unclosed'] as num).toInt()
            );
          }).toList()
            ..sort((a, b) => b.day.compareTo(a.day));
        }
        _updatedAt = DateTime.now();
        _loading = false;
      });
      if (_personal || _canReview) {
        try {
          final result = await ApiClient.instance
              .request('GET', '/api/v1/hour-requests/summary') as Map;
          if (!mounted ||
              generation != _generation ||
              scope != ApiClient.instance.cacheUserKey) {
            return;
          }
          setState(() {
            _pendingRequests = (result['pending_count'] as num).toInt();
            _responses = (result['recent_responses'] as List)
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList();
          });
        } catch (_) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _pendingRequests = null;
            _responses = const [];
            _requestsError =
                'Не удалось обновить запросы. Повторите обновление.';
          });
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : 'Не удалось обновить данные. Проверьте соединение.';
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _refreshing = false);
      }
    }
  }

  EmployeeModel? get _currentEmployee {
    final id = AuthService.instance.currentUser?.employeeId;
    for (final employee in _employees) {
      if (employee.id == id) return employee;
    }
    return null;
  }

  String _iso(DateTime day) => DateFormat('yyyy-MM-dd').format(day);

  AttendanceRecord? _record(DateTime day, String employeeId) {
    final records = _attendance[_iso(day)];
    if (records is! Map || records[employeeId] is! Map) return null;
    return AttendanceRecord.fromJson(
        Map<String, dynamic>.from(records[employeeId] as Map));
  }

  bool _planned(EmployeeModel employee, DateTime day) => isWorkDay(
      day: day,
      type: employee.scheduleType,
      startDate: employee.scheduleStartDate,
      customWorkdays: employee.customWorkdays);

  DateTime? _nextShift(EmployeeModel employee) {
    final today = dateOnly(DateTime.now());
    for (var offset = 0; offset < 45; offset++) {
      final day = today.add(Duration(days: offset));
      final record = _record(day, employee.id);
      if (record?.closed == true ||
          record?.fact == FactStatus.absent ||
          record?.fact == FactStatus.sick ||
          record?.fact == FactStatus.vacation ||
          record?.fact == FactStatus.unpaid) {
        continue;
      }
      if (_planned(employee, day) || record?.hasWorked == true) return day;
    }
    return null;
  }

  List<({DateTime day, int minutes})> get _closedDays {
    final employee = _currentEmployee;
    if (employee == null) return const [];
    final now = DateTime.now();
    final entries = <({DateTime day, int minutes})>[];
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(now.year, now.month, d);
      final record = _record(day, employee.id);
      if (record?.closed == true && record?.hasWorked == true) {
        entries.add((
          day: day,
          minutes: record!.workedMinutes ?? employee.paidShiftHours * 60
        ));
      }
    }
    return entries.reversed.toList();
  }

  Future<void> _showClosedDays() async {
    final entries = _closedDays;
    await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => FractionallySizedBox(
            heightFactor: 0.7,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Учтено за закрытые дни',
                          style: Theme.of(sheetContext).textTheme.titleLarge)),
                  Expanded(
                      child: entries.isEmpty
                          ? const Center(
                              child:
                                  Text('В этом месяце ещё нет закрытых часов.'))
                          : ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (_, index) {
                                final entry = entries[index];
                                return ListTile(
                                    leading: const Icon(Icons.lock_outline),
                                    title: Text(
                                        DateFormat('d MMMM, EEEE', 'ru_RU')
                                            .format(entry.day)),
                                    subtitle: Text(
                                        'Учтено: ${formatWorkDuration(entry.minutes)} · День закрыт'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () {
                                      Navigator.pop(sheetContext);
                                      _open(
                                          '/schedule?date=${_iso(entry.day)}');
                                    });
                              })),
                ])));
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 760;
    return AdaptiveScaffold(
        title: 'Главная',
        selectedRoute: '/',
        actions: [
          IconButton(
              tooltip: 'Обновить',
              onPressed: _refreshing ? null : _load,
              icon: const Icon(Icons.refresh))
        ],
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.all(mobile ? 12 : 24),
                    child: Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                      DateFormat('EEEE, d MMMM', 'ru_RU')
                                          .format(DateTime.now()),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  const SizedBox(height: 8),
                                  _dataStatus(),
                                  const SizedBox(height: 12),
                                  if (_updatedAt == null && _error != null)
                                    FilledButton(
                                        onPressed: _load,
                                        child: const Text('Повторить'))
                                  else if (_employees.isEmpty &&
                                      AuthService.instance
                                          .hasPerm(AppPermission.editEmployees))
                                    _emptyTeam()
                                  else ...[
                                    if (_personal || _canReview)
                                      _requestsCard(),
                                    const SizedBox(height: 12),
                                    _roleWidgets(mobile),
                                    if (!_personal &&
                                        AuthService.instance.hasPerm(
                                            AppPermission.viewAttendance)) ...[
                                      const SizedBox(height: 12),
                                      FilledButton.icon(
                                          onPressed: () => _open(
                                              '/timesheet?year=${DateTime.now().year}&month=${DateTime.now().month}'),
                                          icon: const Icon(
                                              Icons.table_view_outlined),
                                          label: const Text(
                                              'Открыть табель за месяц')),
                                    ],
                                  ],
                                ]))))));
  }

  Widget _dataStatus() {
    final color = _error == null && _requestsError == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Theme.of(context).colorScheme.error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_refreshing) const LinearProgressIndicator(),
      Text(
          _refreshing
              ? 'Обновление…'
              : _updatedAt == null
                  ? 'Данные ещё не загружены'
                  : 'Данные обновлены: ${DateFormat('dd.MM HH:mm').format(_updatedAt!)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
      if (_error != null)
        Text(
            '$_error${_updatedAt == null ? '' : ' Показаны данные последнего обновления; они могут быть устаревшими.'}',
            style: TextStyle(color: color)),
      if (_requestsError != null)
        Text(_requestsError!, style: TextStyle(color: color)),
      if (_preferences.lastError != null)
        Text(_preferences.lastError!,
            style: TextStyle(color: context.shiftColors.warning)),
    ]);
  }

  Widget _emptyTeam() => _DashboardCard(
      icon: Icons.person_add_alt_1,
      title: 'Начнём с сотрудников',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'Добавьте сотрудников вручную или импортируйте старый табель.'),
        const SizedBox(height: 12),
        FilledButton(
            onPressed: () => _open('/employees'),
            child: const Text('Добавить сотрудников')),
        if (_canReview)
          TextButton(
              onPressed: () => _open('/timesheet/import'),
              child: const Text('Импортировать табель')),
      ]));

  Widget _requestsCard() => _DashboardCard(
      icon: Icons.more_time,
      title: _personal ? 'Запросы и ответы' : 'Ожидают решения',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
            _pendingRequests == null
                ? 'Статусы запросов не обновлены'
                : 'Ожидают решения: $_pendingRequests',
            style: Theme.of(context).textTheme.titleMedium),
        if (_personal) ...[
          for (final response in _responses.take(3))
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    '${DateFormat('dd.MM').format(DateTime.parse(response['day'] as String))}: '
                    '+${formatWorkDuration((response['additional_minutes'] as num).toInt())} — '
                    '${response['status'] == 'approved' ? 'одобрено' : 'отклонено'}'
                    '${(response['review_comment'] as String? ?? '').trim().isEmpty ? '' : '\n${response['review_comment']}'}')),
          if (_responses.isEmpty &&
              _requestsError == null &&
              _pendingRequests != null)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Ответов руководителя пока нет.')),
        ],
        const SizedBox(height: 8),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => _open('/hour-requests'),
                icon: const Icon(Icons.chevron_right),
                label:
                    Text(_personal ? 'Все запросы' : 'Рассмотреть запросы'))),
      ]));

  Widget _roleWidgets(bool mobile) {
    final layout = _preferences.layoutFor(mobile: mobile);
    final usefulTypes = _personal
        ? const {DashboardWidgetType.nextShift, DashboardWidgetType.workedHours}
        : _canReview
            ? const {
                DashboardWidgetType.teamToday,
                DashboardWidgetType.attendanceProgress
              }
            : const <DashboardWidgetType>{};
    final items = layout
        .where((item) => item.enabled && usefulTypes.contains(item.type))
        .toList();
    // Older mobile layouts did not have the action summary. Never overwrite
    // stored preferences or re-enable a widget explicitly disabled by its user.
    if (_canReview &&
        !layout.any(
            (item) => item.type == DashboardWidgetType.attendanceProgress)) {
      items.add(const DashboardWidgetPreference(
          type: DashboardWidgetType.attendanceProgress));
    }
    if (items.isEmpty) {
      return const Text('Блоки главной скрыты в дополнительных настройках.');
    }
    return LayoutBuilder(
        builder: (_, constraints) =>
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final item in items)
                SizedBox(
                    width: mobile ||
                            constraints.maxWidth < 720 ||
                            item.size == DashboardWidgetSize.wide
                        ? constraints.maxWidth
                        : item.size == DashboardWidgetSize.compact
                            ? (constraints.maxWidth - 24) / 3
                            : (constraints.maxWidth - 12) / 2,
                    child: switch (item.type) {
                      DashboardWidgetType.nextShift => _nextShiftCard(),
                      DashboardWidgetType.workedHours => _hoursCard(),
                      DashboardWidgetType.teamToday => _teamCard(),
                      DashboardWidgetType.attendanceProgress =>
                        _attentionCard(),
                      _ => const SizedBox.shrink(),
                    }),
            ]));
  }

  Widget _nextShiftCard() {
    final employee = _currentEmployee;
    final next = employee == null ? null : _nextShift(employee);
    return _DashboardCard(
        icon: Icons.calendar_today_outlined,
        title: 'Ближайшая смена',
        child: next == null
            ? const Text('В ближайшие 45 дней нет плановых смен.')
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(DateFormat('d MMMM, EEEE', 'ru_RU').format(next),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                    'По плану: ${formatWorkDuration(employee!.paidShiftHours * 60)}'),
                Text(
                    'Продолжительность ${employee.shiftHours} ч · перерыв ${employee.breakHours} ч'),
                const SizedBox(height: 8),
                TextButton.icon(
                    onPressed: () => _open('/schedule?date=${_iso(next)}'),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Посмотреть смену')),
              ]));
  }

  Widget _hoursCard() => _DashboardCard(
      icon: Icons.lock_outline,
      title: 'Закрытые часы за месяц',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'Учтено: ${formatWorkDuration(_closedDays.fold<int>(0, (total, entry) => total + entry.minutes))}',
            style: Theme.of(context).textTheme.headlineSmall),
        const Text('Только за дни с отметкой «День закрыт».'),
        TextButton(onPressed: _showClosedDays, child: const Text('По дням')),
      ]));

  Widget _teamCard() {
    final today = dateOnly(DateTime.now());
    final planned =
        _employees.where((employee) => _planned(employee, today)).length;
    final worked = _employees
        .where((employee) => _record(today, employee.id)?.hasWorked == true)
        .length;
    return _DashboardCard(
        icon: Icons.groups_outlined,
        title: 'Сотрудники сегодня',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('По плану: $planned · Вышли: $worked',
              style: Theme.of(context).textTheme.titleLarge),
          TextButton(
              onPressed: () => _open('/day/${_iso(today)}'),
              child: const Text('Отметить сегодняшний день')),
        ]));
  }

  Widget _attentionCard() {
    final days = _actionDays;
    return _DashboardCard(
        icon: Icons.fact_check_outlined,
        title: 'Требуют внимания',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(days.isEmpty
              ? 'Все плановые и заполненные дни закрыты.'
              : 'Дней с незаполненными или незакрытыми отметками: ${days.length}'),
          const SizedBox(height: 4),
          const Text('Текущий месяц · по сохранённому графику на каждую дату.',
              style: TextStyle(fontSize: 12)),
          for (final entry in days.take(3))
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(DateFormat('d MMMM', 'ru_RU').format(entry.day)),
                subtitle: Text(
                    'Не заполнено: ${entry.unfilled} · Не закрыто: ${entry.unclosed}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open('/day/${_iso(entry.day)}')),
        ]));
  }
}

class _DashboardCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  const _DashboardCard(
      {required this.icon, required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium))
            ]),
            const SizedBox(height: 12),
            child,
          ])));
}
