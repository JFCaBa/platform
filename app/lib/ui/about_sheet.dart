import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// "1.5.0 (13)": the version and build installed, so a tester can tell builds apart.
/// Read once: it cannot change while the app runs.
Future<String> installedVersion() => _version ??= PackageInfo.fromPlatform()
    .then((p) => p.buildNumber.isEmpty ? p.version : '${p.version} (${p.buildNumber})');
Future<String>? _version;

/// The data source, privacy and version, one tap away instead of at the end of a long list.
Future<void> showAboutSheet(BuildContext context, {required String attribution, required VoidCallback onPrivacy}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What Platform', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                FutureBuilder<String>(
                  future: installedVersion(),
                  builder: (context, v) => Text(v.hasData ? 'Version ${v.data}' : ' ', style: muted),
                ),
                const SizedBox(height: 12),
                Text(attribution, style: muted),
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  onPressed: () {
                    Navigator.of(context).pop();
                    onPrivacy();
                  },
                  child: const Text('Privacy policy'),
                ),
              ],
            ),
          ),
        );
      },
    );
