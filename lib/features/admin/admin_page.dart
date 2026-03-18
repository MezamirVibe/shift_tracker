import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../structure/structure_page.dart';
import 'roles_editor_page.dart';
import 'users_admin_page.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  bool get _canManageUsers =>
      AuthService.instance.currentUser?.role == UserRole.superAdmin ||
      AuthService.instance.hasPerm(AppPermission.manageUsers);

  bool get _canEditRolePolicies =>
      AuthService.instance.currentUser?.role == UserRole.superAdmin ||
      AuthService.instance.hasPerm(AppPermission.editRolePolicies);

  bool get _canManageStructure =>
      AuthService.instance.currentUser?.role == UserRole.superAdmin ||
      AuthService.instance.hasPerm(AppPermission.editEmployees) ||
      AuthService.instance.hasPerm(AppPermission.manageUsers);

  @override
  void initState() {
    super.initState();

    final tabCount = (_canManageUsers ? 1 : 0) +
        (_canEditRolePolicies ? 1 : 0) +
        (_canManageStructure ? 1 : 0);

    _tabController = TabController(
      length: tabCount == 0 ? 1 : tabCount,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Tab> _buildTabs() {
    final tabs = <Tab>[];

    if (_canManageUsers) {
      tabs.add(const Tab(text: 'Пользователи'));
    }

    if (_canManageStructure) {
      tabs.add(const Tab(text: 'Структура'));
    }

    if (_canEditRolePolicies) {
      tabs.add(const Tab(text: 'Роли и права'));
    }

    if (tabs.isEmpty) {
      tabs.add(const Tab(text: 'Нет доступа'));
    }

    return tabs;
  }

  List<Widget> _buildViews() {
    final views = <Widget>[];

    if (_canManageUsers) {
      views.add(const UsersAdminPage());
    }

    if (_canManageStructure) {
      views.add(const StructurePage());
    }

    if (_canEditRolePolicies) {
      views.add(const RolesEditorPage());
    }

    if (views.isEmpty) {
      views.add(
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'У вас нет доступа к разделу администрирования.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return views;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _buildTabs();
    final views = _buildViews();

    return AdaptiveScaffold(
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
              controller: _tabController,
              tabs: tabs,
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: views,
            ),
          ),
        ],
      ),
    );
  }
}