import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/stremio/stremio_addon_settings.dart';
import 'package:mornye/services/stremio/stremio_server.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('StremioAddon');

/// What the add-on server is doing right now, for the Settings page.
class StremioAddonStatus {
  const StremioAddonStatus({
    this.running = false,
    this.port = StremioAddonSettings.defaultPort,
    this.urls = const [],
    this.error,
  });

  final bool running;
  final int port;

  /// Every address another device on the network can use, private ranges first.
  final List<String> urls;

  final String? error;

  List<String> get manifestUrls => [
    for (final url in urls) '$url/manifest.json',
  ];
}

/// Starts and stops the add-on server as the setting changes.
///
/// Watching this provider in the app root keeps the server alive for the whole
/// session; the settings page reads its state to show the addresses.
class StremioAddonController extends Notifier<StremioAddonStatus> {
  StremioAddonServer? _server;
  int _generation = 0;

  @override
  StremioAddonStatus build() {
    final settings = ref.watch(stremioAddonSettingsProvider);
    ref.onDispose(() => unawaited(_stop()));
    unawaited(_apply(settings));
    return const StremioAddonStatus();
  }

  /// Restarts the server, e.g. after a port that was already taken.
  Future<void> restart() => _apply(ref.read(stremioAddonSettingsProvider));

  Future<void> _apply(StremioAddonSettings settings) async {
    final generation = ++_generation;

    if (!settings.enabled) {
      await _stop();
      if (generation != _generation) return;
      state = StremioAddonStatus(port: settings.port);
      return;
    }

    final current = _server;
    if (current != null && current.isRunning && current.port == settings.port) {
      final urls = await stremioLanUrls(settings.port);
      if (generation != _generation) return;
      state = StremioAddonStatus(
        running: true,
        port: settings.port,
        urls: urls,
      );
      return;
    }

    await _stop();
    final server = StremioAddonServer(ref: ref, port: settings.port);
    try {
      await server.start();
    } catch (error) {
      _log.w('Could not start the add-on on port ${settings.port}: $error');
      if (generation != _generation) return;
      state = StremioAddonStatus(
        port: settings.port,
        error: 'Could not listen on port ${settings.port}. $error',
      );
      return;
    }

    if (generation != _generation) {
      await server.stop();
      return;
    }
    _server = server;
    final urls = await stremioLanUrls(settings.port);
    if (generation != _generation) return;
    state = StremioAddonStatus(running: true, port: settings.port, urls: urls);
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    await server?.stop();
  }
}

final stremioAddonControllerProvider =
    NotifierProvider<StremioAddonController, StremioAddonStatus>(
      StremioAddonController.new,
    );
