import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../structure/structure_page.dart';
import 'roles_editor_page.dart';
import 'users_admin_page.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    final tabs = _buildTabs(auth);
    final views = _buildViews(auth);

    final safeLength = tabs.isEmpty ? 1 : tabs.length;
    final safeTabs = tabs.isEmpty ? const [Tab(text: 'Нет доступа')] : tabs;
    final safeViews = views.isEmpty
        ? const [
            Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'У вас нет доступа к разделу администрирования.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ]
        : views;

    return DefaultTabController(
      length: safeLength,
      child: AdaptiveScaffold(
        title: 'Администрирование',
        selectedIndex: 2,
        items: [
          NavItem(
            label: 'Календарь',
            icon: Icons.calendar_month,
            onTap: () => context.go('/'),
          ),
          NavItem(
            label: 'Сотрудники',
            icon: Icons.people,
            onTap: () => context.go('/employees'),
          ),
          NavItem(
            label: 'Админ',
            icon: Icons.admin_panel_settings,
            onTap: () => context.go('/admin'),
          ),
        ],
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                isScrollable: true,
                tabs: safeTabs,
              ),
            ),
            Expanded(
              child: TabBarView(
                children: safeViews,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Tab> _buildTabs(AuthService auth) {
    final tabs = <Tab>[];

    if (_canManageUsers(auth)) {
      tabs.add(const Tab(text: 'Пользователи'));
    }

    if (_canManageStructure(auth)) {
      tabs.add(const Tab(text: 'Структура'));
    }

    if (_canEditRolePolicies(auth)) {
      tabs.add(const Tab(text: 'Роли и права'));
    }

    return tabs;
  }

  List<Widget> _buildViews(AuthService auth) {
    final views = <Widget>[];

    if (_canManageUsers(auth)) {
      views.add(const UsersAdminPage());
    }

    if (_canManageStructure(auth)) {
      views.add(const StructurePage());
    }

    if (_canEditRolePolicies(auth)) {
      views.add(const RolesEditorPage());
    }

    return views;
  }

  bool _canManageUsers(AuthService auth) {
    return auth.isCurrentUserSuperAdmin ||
        auth.hasPerm(AppPermission.manageUsers);
  }

  bool _canEditRolePolicies(AuthService auth) {
    return auth.isCurrentUserSuperAdmin ||
        auth.hasPerm(AppPermission.editRolePolicies);
  }

  bool _canManageStructure(AuthService auth) {
    return auth.isCurrentUserSuperAdmin ||
        auth.hasPerm(AppPermission.editEmployees) ||
        auth.hasPerm(AppPermission.manageUsers);
  }
}