import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import '../ssh/ssh_transport.dart';
import 'tailnet_bridge.dart';

/// Wraps [DartSshTransport.connect] so a host that is only reachable through
/// the tailnet transparently goes through the embedded bridge.
///
/// Order of attempts:
///   1. connect straight to params.host:params.port (LAN / public 鈥?unchanged)
///   2. on a *retryable* failure, bring the embedded tailnet up and connect to
///      127.0.0.1:<port>, which forwards to the same target
///
/// Nothing in ssh_transport.dart changes: the second attempt is the same
/// function with a different address, so the SSH handshake, host-key check,
/// `dsh web` bootstrap, forwarding and reconnect logic all stay identical.
Future<SshTransport> tailnetAwareTransport(
  TailnetBridge bridge,
  SshConnectParams params,
  HostKeyCheck verifyHostKey,
) async {
  try {
    return await DartSshTransport.connect(params, verifyHostKey);
  } on HostLinkError catch (direct) {
    // Auth failures, bad keys and host-key mismatches will not get better
    // through the bridge; only network-shaped errors are worth retrying.
    if (!direct.retryable) rethrow;
    final where = '${params.host}:${params.port}';

    final int port;
    try {
      // ensureEndpoint itself brings the node up for this exact target, so no
      // separate start() call is needed (and none may carry a destination).
      port = await bridge.ensureEndpoint(targetHost: params.host, targetPort: params.port);
    } on PlatformException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressUnresponsive(params.host, params.port),
        detail: '${e.code}: ${e.message}',
        retryable: true,
      );
    }
    if (port <= 0) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressUnresponsive(params.host, params.port),
        detail: 'tailnet bridge returned no port',
        retryable: true,
      );
    }

    // Same parameters, only the address changes. user/auth/secrets/timeouts are
    // carried over untouched so authentication is exactly as before.
    final local = SshConnectParams(
      host: '127.0.0.1',
      port: port,
      username: params.username,
      auth: params.auth,
      secrets: params.secrets,
      connectTimeout: params.connectTimeout,
    );
    try {
      return await DartSshTransport.connect(local, verifyHostKey);
    } on HostLinkError catch (viaTailnet) {
      // Report the address the person actually typed, not 127.0.0.1:<ephemeral>.
      throw HostLinkError(
        viaTailnet.kind,
        appL10n.remoteErrAddressUnresponsive(params.host, params.port),
        detail: [where, viaTailnet.detail].whereType<String>().join('\n'),
        retryable: viaTailnet.retryable,
      );
    }
  }
}
