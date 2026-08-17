import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_service.dart';
import '../dashboard/dashboard_customizer.dart';
import 'preferences_service.dart';

class PreferencesPage extends StatefulWidget {
  const PreferencesPage({super.key});

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  final _preferences = PreferencesService.instance;

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_changed);
  }

  @override
  void dispose() {
    _preferences.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final repeat = TextEditingController();
    String? inlineError;

    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Сменить пароль'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: current,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Текущий пароль'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: next,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Новый пароль',
                    helperText: 'Не менее 10 символов',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: repeat,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Повторите пароль'),
                ),
                if (inlineError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    inlineError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                if (next.text.length < 10) {
                  setDialogState(() => inlineError = 'Пароль слишком короткий');
                  return;
                }
                if (next.text != repeat.text) {
                  setDialogState(() => inlineError = 'Пароли не совпадают');
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Сменить'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return;
    final error = await AuthService.instance.changePassword(
      currentPassword: current.text,
      newPassword: next.text,
    );
    if (!mounted) return;
    if (error == null) {
      context.go('/login');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
            'Для продолжения потребуется снова ввести логин и пароль.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AuthService.instance.logout();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final user = AuthService.instance.currentUser;
    final role = AuthService.instance.roleById(user?.roleId);

    return AdaptiveScaffold(
      title: 'Настройки',
      selectedRoute: '/settings',
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 12 : 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Внешний вид',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Тема применяется сразу и сохраняется для вашей учётной записи.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth < 680
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 24) / 3;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final choice in AppThemeChoice.values)
                          SizedBox(
                            width: width,
                            child: _ThemeChoiceCard(
                              choice: choice,
                              selected: _preferences.theme == choice,
                              onTap: () => _preferences.setTheme(choice),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 28),
                Text('Главный экран',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Выберите виджеты, их порядок и размеры отдельно для компьютера и телефона.',
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => DashboardCustomizer.show(
                                context,
                                mobile: false,
                              ),
                              icon: const Icon(Icons.desktop_windows_outlined),
                              label: const Text('Настроить для компьютера'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => DashboardCustomizer.show(
                                context,
                                mobile: true,
                              ),
                              icon: const Icon(Icons.smartphone_outlined),
                              label: const Text('Настроить для телефона'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text('Учётная запись',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            child: Text(_initials(
                                user?.fullName ?? user?.login ?? 'U')),
                          ),
                          title: Text(user?.fullName ?? user?.login ?? '—'),
                          subtitle: Text(
                              '${role?.name ?? '—'} · ${user?.login ?? '—'}'),
                        ),
                        const Divider(),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _changePassword,
                                icon: const Icon(Icons.password),
                                label: const Text('Сменить пароль'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _logout,
                                icon: const Icon(Icons.logout),
                                label: const Text('Выйти'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_preferences.saving) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (_preferences.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(_preferences.lastError!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty);
    return parts.take(2).map((x) => x[0].toUpperCase()).join();
  }
}

class _ThemeChoiceCard extends StatelessWidget {
  final AppThemeChoice choice;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeChoiceCard({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final preview = switch (choice) {
      AppThemeChoice.light => const [
          Color(0xFFF6F8FC),
          Colors.white,
          Color(0xFF101828),
        ],
      AppThemeChoice.dim => const [
          Color(0xFF1A202B),
          Color(0xFF303A49),
          Color(0xFFF1F4F8),
        ],
      AppThemeChoice.dark => const [
          Color(0xFF080B11),
          Color(0xFF1A2230),
          Color(0xFFF7F9FC),
        ],
    };
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 84,
                decoration: BoxDecoration(
                  color: preview[0],
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      decoration: BoxDecoration(
                        color: preview[1],
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(height: 8, width: 50, color: preview[2]),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: preview[1],
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(choice.icon, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(choice.label,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (selected)
                    Icon(Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
