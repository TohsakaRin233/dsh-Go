// About DSH Go: app information, the original author and personal profiles,
// then the brand mark, slogan and unofficial-app disclaimer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/update_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../star/star_prompt_dialog.dart' show openStarProject;
import '../theme/theme.dart';
import '../update/update_tiles.dart';
import 'settings_widgets.dart';

/// The installed version as the app shows it: `0.9.6 (10271234)`.
String installedVersionLabel(WidgetRef ref) {
  // What Android reports as installed (the compiled-in constant until it does).
  final installed = ref.watch(appUpdateProvider.select((s) => s.current));
  return installed.build == null ? installed.name : '${installed.name} (${installed.build})';
}

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final version = installedVersionLabel(ref);
    return AppPage.list(
      title: l10n.hubAbout,
      children: [
        SettingsSection(
          children: [
            SettingsTile(
              spot: Spots.version,
              value: Text(version, style: AppType.tabular(theme.textTheme.bodyMedium!)),
            ),
            const AppUpdateTiles(),
            SettingsTile(
              key: const ValueKey('settings-star'),
              spot: Spots.star,
              onTap: () => unawaited(
                openStarProject(ProviderScope.containerOf(context, listen: false), ScaffoldMessenger.maybeOf(context)),
              ),
            ),
            SettingsTile(
              spot: Spots.licenses,
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: version,
                applicationIcon: const Padding(padding: EdgeInsets.all(12), child: BrandMark(size: 56, tile: true)),
                applicationLegalese: AppInfo.disclaimer,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            children: [
              BrandMark(size: 18, color: colors.textDisabled),
              const SizedBox(height: 10),
              Text(
                AppInfo.slogan,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
              const SizedBox(height: 8),
              Text(
                AppInfo.disclaimer,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }


}
