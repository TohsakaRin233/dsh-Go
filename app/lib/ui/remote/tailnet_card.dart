import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../remote/tailnet/tailnet_bridge.dart';
import '../../state/connection_state.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';

/// The embedded tsnet node for the host being edited.
///
/// On mobile data a tailnet-only address fails the direct attempt, and the
/// retry lives inside the node: the first run of `tsnet.Up()` stops at
/// `needs_login` and asks for a browser authorization. Nothing in the app used
/// to surface that link, so the form just said "no response". This card is that
/// missing surface, plus the node's own address for the log.
class TailnetCard extends ConsumerStatefulWidget {
  const TailnetCard({super.key, required this.host, required this.port});

  /// The host the form currently holds; the node is pinned to it on start.
  final String host;
  final int port;

  @override
  ConsumerState<TailnetCard> createState() => _TailnetCardState();
}

class _TailnetCardState extends ConsumerState<TailnetCard> {
  TailnetStatus _status = const TailnetStatus();
  StreamSubscription<TailnetStatus>? _sub;
  bool _busy = false;

  TailnetBridge get _bridge => ref.read(tailnetBridgeProvider);

  @override
  void initState() {
    super.initState();
    _sub = _bridge.statuses.listen(_onStatus);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _onStatus(TailnetStatus status) {
    if (mounted) setState(() => _status = status);
  }

  /// A bridge that answers badly is the same thing as a node not started.
  Future<void> _refresh() async {
    try {
      _onStatus(await _bridge.status());
    } on Object catch (_) {
      // Keep the last snapshot; the stream will correct it.
    }
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await _bridge.start(targetHost: widget.host, targetPort: widget.port);
    } on Object catch (_) {
      // The node reports its own failure through the status stream.
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await _bridge.stop();
    } on Object catch (_) {
      // Same as above: the stream is the source of truth.
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _openLogin(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// The node's IPv4, for the log; IPv6 entries are skipped on purpose.
  static String? _firstV4(List<String> ips) {
    for (final ip in ips) {
      if (!ip.contains(':')) return ip;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final phase = _status.phase;

    final label = switch (phase) {
      TailnetPhase.running => l10n.tailnetStateRunning,
      TailnetPhase.starting => l10n.tailnetStateStarting,
      TailnetPhase.needsLogin => l10n.tailnetStateNeedsLogin,
      TailnetPhase.error => l10n.tailnetStateError,
      _ => l10n.tailnetStateIdle,
    };

    final canStart = widget.host.isNotEmpty && widget.port > 0;
    final started = phase == TailnetPhase.running ||
        phase == TailnetPhase.starting ||
        phase == TailnetPhase.needsLogin;

    final nodeIp = _firstV4(_status.tailnetIps);
    final authUrl = _status.authUrl;
    final error = _status.error;

    return SettingsSection(
      title: l10n.tailnetCardTitle,
      footer: Text(l10n.tailnetCardHint),
      children: [
        SettingsTile(
          icon: phase == TailnetPhase.running ? AppIcons.cloud : AppIcons.link,
          tinted: false,
          title: label,
          subtitle: nodeIp == null ? null : '${l10n.tailnetNodeIp} · $nodeIp',
          trailing: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: canStart ? (started ? _stop : _start) : null,
                  child: Text(started ? l10n.tailnetStop : l10n.tailnetStart),
                ),
        ),
        if (error != null && error.isNotEmpty)
          SettingsTile(
            icon: AppIcons.offline,
            tinted: false,
            title: l10n.tailnetStateError,
            subtitle: error,
            danger: true,
          ),
        if (authUrl != null)
          SettingsTile(
            icon: AppIcons.link,
            tinted: false,
            title: l10n.tailnetOpenLogin,
            onTap: () => _openLogin(authUrl),
          ),
      ],
    );
  }
}
