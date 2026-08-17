import 'package:flutter/material.dart';

import '../../shared/widgets/adaptive_scaffold.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../structure/structure_page.dart';
import 'positions_page.dart';
import 'roles_editor_page.dart';
import 'users_admin_page.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    final tabs = _buildTabs(auth);
    final views = _buildViews(auth);

    final int safeLength = tabs.isEmpty ? 1 : tabs.length;
    final List<Tab> safeTabs =
        tabs.isEmpty ? <Tab>[const Tab(text: 'Нет доступа')] : tabs;
    final List<Widget> safeViews = views.isEmpty
        ? <Widget>[
            const Center(
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
        selectedRoute: '/admin',
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Icon(Icons.tune),
                      Text(
                        'Здесь настраиваются пользователи, роли, структура и справочник должностей.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
      tabs.add(const Tab(text: 'Должности'));
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
      views.add(const PositionsPage());
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
