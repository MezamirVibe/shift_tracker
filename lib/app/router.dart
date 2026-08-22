import 'package:go_router/go_router.dart';

import '../features/auth/auth_models.dart';
import '../features/auth/auth_service.dart';
import '../features/auth/bootstrap_admin_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/splash_page.dart';

import '../features/admin/admin_page.dart' as adm;
import '../features/calendar/calendar_page.dart' as cal;
import '../features/dashboard/dashboard_page.dart' as dashboard;
import '../features/day/day_page.dart' as day;
import '../features/employees/employee_details_page.dart' as emp_details;
import '../features/employees/employees_page.dart' as emp;
import '../features/preferences/preferences_page.dart' as preferences;

class AppRouter {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String bootstrap = '/bootstrap';

  static const String dashboardPath = '/';
  static const String calendar = '/schedule';
  static const String fullCalendar = '/calendar';
  static const String dayPath = '/day';
  static const String employees = '/employees';
  static const String employee = '/employee';
  static const String admin = '/admin';
  static const String settings = '/settings';

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
          return dashboardPath;
        }

        final currentRole = auth.roleById(auth.currentUser?.roleId);
        if (loc.startsWith('$dayPath/') &&
            currentRole?.scopeKind == ScopeKind.self) {
          return calendar;
        }

        // ВАЖНО:
        // Не выбрасываем пользователя с /admin во время notifyListeners().
        // Доступ внутри админки обрабатывает сам AdminPage.
        return null;
      },
      routes: [
        GoRoute(
          path: splash,
          builder: (_, __) => const SplashPage(),
        ),
        GoRoute(
          path: login,
          builder: (_, __) => const LoginPage(),
        ),
        GoRoute(
          path: bootstrap,
          builder: (_, __) => const BootstrapAdminPage(),
        ),
        GoRoute(
          path: admin,
          builder: (_, __) => const adm.AdminPage(),
        ),
        GoRoute(
          path: dashboardPath,
          builder: (_, __) => const dashboard.DashboardPage(),
        ),
        GoRoute(
          path: calendar,
          builder: (_, __) => const cal.CalendarPage(),
        ),
        GoRoute(
          path: fullCalendar,
          builder: (_, __) => const cal.CalendarPage(fullView: true),
        ),
        GoRoute(
          path: settings,
          builder: (_, __) => const preferences.PreferencesPage(),
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
