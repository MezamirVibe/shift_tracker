import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'onboarding_service.dart';

enum OnboardingAudience { employee, manager }

enum _OnboardingVisual {
  welcome,
  navigation,
  schedule,
  events,
  attendance,
  deviations,
  closingDay,
  calendar,
  admin,
  help
}

class _OnboardingStep {
  final IconData icon;
  final String title;
  final String description;
  final List<String> points;
  final _OnboardingVisual visual;

  const _OnboardingStep({
    required this.icon,
    required this.title,
    required this.description,
    required this.points,
    required this.visual,
  });
}

class OnboardingPage extends StatefulWidget {
  final bool replay;
  final OnboardingAudience? audienceOverride;

  const OnboardingPage({
    super.key,
    this.replay = false,
    this.audienceOverride,
  });

  static Future<void> show(
    BuildContext context, {
    bool replay = false,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingPage(replay: replay),
      ),
    );
  }

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late final PageController _controller;
  late final OnboardingAudience _audience;
  late final List<_OnboardingStep> _steps;
  int _index = 0;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    _audience = widget.audienceOverride ?? _resolveAudience();
    _steps = _audience == OnboardingAudience.employee
        ? _employeeSteps
        : _managerSteps;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  OnboardingAudience _resolveAudience() {
    final auth = AuthService.instance;
    final user = auth.currentUser;
    final role = auth.roleById(user?.roleId);
    // На новом устройстве справочник ролей может ещё загружаться в фоне.
    // Встроенного рабочего всё равно сразу направляем в личное обучение.
    final selfOnly = role?.scopeKind == ScopeKind.self ||
        user?.roleId == BuiltInRoleIds.worker;
    final canManage = auth.hasPerm(AppPermission.editAttendance) ||
        auth.hasPerm(AppPermission.editEmployees) ||
        auth.hasPerm(AppPermission.manageUsers);
    return selfOnly && !canManage
        ? OnboardingAudience.employee
        : OnboardingAudience.manager;
  }

  List<_OnboardingStep> get _employeeSteps => const [
        _OnboardingStep(
          icon: Icons.waving_hand_outlined,
          title: 'Обучение сотрудника',
          description:
              'Покажем, как быстро узнать свою следующую смену и разобраться в событиях личного графика.',
          points: [
            'Обучение займёт меньше минуты',
            'Вы видите только собственные рабочие данные',
            'Просмотр графика ничего в нём не изменяет',
          ],
          visual: _OnboardingVisual.welcome,
        ),
        _OnboardingStep(
          icon: Icons.touch_app_outlined,
          title: 'Ваши основные разделы',
          description:
              'Внизу экрана расположено главное меню. Активный раздел всегда выделен синим.',
          points: [
            'Главная — ближайшая смена и полезные карточки',
            'График — ваши смены на неделю',
            'Календарь — весь месяц целиком',
            'Ещё — настройки приложения и это обучение',
          ],
          visual: _OnboardingVisual.navigation,
        ),
        _OnboardingStep(
          icon: Icons.calendar_view_week_outlined,
          title: 'Ближайшая смена и неделя',
          description:
              'На главной видна ближайшая смена. В «Графике» выберите день, чтобы проверить план на всю неделю.',
          points: [
            'В карточке смены указаны дата и продолжительность',
            'Синим показана запланированная рабочая смена',
            'На соседнюю неделю можно перейти стрелками',
          ],
          visual: _OnboardingVisual.schedule,
        ),
        _OnboardingStep(
          icon: Icons.event_available_outlined,
          title: 'Что означают события',
          description:
              'Цвет и подпись показывают не только рабочие и выходные дни, но и подтверждённые отсутствия.',
          points: [
            '«Вышел на смену» — руководитель подтвердил фактический выход',
            '«Отпуск» и «Больничный» — подтверждённое отсутствие',
            '«Выходной» — смена на этот день не запланирована',
            'Полная расшифровка всегда есть под календарём',
          ],
          visual: _OnboardingVisual.events,
        ),
        _OnboardingStep(
          icon: Icons.calendar_month_outlined,
          title: 'Весь месяц в календаре',
          description:
              'Календарь помогает быстро отличать рабочие дни, выходные и подтверждённые отсутствия.',
          points: [
            'Раскройте «Обозначения», чтобы вспомнить цвета',
            'Нажмите на день, чтобы открыть подробности',
            'Месяцы переключаются стрелками или свайпом',
          ],
          visual: _OnboardingVisual.calendar,
        ),
        _OnboardingStep(
          icon: Icons.school_outlined,
          title: 'Всё готово',
          description:
              'Начните с главной страницы. Если что-то забудется, откройте «Ещё» → «Настройки» → «Обучение сотрудника».',
          points: [
            'Подсказки можно пройти повторно',
            'Тему и главный экран можно настроить под себя',
            'Повторно вводить пароль при обычной работе не требуется',
          ],
          visual: _OnboardingVisual.help,
        ),
      ];

  List<_OnboardingStep> get _managerSteps => const [
        _OnboardingStep(
          icon: Icons.waving_hand_outlined,
          title: 'Обучение руководителя',
          description:
              'Пройдём реальный рабочий цикл: выбрать смену, отметить сотрудников, уточнить время и закрыть день.',
          points: [
            'Обучение займёт около двух минут',
            'Каждый шаг соответствует экрану приложения',
            'Обучение можно повторить в любой момент',
          ],
          visual: _OnboardingVisual.welcome,
        ),
        _OnboardingStep(
          icon: Icons.touch_app_outlined,
          title: 'Рабочие разделы руководителя',
          description:
              'На телефоне основные разделы находятся снизу, остальные — в меню «Ещё». На компьютере всё меню расположено слева.',
          points: [
            'Главная — ближайшие смены и быстрый обзор',
            'График — план и фактические выходы',
            'Календарь — показатели по дням месяца',
            'Ещё — сотрудники, управление и настройки',
          ],
          visual: _OnboardingVisual.navigation,
        ),
        _OnboardingStep(
          icon: Icons.filter_alt_outlined,
          title: 'Найдите нужную смену',
          description:
              'В «Графике» нажмите «Сегодня» или выберите дату. Большой список удобно сократить фильтрами.',
          points: [
            'Подразделение и группа ограничивают участок работы',
            'Должность оставит, например, только сварщиков или специалистов ОТК',
            'Поиск находит сотрудника по фамилии',
            'Скрытые группы можно вернуть в настройках видимости',
          ],
          visual: _OnboardingVisual.schedule,
        ),
        _OnboardingStep(
          icon: Icons.fact_check_outlined,
          title: 'Отметка выхода сотрудников',
          description:
              'В разделе «График» нажмите «Сегодня», затем отмечайте сотрудников по одному или сразу целой группой.',
          points: [
            '«Вышел» подтверждает фактический выход',
            '«Неявка» означает, что сотрудник не вышел',
            'Повторное нажатие выбранного статуса заблокировано',
            'Группу или всю смену можно отметить одним действием',
          ],
          visual: _OnboardingVisual.attendance,
        ),
        _OnboardingStep(
          icon: Icons.more_time_outlined,
          title: 'Опоздание, ранний уход и переработка',
          description:
              'Нажмите значок настроек в строке сотрудника и укажите фактическое начало и окончание работы.',
          points: [
            'Плановое время уже показано для сравнения',
            'Опоздание и ранний уход считаются автоматически',
            'Работа после планового окончания попадёт в переработку',
            'Комментарий объяснит ручную корректировку',
          ],
          visual: _OnboardingVisual.deviations,
        ),
        _OnboardingStep(
          icon: Icons.lock_clock_outlined,
          title: 'Проверьте и закройте день',
          description:
              'До закрытия убедитесь, что показатель «Не заполнено» равен нулю. После закрытия итоги сразу обновятся во всех экранах.',
          points: [
            'Сначала проверьте отсутствующих и неполные смены',
            'Закрытие фиксирует итог дня для дальнейшего табеля',
            'Повторное открытие доступно только пользователю с правом',
          ],
          visual: _OnboardingVisual.closingDay,
        ),
        _OnboardingStep(
          icon: Icons.calendar_month_outlined,
          title: 'Контроль месяца',
          description:
              'В полном календаре каждая ячейка показывает «вышли / план». Цвет линии помогает увидеть проблему без открытия дня.',
          points: [
            'Зелёный — все вышли по плану',
            'Синий — вышла только часть сотрудников',
            'Оранжевый — выход сверх плана',
            'Фильтры ограничивают календарь подразделением, группой или должностью',
          ],
          visual: _OnboardingVisual.calendar,
        ),
        _OnboardingStep(
          icon: Icons.admin_panel_settings_outlined,
          title: 'Сотрудники и доступы',
          description:
              'В «Сотрудниках» редактируется рабочая информация. В «Управлении» создаются логины, роли и ограничения доступа.',
          points: [
            'Нажмите на сотрудника, чтобы открыть его карточку',
            'Логин привязывается к уже созданному сотруднику',
            'Пользователь видит только разрешённые ему данные',
          ],
          visual: _OnboardingVisual.admin,
        ),
        _OnboardingStep(
          icon: Icons.school_outlined,
          title: 'Можно начинать работу',
          description:
              'Откройте «График» → «Сегодня» и пройдите рабочий цикл. Повторное обучение находится в настройках.',
          points: [
            'Сначала примените фильтр своего участка',
            'Затем внесите факт и уточните отклонения времени',
            'Закрывайте день только после итоговой проверки',
          ],
          visual: _OnboardingVisual.help,
        ),
      ];

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await OnboardingService.instance.completeForCurrentUser();
    } catch (_) {
      // Обучение не должно блокировать работу при ошибке локального хранилища.
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _next() async {
    if (_index == _steps.length - 1) {
      await _finish();
      return;
    }
    await _controller.nextPage(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _back() async {
    if (_index == 0) return;
    await _controller.previousPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = MediaQuery.sizeOf(context).width < 700;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.replay,
        title: Text(
          _audience == OnboardingAudience.employee
              ? 'Обучение сотрудника'
              : 'Обучение руководителя',
        ),
        actions: [
          TextButton(
            onPressed: _finishing ? null : _finish,
            child: Text(widget.replay ? 'Закрыть' : 'Пропустить'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                isPhone ? 12 : 24,
                isPhone ? 8 : 20,
                isPhone ? 12 : 24,
                isPhone ? 10 : 20,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: _steps.length,
                      onPageChanged: (index) => setState(() => _index = index),
                      itemBuilder: (context, index) => _StepView(
                        step: _steps[index],
                        audience: _audience,
                        compact: isPhone,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'Шаг ${_index + 1} из ${_steps.length}',
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var index = 0; index < _steps.length; index++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: index == _index ? 24 : 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: index == _index
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (_index > 0)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _finishing ? null : _back,
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('Назад'),
                          ),
                        )
                      else
                        const Spacer(),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: isPhone ? 2 : 1,
                        child: FilledButton.icon(
                          onPressed: _finishing ? null : _next,
                          icon: _finishing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _index == _steps.length - 1
                                      ? Icons.check
                                      : Icons.arrow_forward,
                                ),
                          label: Text(
                            _index == _steps.length - 1
                                ? 'Начать работу'
                                : 'Далее',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepView extends StatelessWidget {
  final _OnboardingStep step;
  final OnboardingAudience audience;
  final bool compact;

  const _StepView({
    required this.step,
    required this.audience,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(compact ? 18 : 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: compact ? 48 : 56,
                    height: compact ? 48 : 56,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(step.icon, color: scheme.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          step.description,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 18 : 24),
              _StepIllustration(
                visual: step.visual,
                audience: audience,
                compact: compact,
              ),
              SizedBox(height: compact ? 18 : 24),
              for (final point in step.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(point)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepIllustration extends StatelessWidget {
  final _OnboardingVisual visual;
  final OnboardingAudience audience;
  final bool compact;

  const _StepIllustration({
    required this.visual,
    required this.audience,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: compact ? 142 : 180),
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: switch (visual) {
        _OnboardingVisual.welcome => _WelcomePreview(audience: audience),
        _OnboardingVisual.navigation => const _NavigationPreview(),
        _OnboardingVisual.schedule => const _SchedulePreview(),
        _OnboardingVisual.events => const _EventsPreview(),
        _OnboardingVisual.attendance => const _AttendancePreview(),
        _OnboardingVisual.deviations => const _DeviationsPreview(),
        _OnboardingVisual.closingDay => const _ClosingDayPreview(),
        _OnboardingVisual.calendar => const _CalendarPreview(),
        _OnboardingVisual.admin => const _AdminPreview(),
        _OnboardingVisual.help => const _HelpPreview(),
      },
    );
  }
}

class _WelcomePreview extends StatelessWidget {
  final OnboardingAudience audience;

  const _WelcomePreview({required this.audience});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          audience == OnboardingAudience.employee
              ? Icons.badge_outlined
              : Icons.groups_2_outlined,
          size: 52,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          audience == OnboardingAudience.employee
              ? 'Ваш личный график всегда под рукой'
              : 'План и факт смен в одном месте',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}

class _NavigationPreview extends StatelessWidget {
  const _NavigationPreview();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.home_outlined, 'Главная'),
      (Icons.calendar_view_week_outlined, 'График'),
      (Icons.calendar_month_outlined, 'Календарь'),
      (Icons.more_horiz, 'Ещё'),
    ];
    return Row(
      children: [
        for (var index = 0; index < items.length; index++)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  items[index].$1,
                  color: index == 0
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 6),
                FittedBox(child: Text(items[index].$2)),
              ],
            ),
          ),
      ],
    );
  }
}

class _SchedulePreview extends StatelessWidget {
  const _SchedulePreview();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final day in const [('Пн', true), ('Вт', true), ('Ср', false)])
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 6),
              decoration: BoxDecoration(
                color: day.$2
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(day.$1),
                  const SizedBox(height: 8),
                  Text(
                    day.$2 ? 'Рабочая смена' : 'Выходной',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _EventsPreview extends StatelessWidget {
  const _EventsPreview();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <(Color, IconData, String)>[
      (scheme.primary, Icons.work_outline, 'Рабочая смена'),
      (Colors.green, Icons.check_circle_outline, 'Вышел на смену'),
      (Colors.teal, Icons.beach_access_outlined, 'Отпуск'),
      (Colors.deepPurple, Icons.medical_services_outlined, 'Больничный'),
      (scheme.outline, Icons.weekend_outlined, 'Выходной'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: item.$1.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: item.$1.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.$2, size: 18, color: item.$1),
                const SizedBox(width: 7),
                Text(item.$3),
              ],
            ),
          ),
      ],
    );
  }
}

