import 'dart:io';

void main() {
  final files = [
    '/home/nikhil/Desktop/atmos-app/lib/screens/details_screen.dart',
    '/home/nikhil/Desktop/atmos-app/lib/screens/player_screen.dart'
  ];

  for (final path in files) {
    var content = File(path).readAsStringSync();
    
    content = content.replaceAll('Theme.of(context).colorScheme.surface', 'Theme.of(context).colorScheme.surface');
    content = content.replaceAll('Theme.of(context).colorScheme.surfaceContainer', 'Theme.of(context).colorScheme.surfaceContainer');
    content = content.replaceAll('Theme.of(context).colorScheme.surfaceContainerHigh', 'Theme.of(context).colorScheme.surfaceContainerHigh');
    content = content.replaceAll('Theme.of(context).colorScheme.onSurface', 'Theme.of(context).colorScheme.onSurface');
    content = content.replaceAll('Theme.of(context).colorScheme.onSurfaceVariant', 'Theme.of(context).colorScheme.onSurfaceVariant');
    content = content.replaceAll('Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)', 'Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)');
    content = content.replaceAll('Theme.of(context).colorScheme.primary', 'Theme.of(context).colorScheme.primary');
    content = content.replaceAll('Theme.of(context).colorScheme.outlineVariant', 'Theme.of(context).colorScheme.outlineVariant');
    content = content.replaceAll('Colors.amber.shade400', 'Colors.amber.shade400');
    content = content.replaceAll('Theme.of(context).colorScheme.primaryGradient', 'Theme.of(context).colorScheme.primaryGradient(Theme.of(context).colorScheme)');
    content = content.replaceAll('AtmosTheme.heroGradient', 'AtmosTheme.heroGradient(Theme.of(context).colorScheme)');
    content = content.replaceAll("import '../theme/app_tokens.dart';", "import '../theme/app_tokens.dart';");
    content = content.replaceAll('context.isExpanded', 'context.isExpanded');
    
    File(path).writeAsStringSync(content);
  }
}
