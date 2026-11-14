import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the Stremio add-on is served and on which port.
///
/// These two values live in SharedPreferences instead of [AppSettings] so the
/// add-on can be added without touching the settings schema or its generated
/// serializer. The defaults are what the add-on uses before the first read
/// finishes.
class StremioAddonSettings {
  const StremioAddonSettings({this.enabled = false, this.port = defaultPort});

  static const int defaultPort = 8089;
  static const int minPort = 1024;
  static const int maxPort = 65535;

  final bool enabled;
  final int port;

  static int normalizePort(int value) =>
      value < minPort || value > maxPort ? defaultPort : value;

  StremioAddonSettings copyWith({bool? enabled, int? port}) =>
      StremioAddonSettings(
        enabled: enabled ?? this.enabled,
        port: normalizePort(port ?? this.port),
      );

  @override
  bool operator ==(Object other) =>
      other is StremioAddonSettings &&
      other.enabled == enabled &&
      other.port == port;

  @override
  int get hashCode => Object.hash(enabled, port);
}

class StremioAddonSettingsNotifier extends Notifier<StremioAddonSettings> {
  static const _enabledKey = 'stremio_addon_enabled';
  static const _portKey = 'stremio_addon_port';

  @override
  StremioAddonSettings build() {
    _restore();
    return const StremioAddonSettings();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_enabledKey);
      final port = prefs.getInt(_portKey);
      if (enabled == null && port == null) return;
      state = StremioAddonSettings(
        enabled: enabled ?? state.enabled,
        port: StremioAddonSettings.normalizePort(port ?? state.port),
      );
    } catch (_) {
      // The defaults stay usable; a failed read must not block startup.
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
    } catch (_) {
      // The switch still applies for this session.
    }
  }

  Future<void> setPort(int port) async {
    final normalized = StremioAddonSettings.normalizePort(port);
    state = state.copyWith(port: normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_portKey, normalized);
    } catch (_) {
      // The port still applies for this session.
    }
  }
}

final stremioAddonSettingsProvider =
    NotifierProvider<StremioAddonSettingsNotifier, StremioAddonSettings>(
      StremioAddonSettingsNotifier.new,
    );
