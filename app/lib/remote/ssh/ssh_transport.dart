import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'remote_shell.dart';
import 'ssh_host_config.dart';

/// A byte pipe to `host:port` on the remote side of the SSH connection.
abstract class TunnelChannel {
  Stream<Uint8List> get stream;
  StreamSink<List<int>> get sink;
  void destroy();
}

/// A reachable SSH server refused the destination TCP connection.
class TunnelRefused implements Exception {
  const TunnelRefused([this.cause]);
  final Object? cause;

  @override
  String toString() => 'TunnelRefused: $cause';
}

/// Host key presented by the server: algorithm and OpenSSH-style
/// `SHA256:<base64>` fingerprint (same text `ssh-keygen -lf` prints).
class PresentedHostKey {
  const PresentedHostKey(this.type, this.fingerprint);

  final String type;
  final String fingerprint;

  /// `ED25519` / `RSA` / `ECDSA` for display.
  String get shortType {
    final t = type.toLowerCase();
    if (t.contains('ed25519')) return 'ED25519';
    if (t.contains('rsa')) return 'RSA';
    if (t.contains('ecdsa')) return 'ECDSA';
    return type;
  }
}

/// Decides whether to trust the server's key. Return false to abort.
typedef HostKeyCheck = FutureOr<bool> Function(PresentedHostKey key);

/// Everything needed to open one SSH connection.
class SshConnectParams {
  const SshConnectParams({
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    required this.secrets,
    this.connectTimeout = const Duration(seconds: 12),
  });

  factory SshConnectParams.of(SshHostConfig config, SshSecrets secrets) => SshConnectParams(
    host: config.host.trim(),
    port: config.port,
    username: config.user.trim(),
    auth: config.auth,
    secrets: secrets,
    connectTimeout: connectTimeoutFor(config.host.trim()),
  );

  /// A private address answers fast or not at all: a phone that just left the
  /// LAN would otherwise burn the full [defaultConnectTimeout] on every
  /// reconnect before the embedded-tailnet fallback gets its turn.
  ///
  /// Public host names keep the long timeout — they pay DNS and a WAN round
  /// trip, and a slow answer there is normal.
  static Duration connectTimeoutFor(String host) {
    if (!_isPrivateHost(host)) return const Duration(seconds: 12);
    return const Duration(seconds: 3);
  }

  static bool _isPrivateHost(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10 (CGNAT / tailnet)
    return false;
  }

  static const Duration defaultConnectTimeout = Duration(seconds: 12);

  final String host;
  final int port;
  final String username;
  final SshAuthMethod auth;
  final SshSecrets secrets;
  final Duration connectTimeout;
}

/// One authenticated SSH connection.
abstract class SshTransport implements RemoteShell {
  /// Opens a direct-tcpip channel to [host]:[port] as seen from the server.
  Future<TunnelChannel> openTunnel(String host, int port);

  /// Round-trips a keepalive; throws or times out when the link is dead.
  Future<void> ping({Duration timeout = const Duration(seconds: 10)});

  /// Completes when the connection closes for any reason.
  Future<void> get done;

  bool get isClosed;

  void close();

  /// True when this connection reaches the host through the embedded tailnet
  /// bridge instead of the address the person typed. The link uses it to
  /// decide whether a network change is worth re-picking the route: a bridge
  /// connection is a loopback socket that survives a network switch, so only
  /// an explicit re-pick can move it back to the direct route.
  bool get viaBridge => false;
}

typedef SshTransportFactory = Future<SshTransport> Function(SshConnectParams params, HostKeyCheck verifyHostKey);

/// dartssh2-backed transport.
class DartSshTransport implements SshTransport {
  DartSshTransport._(this._client, {this.viaBridge = false});

  final SSHClient _client;

  @override
  final bool viaBridge;

