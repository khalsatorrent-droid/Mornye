import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/stremio/stremio_addon_controller.dart';
import 'package:mornye/services/stremio/stremio_addon_settings.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Settings for the Stremio add-on: on/off, port, and the addresses to
/// install from.
class StremioAddonPage extends ConsumerStatefulWidget {
  const StremioAddonPage({super.key});

  @override
  ConsumerState<StremioAddonPage> createState() => _StremioAddonPageState();
}

class _StremioAddonPageState extends ConsumerState<StremioAddonPage> {
  late final TextEditingController _portController;
  bool _portInvalid = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: ref.read(stremioAddonSettingsProvider).port.toString(),
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
        value < StremioAddonSettings.minPort ||
        value > StremioAddonSettings.maxPort) {
      setState(() => _portInvalid = true);
      return;
    }
    setState(() => _portInvalid = false);
    await ref.read(stremioAddonSettingsProvider.notifier).setPort(value);
    await ref.read(stremioAddonControllerProvider.notifier).restart();
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
    final settings = ref.watch(stremioAddonSettingsProvider);
    final status = ref.watch(stremioAddonControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final manifestUrls = status.manifestUrls;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const AppSliverHeader.page(title: 'Stremio add-on'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Serve the same catalogue the app shows as a Stremio add-on on '
                'your local network. Pick a source in Stremio and the track is '
                'downloaded into your library, then streamed from there.',
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
                          .read(stremioAddonSettingsProvider.notifier)
                          .setEnabled(value),
                      title: const Text('Serve add-on on this network'),
                      subtitle: Text(
                        'Listens on all interfaces so a TV or computer running '
                        'Stremio can reach it.',
                      ),
                    ),
                    ListTile(
                      title: const Text('Port'),
                      subtitle: _portInvalid
                          ? Text(
                              'Enter a port between '
                              '${StremioAddonSettings.minPort} and '
                              '${StremioAddonSettings.maxPort}',
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
                      onTap: () => ref
                          .read(stremioAddonControllerProvider.notifier)
                          .restart(),
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
                    'In Stremio, open Add-ons → Install from URL and paste one '
                    'of the manifest URLs above. Both devices must be on the '
                    'same network. Downloads use the providers you enabled in '
                    'Settings → Extensions, in your configured quality order.',
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
