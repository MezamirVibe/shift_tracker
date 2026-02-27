import 'package:flutter/material.dart';

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

class _AdminPageState extends State<AdminPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    final canUsers = auth.currentUser?.role == UserRole.superAdmin || auth.hasPerm(AppPermission.manageUsers);
    final canRoles = auth.currentUser?.role == UserRole.superAdmin || auth.hasPerm(AppPermission.editRolePolicies);
    final canStructure = auth.currentUser?.role == UserRole.superAdmin || auth.hasPerm(AppPermission.editEmployees);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Администрирование'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Пользователи'),
            Tab(text: 'Роли и права'),
            Tab(text: 'Структура'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          canUsers ? const UsersAdminPage() : const _NoAccess(text: 'Нет прав на управление пользователями'),
          canRoles ? const RolesEditorPage() : const _NoAccess(text: 'Нет прав на настройку ролей'),
          canStructure ? const StructurePage() : const _NoAccess(text: 'Нет прав на изменение структуры'),
        ],
      ),
    );
  }
}

class _NoAccess extends StatelessWidget {
  final String text;
  const _NoAccess({required this.text});

  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}