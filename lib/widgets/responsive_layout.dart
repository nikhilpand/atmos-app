import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

export '../theme/app_tokens.dart';

// ─── Navigation Destination Config ───────────────────────────────────────────

class NavDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String route;

  const NavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.route,
  });
}

const kNavDestinations = <NavDestination>[
  NavDestination(
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    route: '/',
  ),
  NavDestination(
    label: 'Search',
    icon: Icons.search_outlined,
    selectedIcon: Icons.search_rounded,
    route: '/search',
  ),
  NavDestination(
    label: 'Watchlist',
    icon: Icons.bookmark_border_rounded,
    selectedIcon: Icons.bookmark_rounded,
    route: '/watchlist',
  ),
  NavDestination(
    label: 'Downloads',
    icon: Icons.download_outlined,
    selectedIcon: Icons.download_rounded,
    route: '/downloads',
  ),
  NavDestination(
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    route: '/settings',
  ),
];

// ─── Adaptive Shell ───────────────────────────────────────────────────────────
// Wraps a page body with the correct navigation pattern for each form factor:
//   • Phone (< 600px wide):  NavigationBar at the bottom
//   • Tablet (600–1200px):   NavigationRail on the left, no labels
//   • TV / large (≥ 1200px): NavigationDrawer (extended rail with labels)

class AdaptiveShell extends StatelessWidget {
  final Widget body;
  final int selectedIndex;
  final void Function(int) onDestinationSelected;

  const AdaptiveShell({
    super.key,
    required this.body,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    if (width >= AppBreakpoints.expanded) {
      return _ExtendedRailLayout(
        body: body,
        selectedIndex: selectedIndex,
        onSelected: onDestinationSelected,
      );
    }
    if (width >= AppBreakpoints.compact) {
      return _RailLayout(
        body: body,
        selectedIndex: selectedIndex,
        onSelected: onDestinationSelected,
      );
    }
    return _BottomBarLayout(
      body: body,
      selectedIndex: selectedIndex,
      onSelected: onDestinationSelected,
    );
  }
}

// ── Phone: bottom NavigationBar ───────────────────────────────────────────────

class _BottomBarLayout extends StatelessWidget {
  final Widget body;
  final int selectedIndex;
  final void Function(int) onSelected;
  const _BottomBarLayout({required this.body, required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelected,
        destinations: kNavDestinations.map((d) => NavigationDestination(
          icon: Icon(d.icon),
          selectedIcon: Icon(d.selectedIcon),
          label: d.label,
        )).toList(),
      ),
    );
  }
}

// ── Tablet: compact NavigationRail ────────────────────────────────────────────

class _RailLayout extends StatelessWidget {
  final Widget body;
  final int selectedIndex;
  final void Function(int) onSelected;
  const _RailLayout({required this.body, required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          labelType: NavigationRailLabelType.selected,
          destinations: kNavDestinations.map((d) => NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          )).toList(),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: body),
      ]),
    );
  }
}

// ── TV / Large: extended NavigationRail ───────────────────────────────────────

class _ExtendedRailLayout extends StatelessWidget {
  final Widget body;
  final int selectedIndex;
  final void Function(int) onSelected;
  const _ExtendedRailLayout({required this.body, required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          extended: true,
          minExtendedWidth: 200,
          leading: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.lg,
              horizontal: AppSpacing.md,
            ),
            child: Row(children: [
              Icon(Icons.movie_filter_rounded,
                  color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(width: AppSpacing.sm),
              Text('Atmos',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.primary,
                  )),
            ]),
          ),
          destinations: kNavDestinations.map((d) => NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          )).toList(),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: body),
      ]),
    );
  }
}

// ─── Single-page wrapper (for screens that don't use the shell) ────────────────
// e.g. DetailsScreen, PlayerScreen — they fill the full area.

class PageFrame extends StatelessWidget {
  final Widget child;
  const PageFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= AppBreakpoints.expanded) {
      // On large screens, horizontally constrain content like a website.
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: child,
        ),
      );
    }
    return child;
  }
}
