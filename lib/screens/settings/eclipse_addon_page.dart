import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/addon/addon_controller.dart';
import 'package:mornye/services/addon/addon_settings.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Settings for the Eclipse add-on: on/off, port, download source and the
/// addresses to install from.
class EclipseAddonPage extends ConsumerStatefulWidget {
  const EclipseAddonPage({super.key});

  @override
  ConsumerState<EclipseAddonPage> createState() => _EclipseAddonPageState();
}

class _EclipseAddonPageState extends ConsumerState<EclipseAddonPage> {
  late final TextEditingController _portController;
  bool _portInvalid = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: ref.read(addonSettingsProvider).port.toString(),
    );
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _applyPort() async {
    final value = int.tryParse(_portController.text.trim());
    if (value == null ||
        value < AddonSettings.minPort ||
        value > AddonSettings.maxPort) {
      setState(() => _portInvalid = true);
      return;
    }
    setState(() => _portInvalid = false);
    await ref.read(addonSettingsProvider.notifier).setPort(value);
    await ref.read(addonControllerProvider.notifier).restart();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(addonSettingsProvider);
    final status = ref.watch(addonControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final manifestUrls = status.manifestUrls;
    final sources = ref
        .watch(extensionProvider.select((state) => state.extensions))
        .where(
          (extension) => extension.enabled && extension.hasDownloadProvider,
        )
        .toList(growable: false);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const AppSliverHeader.page(title: 'Eclipse add-on'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Serve the same catalogue the app shows as an add-on for '
                'Eclipse Music. Pick a track there and it is downloaded into '
                'your library, then streamed from there.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsGroup(
                  children: [
                    AppSwitchListTile(
                      value: settings.enabled,
                      onChanged: (value) => ref
                          .read(addonSettingsProvider.notifier)
                          .setEnabled(value),
                      title: const Text('Serve add-on on this network'),
                      subtitle: const Text(
                        'Listens on all interfaces so Eclipse on a phone, '
                        'tablet or computer can reach it.',
                      ),
                    ),
                    ListTile(
                      title: const Text('Port'),
                      subtitle: _portInvalid
                          ? Text(
                              'Enter a port between '
                              '${AddonSettings.minPort} and '
                              '${AddonSettings.maxPort}',
                              style: TextStyle(color: colorScheme.error),
                            )
                          : const Text('Default 8089'),
                      trailing: SizedBox(
                        width: 104,
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.end,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onSubmitted: (_) => _applyPort(),
                          onEditingComplete: _applyPort,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ),
                    ListTile(
                      title: const Text('Download source'),
                      subtitle: Text(
                        settings.source.isEmpty
                            ? 'Default service from Settings → Download'
                            : sources
                                      .where((ext) => ext.id == settings.source)
                                      .map((ext) => ext.displayName)
                                      .firstOrNull ??
                                  settings.source,
                      ),
                      trailing: const Icon(Icons.arrow_drop_down),
                      onTap: sources.isEmpty
                          ? null
                          : () async {
                              final picked = await showModalBottomSheet<String>(
                                context: context,
                                builder: (context) => SafeArea(
                                  child: ListView(
                                    shrinkWrap: true,
                                    children: [
                                      ListTile(
                                        title: const Text('Default service'),
                                        subtitle: const Text(
                                          'Whatever Settings → Download uses',
                                        ),
                                        selected: settings.source.isEmpty,
                                        onTap: () => Navigator.pop(context, ''),
                                      ),
                                      for (final extension in sources)
                                        ListTile(
                                          title: Text(extension.displayName),
                                          selected:
                                              extension.id == settings.source,
                                          onTap: () => Navigator.pop(
                                            context,
                                            extension.id,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                              if (picked == null) return;
                              await ref
                                  .read(addonSettingsProvider.notifier)
                                  .setSource(picked);
                            },
                    ),
                  ],
                ),
                SettingsGroup(
                  children: [
                    ListTile(
                      leading: Icon(
                        status.running
                            ? Icons.check_circle
                            : Icons.pause_circle_outline,
                        color: status.running
                            ? Colors.green
                            : colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        status.running
                            ? 'Running on port ${status.port}'
                            : 'Not running',
                      ),
                      subtitle: status.error == null
                          ? Text(
                              status.running
                                  ? 'Keep Mornye open while you stream.'
                                  : 'Turn the switch on to start the server.',
                            )
                          : Text(
                              status.error!,
                              style: TextStyle(color: colorScheme.error),
                            ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.refresh),
                      title: const Text('Restart server'),
                      subtitle: const Text(
                        'Use this after changing the port or the network.',
                      ),
                      onTap: () =>
                          ref.read(addonControllerProvider.notifier).restart(),
                    ),
                  ],
                ),
                if (manifestUrls.isNotEmpty)
                  SettingsGroup(
                    children: [
                      for (final url in manifestUrls)
                        ListTile(
                          leading: const Icon(Icons.link),
                          title: Text(url),
                          subtitle: const Text('Manifest URL'),
                          trailing: IconButton(
                            tooltip: 'Copy',
                            icon: const Icon(Icons.copy),
                            onPressed: () => _copy(url),
                          ),
                        ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Text(
                    'In Eclipse Music open Settings → Connections → Add '
                    'Connection → Addon and paste one of the manifest URLs '
                    'above. Both devices must be on the same network. '
                    'Downloads use the source picked here, with the quality '
                    'settings from Settings → Download.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
