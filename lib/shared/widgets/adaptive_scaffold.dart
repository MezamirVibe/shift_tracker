import 'package:flutter/material.dart';

class NavItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const NavItem({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class AdaptiveScaffold extends StatelessWidget {
  final String title;
  final int selectedIndex;
  final List<NavItem> items;
  final List<Widget> actions;
  final Widget child;

  final Widget? floatingActionButton;

  const AdaptiveScaffold({
    super.key,
    required this.title,
    required this.selectedIndex,
    required this.items,
    required this.child,
    this.actions = const [],
    this.floatingActionButton,
  });

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 900;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);

    if (!desktop) {
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: actions,
        ),
        body: child,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (idx) => items[idx].onTap(),
          destinations: [
            for (final item in items)
              NavigationDestination(
                icon: Icon(item.icon),
                label: item.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (idx) => items[idx].onTap(),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final item in items)
                NavigationRailDestination(
                  icon: Icon(item.icon),
                  label: Text(item.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Scaffold(
              appBar: AppBar(
                title: Text(title),
                actions: actions,
              ),
              body: child,
              floatingActionButton: floatingActionButton,
            ),
          ),
        ],
      ),
    );
  }
}
