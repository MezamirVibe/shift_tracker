import 'package:go_router/go_router.dart';

import '../features/admin/admin_page.dart';
import '../features/auth/auth_models.dart';
import '../features/auth/auth_service.dart';
import '../features/auth/bootstrap_admin_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/splash_page.dart';

// ✅ Алиасы — чтобы никогда не ловить конфликт имён
import '../features/calendar/calendar_page.dart' as cal;
import '../features/day/day_page.dart' as day;
import '../features/employees/employees_page.dart' as emp;
import '../features/employees/employee_details_page.dart' as emp_details;

class AppRouter {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String bootstrap = '/bootstrap';

  static const String calendar = '/';
  static const String dayPath = '/day';
  static const String employees = '/employees';
  static const String employee = '/employee';
  static const String admin = '/admin';

  static GoRouter makeRouter() {
    final auth = AuthService.instance;

    return GoRouter(
      initialLocation: splash,
      refreshListenable: auth,
      redirect: (_, state) {
        final loc = state.uri.toString();

        if (!auth.initialized) {
          return loc == splash ? null : splash;
        }

        final isAuthRoute =
            loc == splash || loc.startsWith(login) || loc.startsWith(bootstrap);

        if (!auth.hasUsers) {
          return loc == bootstrap ? null : bootstrap;
        }

        if (!auth.isLoggedIn) {
          return isAuthRoute ? null : login;
        }

        if (isAuthRoute) {
          return calendar;
        }

        // guard admin
        if (loc.startsWith(admin)) {
          final can = auth.currentUser?.role == UserRole.superAdmin ||
              auth.hasPerm(AppPermission.manageUsers) ||
              auth.hasPerm(AppPermission.editRolePolicies);

          if (!can) return calendar;
        }

        return null;
      },
      routes: [
        GoRoute(path: splash, builder: (_, __) => const SplashPage()),
        GoRoute(path: login, builder: (_, __) => const LoginPage()),
        GoRoute(
            path: bootstrap, builder: (_, __) => const BootstrapAdminPage()),
        GoRoute(path: admin, builder: (_, __) => const AdminPage()),
        GoRoute(
          path: calendar,
          builder: (_, __) => const cal.CalendarPage(),
        ),
        GoRoute(
          path: '$dayPath/:date',
          builder: (_, state) {
            final dateStr = state.pathParameters['date']!;
            return day.DayPage(dateIso: dateStr);
          },
        ),
        GoRoute(
          path: employees,
          builder: (_, __) => const emp.EmployeesPage(),
        ),
        GoRoute(
          path: '$employee/:id',
          builder: (_, state) {
            final id = state.pathParameters['id']!;
            return emp_details.EmployeeDetailsPage(id: id);
          },
        ),
      ],
    );
  }
}
