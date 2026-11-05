import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// What the embedded tailnet is doing (Go `mobile/status.go` states).
enum TailnetPhase {
  idle,
  starting,
  needsLogin,
  running,
  error,
  stopped;

  static TailnetPhase parse(Object? wire) => switch (wire) {
    'starting' => TailnetPhase.starting,
    'needs_login' => TailnetPhase.needsLogin,
    'running' => TailnetPhase.running,
    'error' => TailnetPhase.error,
    'stopped' => TailnetPhase.stopped,
    _ => TailnetPhase.idle,
  };

  bool get isBusy => this == TailnetPhase.starting;
}

/// Snapshot of the embedded tsnet node.
class TailnetStatus {
  const TailnetStatus({
    this.phase = TailnetPhase.idle,
    this.authUrl,
    this.tailnetIps = const [],
    this.listenPort = 0,
    this.target = '',
    this.error,
    this.connCount = 0,
  });

  factory TailnetStatus.fromJson(Map<String, dynamic> json) => TailnetStatus(
    phase: TailnetPhase.parse(json['state']),
    authUrl: (json['authUrl'] as String?)?.trim().isEmpty ?? true ? null : json['authUrl'] as String,
    tailnetIps: [
      for (final ip in (json['tailnetIp'] as List?) ?? const [])
        if (ip is String) ip,
    ],
    listenPort: (json['listenPort'] as num?)?.toInt() ?? 0,
    target: (json['target'] as String?) ?? '',
    error: (json['error'] as String?)?.trim().isEmpty ?? true ? null : json['error'] as String,
    connCount: (json['connCount'] as num?)?.toInt() ?? 0,
  );

  final TailnetPhase phase;
  final String? authUrl;
  final List<String> tailnetIps;
  final int listenPort;
  final String target;
  final String? error;
  final int connCount;

  bool get isRunning => phase == TailnetPhase.running;

  /// First IPv4 of the node, for display.
  String? get primaryIp => tailnetIps.where((ip) => !ip.contains(':')).firstOrNull;
}

/// Dart side of the embedded tailnet. Kotlin holds the Go instance; this
/// object only talks to it.
///
/// Intentionally narrow: the app never sees raw Go objects, and the endpoint is
/// bound to one fixed tailnet target (no generic forwarding).
abstract class TailnetBridge {
  Future<void> start();

  Future<void> stop();

  Future<TailnetStatus> status();

  /// Opens the loopback listener and returns its port (0 when not running).
  /// The listener accepts only 127.0.0.1 and dials [targetHost]:[targetPort].
  Future<int> ensureEndpoint({required String targetHost, required int targetPort});

  Stream<TailnetStatus> get statuses;

  void dispose();
}

/// MethodChannel-backed implementation (`dsh/tailnet` in TailnetPlugin.kt).
class TailnetBridgeChannel implements TailnetBridge {
  TailnetBridgeChannel({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('dsh/tailnet'),
      _events = events ?? const EventChannel('dsh/tailnet/events') {
    _subscription = _events.receiveBroadcastStream().listen((event) {
      final status = _parse(event);
      if (status != null) _statuses.add(status);
    }, onError: (_) {});
  }

  final MethodChannel _methods;
  final EventChannel _events;
  final _statuses = StreamController<TailnetStatus>.broadcast();
  StreamSubscription<Object?>? _subscription;

  TailnetStatus? _last;

  TailnetStatus? get last => _last;

  static TailnetStatus? _parse(Object? event) {
    if (event is! String) return null;
    try {
      return TailnetStatus.fromJson(jsonDecode(event) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _statusMap() async {
    final raw = await _methods.invokeMethod<String>('status');
    if (raw == null) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> start() async {
    await _methods.invokeMethod<void>('start');
    _last = TailnetStatus.fromJson(await _statusMap());
  }

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<TailnetStatus> status() async => _last = TailnetStatus.fromJson(await _statusMap());

  @override
  Future<int> ensureEndpoint({required String targetHost, required int targetPort}) async {
    final port = await _methods.invokeMethod<int>('ensureEndpoint', {
      'targetHost': targetHost,
      'targetPort': targetPort,
    });
    return port ?? 0;
  }

  @override
  Stream<TailnetStatus> get statuses => _statuses.stream;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