  /// [viaBridge] only tags the resulting transport; the dial itself always
  /// goes to [params.host]. The caller decides which address to pass.
  static Future<SshTransport> connect(
    SshConnectParams params,
    HostKeyCheck verifyHostKey, {
    bool viaBridge = false,
  }) async {
    List<SSHKeyPair>? identities;
    if (params.auth == SshAuthMethod.privateKey) {
      identities = await decodePrivateKey(params.secrets.privateKey ?? '', params.secrets.passphrase);
    } else if ((params.secrets.password ?? '').isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrPasswordMissing);
    }

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(params.host, params.port, timeout: params.connectTimeout);
    } on SocketException catch (e) {
      throw describeSocketError(e, params);
    } on TimeoutException {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressUnresponsive(params.host, params.port),
        retryable: true,
      );
    }

    HostLinkError? keyVerdict;
    final client = SSHClient(
      socket,
      username: params.username,
      identities: identities,
      onPasswordRequest: params.auth == SshAuthMethod.password ? () => params.secrets.password : null,
      // Keyboard-interactive servers ask for the same password.
      onUserInfoRequest: params.auth == SshAuthMethod.password
          ? (request) => [for (final _ in request.prompts) params.secrets.password ?? '']
          : null,
      onVerifyHostKey: (type, fingerprint) async {
        final key = PresentedHostKey(type, utf8.decode(fingerprint, allowMalformed: true));
        try {
          return await verifyHostKey(key);
        } on HostLinkError catch (e) {
          keyVerdict = e;
          return false;
        }
      },
      // The link runs its own keepalive with a timeout (dartssh2's never
      // notices a dead socket on its own).
      keepAliveInterval: null,
      handshakeTimeout: const Duration(seconds: 20),
      authTimeout: const Duration(seconds: 30),
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      if (keyVerdict != null) throw keyVerdict!;
      throw describeSshError(e, params);
    }
    return DartSshTransport._(client, viaBridge: viaBridge);
  }

  /// Parses a PEM private key, mapping failures to a person-readable error.
  static Future<List<SSHKeyPair>> decodePrivateKey(String pem, String? passphrase) async {
    final text = pem.trim();
    if (text.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrPrivateKeyMissing);
    }
    try {
      final pass = (passphrase == null || passphrase.isEmpty) ? null : passphrase;
      // PEM parsing and the encrypted-key KDF are synchronous CPU work.
      // Keep localization on the caller isolate; send only key material.
      final pairs = await Isolate.run(() {
        if (pass == null && SSHKeyPair.isEncryptedPem(text)) return null;
        return SSHKeyPair.fromPem(text, pass);
      }, debugName: 'ssh-private-key');
      if (pairs == null) {
        throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrKeyNeedsPassword);
      }
      if (pairs.isEmpty) throw const FormatException('no keys');
      return pairs;
    } on HostLinkError {
      rethrow;
    } on SSHKeyDecryptError catch (e) {
      throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrKeyPassword, detail: e.message);
    } catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.badPrivateKey,
        appL10n.remoteErrKeyUnreadable,
        detail: appL10n.remotePrivateKeyFormats(e.toString()),
      );
    }
  }

  static HostLinkError describeSocketError(SocketException e, SshConnectParams params) {
    final os = e.osError?.message ?? e.message;
    final text = '$os ${e.message}'.toLowerCase();
    final where = '${params.host}:${params.port}';
    if (text.contains('refused')) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressRejected(where),
        detail: os,
        retryable: true,
      );
    }
    if (text.contains('host lookup') || text.contains('name') && text.contains('resol') || text.contains('nodename')) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshHostNotFound(params.host),
        detail: os,
        retryable: true,
      );
    }
    return HostLinkError(
      HostLinkErrorKind.unreachable,
      appL10n.remoteErrSshAddressUnresponsive(where),
      detail: os,
      retryable: true,
    );
  }

  static HostLinkError describeSshError(Object e, SshConnectParams params) {
    if (e is HostLinkError) return e;
    if (e is SSHAuthError) {
      return HostLinkError(
        HostLinkErrorKind.authFailed,
        params.auth == SshAuthMethod.password ? appL10n.remoteErrUsernamePassword : appL10n.remoteErrPrivateKeyRejected,
        detail: params.auth == SshAuthMethod.privateKey
            ? appL10n.remoteAuthorizedKeysHelp(params.username, e.toString())
            : '$e',
      );
    }
    if (e is SSHHostkeyError) {
      return HostLinkError(HostLinkErrorKind.hostKeyRejected, appL10n.remoteErrFingerprintUntrusted, detail: '$e');
    }
    if (e is SocketException) return describeSocketError(e, params);
    if (e is TimeoutException) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshHandshakeTimeout,
        detail: '$e',
        retryable: true,
      );
    }
    final text = '$e';
    if (e is SSHHandshakeError || e is SSHSocketError || e is SSHStateError || e is SSHDisconnectError) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshInterrupted,
        detail: text,
        retryable: true,
      );
    }
    return HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrSshConnection, detail: text, retryable: true);
  }

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    final SSHRunResult result;
    try {
      result = await _client.runWithResult(loginShell(script)).timeout(timeout);
    } on TimeoutException {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrCommandTimeout,
        retryable: true,
        detail: 'after $timeout',
      );
    } on SSHError catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshInterrupted,
        detail: '$e',
        retryable: true,
      );
    }
    return RemoteExecResult(
      result.exitCode,
      utf8.decode(result.stdout, allowMalformed: true),
      utf8.decode(result.stderr, allowMalformed: true),
    );
  }

  @override
  Future<TunnelChannel> openTunnel(String host, int port) async {
    try {
      final channel = await _client.forwardLocal(host, port, localHost: '127.0.0.1');
      return _ForwardChannel(channel);
    } on SSHChannelOpenError catch (e) {
      // 2 = SSH_OPEN_CONNECT_FAILED: nothing listens on that port anymore.
      if (e.code == 2) throw TunnelRefused(e);
      rethrow;
    }
  }

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) => _client.ping().timeout(timeout);

  @override
  Future<void> get done => _client.done.catchError((_) {});

  @override
  bool get isClosed => _client.isClosed;

  @override
  void close() => unawaited(Future.sync(_client.close).catchError((_) {}));
}

class _ForwardChannel implements TunnelChannel {
  _ForwardChannel(this._channel);

  final SSHForwardChannel _channel;

  @override
  Stream<Uint8List> get stream => _channel.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink;

  @override
  void destroy() => _channel.destroy();
}
