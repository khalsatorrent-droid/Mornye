import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the Eclipse add-on is served, on which port, and which download
/// source it streams from.
///
/// These values live in SharedPreferences instead of [AppSettings] so the
/// add-on can be added without touching the settings schema or its generated
/// serializer.
class AddonSettings {
  const AddonSettings({
    this.enabled = false,
    this.port = defaultPort,
    this.source = '',
  });

  static const int defaultPort = 8089;
  static const int minPort = 1024;
  static const int maxPort = 65535;

  final bool enabled;
  final int port;

  /// A download extension id, or empty to use the app's default service.
  final String source;

  static int normalizePort(int value) =>
      value < minPort || value > maxPort ? defaultPort : value;

  AddonSettings copyWith({bool? enabled, int? port, String? source}) =>
      AddonSettings(
        enabled: enabled ?? this.enabled,
        port: normalizePort(port ?? this.port),
        source: source ?? this.source,
      );

  @override
  bool operator ==(Object other) =>
      other is AddonSettings &&
      other.enabled == enabled &&
      other.port == port &&
      other.source == source;

  @override
  int get hashCode => Object.hash(enabled, port, source);
}

class AddonSettingsNotifier extends Notifier<AddonSettings> {
  static const _enabledKey = 'addon_enabled';
  static const _portKey = 'addon_port';
  static const _sourceKey = 'addon_source';

  @override
  AddonSettings build() {
    _restore();
    return const AddonSettings();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_enabledKey);
      final port = prefs.getInt(_portKey);
      final source = prefs.getString(_sourceKey);
      if (enabled == null && port == null && source == null) return;
      state = AddonSettings(
        enabled: enabled ?? state.enabled,
        port: AddonSettings.normalizePort(port ?? state.port),
        source: source ?? state.source,
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
    final normalized = AddonSettings.normalizePort(port);
    state = state.copyWith(port: normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_portKey, normalized);
    } catch (_) {
      // The port still applies for this session.
    }
  }

  Future<void> setSource(String source) async {
    state = state.copyWith(source: source.trim());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sourceKey, source.trim());
    } catch (_) {
      // The source still applies for this session.
    }
  }
}

final addonSettingsProvider =
    NotifierProvider<AddonSettingsNotifier, AddonSettings>(
      AddonSettingsNotifier.new,
    );