class _AttendancePreview extends StatelessWidget {
  const _AttendancePreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _MetricPreview(label: 'По плану', value: '12'),
            _MetricPreview(label: 'Вышли', value: '10'),
            _MetricPreview(label: 'Не заполнено', value: '2'),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: null,
              icon: const Icon(Icons.done_all),
              label: const Text('Отметить группу'),
            ),
            OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Закрыть день'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeviationsPreview extends StatelessWidget {
  const _DeviationsPreview();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'План: 08:00–17:00',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _TimePreview(
                label: 'Начало',
                value: '08:20',
                color: scheme.error,
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: _TimePreview(
                label: 'Окончание',
                value: '18:00',
                color: Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('Опоздание 20 мин')),
            Chip(label: Text('Переработка 60 мин')),
          ],
        ),
      ],
    );
  }
}

class _TimePreview extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _TimePreview({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _ClosingDayPreview extends StatelessWidget {
  const _ClosingDayPreview();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Row(
          children: [
            _MetricPreview(label: 'По плану', value: '12'),
            _MetricPreview(label: 'Вышли', value: '11'),
            _MetricPreview(label: 'Неявка', value: '1'),
            _MetricPreview(label: 'Не заполнено', value: '0'),
          ],
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.lock_outline),
          label: const Text('Закрыть день'),
          style: FilledButton.styleFrom(
            disabledBackgroundColor: scheme.primaryContainer,
            disabledForegroundColor: scheme.onPrimaryContainer,
          ),
        ),
      ],
    );
  }
}

class _MetricPreview extends StatelessWidget {
  final String label;
  final String value;

  const _MetricPreview({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _CalendarPreview extends StatelessWidget {
  const _CalendarPreview();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('август', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final item in const [
              ('17', '12/12'),
              ('18', '8/12'),
              ('19', '—')
            ])
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: primary.withValues(alpha: 0.4)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(item.$1),
                      const SizedBox(height: 7),
                      Text(
                        item.$2,
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AdminPreview extends StatelessWidget {
  const _AdminPreview();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _AdminRow(icon: Icons.people_outline, label: 'Сотрудники'),
        SizedBox(height: 8),
        _AdminRow(icon: Icons.key_outlined, label: 'Логины и роли'),
        SizedBox(height: 8),
        _AdminRow(icon: Icons.account_tree_outlined, label: 'Группы и отделы'),
      ],
    );
  }
}

class _AdminRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _AdminRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class _HelpPreview extends StatelessWidget {
  const _HelpPreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.help_outline,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 10),
        Text(
          'Настройки → Обучение и помощь',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}
