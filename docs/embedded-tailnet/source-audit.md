<!-- redacted: tailnet addresses, build-host paths and user names replaced with placeholders -->
> 说明：本文件在对外发布前已脱敏——Tailnet 地址、构建机路径与用户名换成占位符；代码逻辑、错误信息与结论保持原样。

# dsh-go 内嵌用户态 Tailnet —— 源码调查报告（P0 交付物）

- **项目代号**：Embedded Tailnet for dsh-go
- **阶段**：P0（源码调查，禁止在此阶段改产品代码）
- **被调查仓库**：`ccch1mneyyy/dsh-Go`（GitHub，AGPL-3.0）
- **基线提交**：`48f866581e3bcc5c0e4fb8c26aaeae31273b708c`（2026-11-05 20:05:52 +0800，main）
- **本地 clone**：`/workspace/tmp/dsh-audit/dsh-Go`（depth 50，601 MB，含资产）
- **规模**：`app/lib` 774 个 Dart 文件 / 7.8 MB；`app/android` 293 个 Kotlin 文件；**全仓库 0 个 `.go` 文件、0 个 `go.mod`**
- **调查日期**：2026-11-05（JST）
- **报告状态**：待项目负责人审阅（审阅通过后才进入 P1）

> 说明：计划书里给的路径线索是「根据评审资料」推断的。本报告只写**实际在源码里核实过**的内容，
> 每条结论都带 `文件:行号`。凡与计划书不一致的地方集中放在第 9 节。

---

## 0. 结论速览（给负责人先看这 8 条）

1. **注入点比预想的更干净**：dsh-Go 已经有 `sshTransportFactoryProvider`（单点定义），
   `SshHostLink` 构造时本来就接受 `transportFactory`。只要覆盖这个 Provider，
   把 `SshConnectParams` 的 host/port 改写成 `127.0.0.1:<bridgePort>`，
   **`ssh_transport.dart` 一行都不用改**，计划书约束 3、4 天然满足。
2. **Host Key 校验与网络路径完全解耦**：校验发生在 dartssh2 的 `onVerifyHostKey` 回调里
   （`ssh_transport.dart:133-141`），只看 socket 上握手得到的 key，不关心 socket 从哪来。
   走本地 bridge 不会削弱 SSH 身份校验（计划书第十章的要求成立，且不需要额外工作）。
3. **`LocalForwarder` 是现成的「本地 loopback 监听 + 随机端口」范式**
   （`ServerSocket.bind(InternetAddress.loopbackIPv4, 0)`，`local_forward.dart:27`），
   方向相反但结构一样，可作为 Go Bridge 的 Dart 侧设计参照和测试对照。
4. **仓库是全新地面**：没有 Go 工具链痕迹、没有 `native/` 目录、没有任何 tailscale/tsnet/wireguard
   代码（只有 `dsh_remote` 里把 `100.64/10`、`fd7a:115c:a1e0::/48` 识别成 CGNAT 用于 ICE 候选过滤，
   `packages/dsh_remote/lib/src/transport/peer_connection.dart:162-192`）。内嵌 Tailnet 是新增模块，
   不存在与旧实现冲突。
5. **`DshService` 不是「远程接入服务容器」**：它是**本地 proot DSH 引擎**的前台服务
   （`DshService.kt:22` 注释、`RuntimeController.phase` 只描述本地引擎）。
   只用远程主机的用户可能根本不启动它（`PetOverlayService.kt:20-21` 的注释明说
   "someone who only uses remote hosts"）。计划书第九章「由 DshService 持有 Go 实例」需要修正，
   见第 9 节第 2 条。
6. **许可证是 AGPL-3.0**（`LICENSE:1-2`）。这是硬约束：内嵌 Tailnet 的代码一旦与 dsh-go 分发在一起，
   整个产物按 AGPL 处理；仓库还明确**不接受外部 PR**（`AGENTS.md`「不接受外部 PR」章节）。
   所以「改这个仓库」的路线要负责人先决断，建议走独立 fork 或独立插件仓，见第 9 节第 9 条。
7. **本沙箱没有 Android 构建链**：`go`/`flutter`/`dart`/`java`/`gradle`/`adb`/NDK **全部不存在**。
   P2 的「真机 Gate」不可能在本环境完成，只能在有工具链的机器上做（第 10 节给脚本与清单）。
   **但编译门已经提前探到一半**（第 10 节，全部实测）：
   - `CGO_ENABLED=0 GOOS=android GOARCH=arm64` 编 tsnet **成功**（30 MB，ELF AArch64 **PIE**）——纯 Go 路线成立；
   - `CGO_ENABLED=1` 立刻失败（没有 gcc/clang）——说明 **`gomobile bind` 必然依赖 NDK**；
   - 实测 `gomobile bind` 报 `could not locate Android SDK`——AAR 构建需要 SDK+NDK 齐备。
8. **交互登录这条路实测是通的，不需要 auth key**（计划书 7.1 的疑虑有答案）：
   `tsnet.Server.Up()` 在未登录时进入 `NeedsLogin` 并**自动 `StartLoginInteractive`，直接打印
   `https://login.tailscale.com/a/...` 登录 URL**。手机场景 = Kotlin 取 URL → 系统浏览器打开 → 用户自己批准，
   APK 不需要任何长期凭据。详见 `p2-probe-log.md` §4。

---

## 1. 实际架构图

### 1.1 仓库分层（按实际目录）

```
dsh-Go/                                    AGPL-3.0（LICENSE:1）
├── app/                                   Flutter 应用（applicationId io.github.ccch1mneyyy.dsh_app）
│   ├── lib/                               774 个 Dart 文件
│   │   ├── main.dart / app.dart
│   │   ├── remote/                        ★ 远程接入的 Dart 层
│   │   │   ├── ssh/                       ssh_transport / ssh_host_config / ssh_link /
│   │   │   │                              local_forward / remote_bootstrap / remote_shell
│   │   │   ├── relay/                     WebRTC/LAN/TURN/Relay（DS Remote）
│   │   │   ├── link_status.dart           链路状态模型（phase / step / 错误码）
│   │   │   ├── network_watch.dart         网络切换与前台恢复的 kick 流
│   │   │   └── secret_store.dart          flutter_secure_storage 封装
│   │   ├── state/                         Riverpod 状态（hosts_state / connection_state ...）
│   │   ├── runtime/                       本机 proot 引擎的 Dart 侧（MethodChannel 封装）
│   │   ├── ui/remote/                     SSH 表单、主机切换、Host Key 对话框
│   │   └── phone/ voice/ notify/ ...      其它原生能力
│   └── android/                           Kotlin 原生层（手写 FlutterPlugin，无 Pigeon）
│       └── app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/
│           ├── MainActivity.kt            插件注册表（43-65 行）
│           ├── runtime/                   DshService / RuntimeController / DshProcess /
│           │                              RuntimePlugin（跨进程的通道实现）
│           ├── phone/ notify/ pet/ ...    其它插件
│           └── ...
├── packages/
│   ├── dsh_client/                        纯 Dart：DSH Web API（HTTP/SSE/mux）
│   └── dsh_remote/                        纯 Dart：DSH Remote 传输（WebRTC/TURN/Relay）
├── runtime/                               打补丁的 DSH 引擎 + proot rootfs 打包
├── docs/architecture.md                   架构约定（含平台通道表）
└── tooling/                               APK 构建脚本
```

### 1.2 远程接入的三条现有通道（这是本项目的落点）

```
                    ┌─────────────────────────── dsh-Go 手机 App（单个 Linux 进程） ──────────────┐
                    │                                                                             │
  Flutter UI ───────┤  Riverpod state (connection_state.dart)                                     │
  (Dart)            │        │                                                                    │
                    │        ├── hostLinkProvider ──► SshHostLink（ssh_link.dart:59）              │
                    │        │                          │                                          │
                    │        │                          │ transportFactory(SshConnectParams,...)  │
                    │        │                          ▼                                          │
                    │        │                    DartSshTransport.connect（ssh_transport.dart:102）│
                    │        │                          │                                          │
                    │        │                          ▼  SSHSocket.connect(host, port)          │
                    │        │                     ┌──────────────┐                                │
                    │        │                     │  TCP socket  │──► LAN / 公网 / (未来) 本地桥   │
                    │        │                     └──────────────┘                                │
                    │        │                          │ SSH 认证（onVerifyHostKey:133-141）        │
                    │        │                          ▼                                          │
                    │        │                    RemoteDshBootstrap.ensureRunning（远端起 dsh web）│
                    │        │                          │                                          │
                    │        │                          ▼                                          │
                    │        │                    LocalForwarder.bind（local_forward.dart:24-30）   │
                    │        │                     127.0.0.1:<随机> ── SSH direct-tcpip ──► 远端      │
                    │        │                          │         127.0.0.1:<dsh web 端口>           │
                    │        │                          ▼                                          │
                    │        └────────────────► DshClient.connect(http://127.0.0.1:<随机>)         │
                    │                                                                             │
                    ├── HostLink relay 通道 ──► packages/dsh_remote（WebRTC/TURN/Relay，Noise E2E） │
                    └── 本机通道 ──► RuntimeBridge(MethodChannel dsh/runtime) ──► proot 里的 dsh web │
                    └─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 内嵌 Tailnet 接入后的目标数据流（与上图的差异，只有一处）

```
  SshHostLink
      │ transportFactory = 被覆盖的 tailnetAwareFactory（本次新增，Dart 侧 ~50 行）
      ▼
  判断：直连可行？──是──► DartSshTransport.connect（原样）
      │否
      ▼
  TailnetBridge.ensureEndpoint(targetHost, targetPort)   ← 新 Platform Channel
      ▼
  127.0.0.1:<bridgePort>（Kotlin 拿到的本地端口）
      ▼
  DartSshTransport.connect（**同一个函数**，只是 host/port 换了）
      ▼
  Go Bridge（tsnet.Server.Dial → 100.x.y.z:22）──► NAS sshd  ← 内嵌用户态网络栈
```

要点：**Dart 业务层以下完全不变**——SSH 握手、Host Key 校验、远端 `dsh web` 引导、forward、DshClient 登录、
keepalive、退避重连全部复用，因为 socket 的另一端只是变成了 loopback 上的 bridge。

---

## 2. SSH 连接调用链（逐跳，带行号）

### 2.1 首次连接

| # | 位置 | 做什么 |
|---|---|---|
| 1 | `lib/state/connection_state.dart:169-185` | `hostLinkProvider` 按 `HostRef` 构造 `SshHostLink`，传入 `transportFactory: ref.read(sshTransportFactoryProvider)`（`connection_state.dart:171`） |
| 2 | `lib/state/connection_state.dart:158` | `sshTransportFactoryProvider = Provider<SshTransportFactory>((ref) => DartSshTransport.connect)` —— **唯一的工厂来源** |
| 3 | `lib/remote/ssh/ssh_link.dart:158-163` | `open()` → `_openFirst()`，发 `HostLinkStatus(connecting, step: connect)` |
| 4 | `ssh_link.dart:202-212` | `_connectOnce()`：`_loadSecrets()` 取凭据 → `_transportFactory(SshConnectParams.of(config, secrets), verifyHostKey)` |
| 5 | `lib/remote/ssh/ssh_host_config.dart:62-68` | `SshConnectParams.of()` 把 `host/port/user/auth/secrets` 摊平成连接参数（**host 来自 config**） |
| 6 | `lib/remote/ssh/ssh_transport.dart:102-121` | `DartSshTransport.connect`：私钥解码（`Isolate.run`，:168）+ `SSHSocket.connect(params.host, params.port, timeout: 12s)`（:112） |
| 7 | `ssh_transport.dart:133-141` | dartssh2 `onVerifyHostKey` → 转成 `PresentedHostKey` → 调用注入的 `verifyHostKey` |
| 8 | `ssh_link.dart:212-239` | 校验逻辑：`checkHostKey`（:40-44）→ trusted/mismatch/unknown 三分支；unknown 时弹 `HostKeyPrompt` 并 `pinHostKey` 落盘 |
| 9 | `ssh_link.dart:246-257` | `RemoteDshBootstrap.ensureRunning()`：在远端探测/启动 `dsh web`，读它日志里的端口与 token（`lib/remote/ssh/remote_bootstrap.dart`，407 行） |
| 10 | `ssh_link.dart:261-273` | `transport.openTunnel('127.0.0.1', endpoint.port)` 探一次通道（超时后也 destroy，防泄漏） |
| 11 | `ssh_link.dart:277-284` | `LocalForwarder.bind(_openChannel)` → `127.0.0.1:<随机>`；`local_forward.dart:27` `ServerSocket.bind(loopbackIPv4, 0)` |
| 12 | `ssh_link.dart:288-297` | `_ensureClient()` → `DshClient.connect(baseUri: http://127.0.0.1:<forwardPort>, token, hostHeader)` |
| 13 | `ssh_link.dart:298, 428-454` | 每 15s keepalive（`transport.ping()`），连续 2 次失败判死 |
| 14 | `ssh_link.dart:456-510` | `_lost()` → `_recover()` 指数退避重连（`_connectOnce` 重跑整条链） |

### 2.2 走本地 bridge 时会变成什么

第 6 步的 `params.host/params.port` 换成 `127.0.0.1/<bridgePort>`，第 7 步之后**一步都不变**。

关键：**只能改 `SshConnectParams`，不能改 `SshHostConfig`**。理由：
- `SshHostConfig.connectionKey`（`ssh_host_config.dart:54`）含 `host/port`，`hostLinkProvider` 用它判断要不要重建链路（`connection_state.dart:177-183`）；
- `copyWith` 在 host/port 变化时会**清掉已 pin 的 Host Key**（`ssh_host_config.dart:69, 79-80`）；
- `toJson`（:84-95）会持久化到 SharedPreferences，改 config 等于污染用户配置，破坏约束 9（Host 配置兼容性）。

### 2.3 还有两个地方会用这个 factory（覆盖时必须一起覆盖）

| 位置 | 用途 |
|---|---|
| `lib/ui/remote/ssh_host_form.dart:239-253` | 「测试连接」直接 `new SshHostLink(..., transportFactory: ref.read(sshTransportFactoryProvider), retryFirstOpen: false)` |
| `lib/ui/remote/host_key_dialog.dart:116` | `fetchHostKey(config, transportFactory: ref.read(sshTransportFactoryProvider))`，只握手读 key、不登录（`ssh_link.dart:578-602`） |

**好消息**：三处都从同一个 Provider 取，覆盖 Provider 即全覆盖，不需要改这三个文件。

---

## 3. Platform Channel 现有实现方式（内嵌 Tailnet 必须沿用的范式）

### 3.1 范式总览

- **不用 Pigeon、不用 pigeon 生成**：全仓 `MethodChannel` 手写。命名规范是 `dsh/<模块>` + `dsh/<模块>/events`。
- 典型例子：`dsh/runtime` + `dsh/runtime/events`（`lib/runtime/runtime_bridge.dart:505-507` 与
  `android/.../runtime/RuntimePlugin.kt:31-33`）。
- Kotlin 侧实现 `FlutterPlugin` + `MethodChannel.MethodCallHandler` + `EventChannel.StreamHandler`，
  在 `MainActivity.configureFlutterEngine` 里 `engine.plugins.add(SomePlugin())` 注册
  （`MainActivity.kt:43-65`，目前约 20 个插件）。
- 事件推送：Kotlin 侧有 `RuntimeController.EventSink`（`DshService.kt:46-59` 用法），Dart 侧
  `EventChannel.receiveBroadcastStream()` 转 `Stream`，再映射成 Riverpod state。
- 错误约定：`result.error("install_busy", ...)` 这种**稳定字符串码**（`RuntimePlugin.kt:92`），
  不把异常文本当业务判断依据 —— 与计划书 5.3「错误码必须稳定」一致，已有先例可抄。

### 3.2 与内嵌 Tailnet 相关的既存绑定（可直接复用的模式）

| 现有实现 | 可复用点 |
|---|---|
| `runtime_bridge.dart`（721 行） | Dart 侧「通道 + 枚举解析 + 状态快照 + 事件流 + 单例暴露」的完整写法；`RuntimePhase.parse` 的 wire 解析方式（:18-21）适合 `TailnetPhase` |
| `RuntimePlugin.kt`（272 行） | Kotlin 侧「参数校验 + `result.success(map)` + 权限/生命周期处理」；`start/stop` 返回 map 或 null 的约定 |
| `DshService` + `RuntimeController` | 进程级单例 + 前台服务 + `EventSink` 广播；`RuntimeController.get(context)` 单例模式（`DshService.kt:34`） |
| `PhoneControl` | 复杂子系统的「单例 + 内部线程 + 状态枚举」写法 |

### 3.3 结论

新增 Tailnet 通道**不引入新范式**：`dsh/tailnet` + `dsh/tailnet/events`，Kotlin 侧新增一个
`TailnetPlugin` 注册到 `MainActivity.kt`，Dart 侧新增 `lib/remote/tailnet/` 目录。
这样上游升级时的冲突面最小。

---

## 4. DshService 生命周期（计划书第九章的前提需要修正）

### 4.1 事实

- `DshService` 是**本地 proot DSH 引擎**的前台服务（`DshService.kt:22`：`/** Foreground service that keeps the local DSH process alive in the background. */`）。
- 前台类型 `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`（`DshService.kt:117-118`），`START_NOT_STICKY`（:61/71/85/98）。
- Action 分发（:35-97）：`ACTION_INSTALL` / `ACTION_INSTALL_DONE` / `ACTION_START`（else 分支）/ `ACTION_STOP` / `ACTION_PHONE_STOP`。
- 只在 else 分支（即 `ACTION_START`）里：`foreground()` + `acquireWakeLock()` + `registerNetworkCallback()` + `controller.startProcess()`。
- 网络回调只做两件事（:124-138）：`onLinkPropertiesChanged` → `controller.refreshDns(properties)`（把系统 DNS 灌给 proot 里的 resolv.conf）；
  `onBlockedStatusChanged` → `controller.onNetworkBlocked(...)`。
- `onDestroy`（:101-114）注销回调、释放 wake lock、`onNetworkWatchStopped()`。
- 状态是**流程级单例** `RuntimeController.get(context)`（`DshService.kt:34`），`Phase = {INSTALLING, STARTING, RUNNING, STOPPING, ...}`（`DshService.kt:66, 80, 286-289`）。

### 4.2 对本项目的直接影响

1. **远程主机用户可以完全不启动 DshService**（`PetOverlayService.kt:20-21` 注释证实：有些人只用远程主机，
   本机引擎没跑）。所以「Go 实例交给 DshService 托管」会让 Tailnet 在纯远程场景下没有宿主。
2. 正确做法：**Go 实例由 Kotlin 侧进程级单例持有**（照 `RuntimeController` 的模式），
   前台服务只负责「保活 + 通知」这一类可选职责。是否插进 `DshService` 由 P5 再定，
   P3/P4 阶段先做无服务依赖的进程内单例即可。
3. `DshService` 的 `refreshDns`（:128-130）说明**项目已经在做「把系统 DNS 喂给非系统网络栈」这件事**。
   tsnet 同样需要 DNS（MagicDNS），这里的既有代码（`RuntimeController.refreshDns`）值得先读、再决定
   Go 侧要不要自己的 resolver（见第 8 节风险 R4）。

### 4.3 无进程级单例时的替代方案

`PhoneControl.get(context)`（`PhoneControl.kt`）也是进程单例；全项目一致用「`companion object` + `get(ctx)`」。
新增 `TailnetBridgeManager` 按同样写法即可，Kotlin 侧不需要新架构。

---

## 5. Android 构建配置（实测值）

来源：`app/android/settings.gradle.kts`、`app/android/app/build.gradle.kts`、`app/android/gradle.properties`、
`app/android/app/src/main/AndroidManifest.xml`。

| 项 | 值 | 位置 |
|---|---|---|
| Android Gradle Plugin | **9.1.0** | `settings.gradle.kts:25` |
| Kotlin | **2.4.0** | `settings.gradle.kts:26` |
| JVM target / compileOptions | Java 17 | `build.gradle.kts:41-44, 132` |
| compileSdk | `flutter.compileSdkVersion`（跟随 Flutter SDK，**未钉死**） | `build.gradle.kts:37` |
| ndkVersion | `flutter.ndkVersion`（**未钉死**） | `build.gradle.kts:38` |
| minSdk | **26** | `build.gradle.kts:48` |
| targetSdk | **28**（有意为之，非 Play 发布；`lint.disable += ExpiredTargetSdkVersion`） | `build.gradle.kts:51, 90-93` |
| ABI flavor | `arm64`(arm64-v8a) / `x64`(x86_64)，`disable-abi-filtering=true` | `build.gradle.kts:56-66`、`gradle.properties:11` |
| jniLibs 来源 | `sourceSets.arm64.jniLibs.srcDir(runtimeOut/arm64-v8a/jniLibs)` | `build.gradle.kts:69-77` |
| native 打包 | `useLegacyPackaging = true`，`libproot.so` 等保留调试符号 | `build.gradle.kts:80-87` |
| 构建脚本 | `tooling/build-apk.sh --build-name x.y.z` | 仓库 `AGENTS.md`「命令」 |
| 签名 | 三套签名（v1/v2/v3），key 从 `key.properties` 读 | `build.gradle.kts:112-126` |

### 5.1 对 AAR 接入的具体含义

1. **不能再加一个 ABI**：flavor 已把 ABI 锁成每个 flavor 一个；AAR 只需提供 `arm64-v8a`（x64 flavor 是模拟器用，
   第一阶段可不提供，但要注意 `x64` flavor 构建时缺 `.so` 会**编译通过、运行崩**，建议给 x64 留一个
   stub 或在 gradle 里按 flavor 排除）。
2. **jniLibs 已经有 import 路径**（`runtimeOut/.../jniLibs`），说明「把外部 `.so` 塞进 APK」这条链路
   **已经在跑**（现在装的是 proot 那批）。AAR 自带 `.so` 的话 Gradle 会自动合并，与现有 sourceSets 不冲突。
3. **`keepDebugSymbols` 白名单**（:86）只列了 proot 的 so；Go 的 `libtailnet.so` 不需要，但要注意
   `extractNativeLibs="true"`（Manifest `application` 属性）——这是 Go/DB 库能被正常 `dlopen` 的前提，已满足。
4. **minSdk 26**：gomobile 生成的 AAR 一般 minSdk 21+，兼容。**targetSdk 28 是双刃剑**：
   对网络/后台限制宽松（好事），但 Android 14+ 的某些行为按 targetSdk 判定，实测要覆盖新机型。
5. **`ndkVersion = flutter.ndkVersion` 未钉死** —— 计划书第十三章要求「固定 NDK 版本」，当前仓库没有这个约束，
   做 AAR 时需要单独 pin（见第 8 节 P2-1 待办）。
6. **明文网络**：`network_security_config.xml` 只对 `127.0.0.1`/`localhost` 放行 cleartext（HTTP）。
   与 raw TCP 无关，但**恰好说明项目已经默认「本地 loopback 是可信的」**，与 Bridge 设计一致。

### 5.2 构建命令（本环境无法执行，仅记录契约）

```bash
# 仓库自带（AGENTS.md）
(cd app && flutter pub get && flutter analyze && flutter test)
tooling/build-apk.sh --build-name <x.y.z>
# 只构建 Android
(cd app && flutter build apk --flavor arm64 --target-platform android-arm64)
```

---

## 6. 现有 Host 配置存储方式

| 内容 | 存储 | 位置 |
|---|---|---|
| SSH Host 列表 | SharedPreferences，键 **`remote_ssh_hosts`**，值是 JSON 数组 | `lib/state/hosts_state.dart:104`（`static const prefsKey`），读写 :117-133 |
| 单条 Host 结构 | `SshHostConfig`（id/name/host/port/user/auth/launchCommand/workingDirectory/hostKeyType/hostKeyFingerprint） | `ssh_host_config.dart:11-46`，序列化 :84-119 |
| 密码 / 私钥 / passphrase | **flutter_secure_storage**（Android Keystore），键前缀 `remote.`，命名空间 `ssh.<hostId>.password` 等 | `lib/remote/secret_store.dart:16-38`；`ssh_host_config.dart:156-158` |
| Host Key pin | 存在 `SshHostConfig.hostKeyType/hostKeyFingerprint`（普通 prefs，非敏感） | `ssh_host_config.dart:43-46` |
| 设备（relay）凭据 | 同一个 `SecretStore` | `secret_store.dart:3-8` 注释 |

### 6.1 向后兼容的具体做法（满足约束 9）

- `SshHostConfig.fromJson`（:97-119）对缺字段有默认值：`port` 缺/非法 → 22；`auth` 未知 → `password`；
  `launchCommand` 空 → `'dsh web'`；可选字段缺 → null。**新增 `embeddedTailnet` 字段可以照这个模式加，
  旧配置读出来默认 false，零迁移成本。**
- 但**不要**改 `connectionKey`（:54）的构成来包含新字段——那会让老 Host 无故重建链路。
  如果需要「开关变化后重连」，正确做法是在 `hostLinkProvider`（`connection_state.dart:174-183`）里单独 watch 新字段。

---

## 7. 可复用代码（不用重写的东西）

| 目标 | 直接复用 | 说明 |
|---|---|---|
| SSH 连接、Host Key 校验、`dsh web` 引导、forward、登录、keepalive、退避重连 | `SshHostLink` + `DartSshTransport` 全套 | 只换 socket 端点，零改动（第 2 节） |
| 「本地 loopback 监听 + 随机端口 + 连接对管理 + 统一 drop」 | `LocalForwarder`（`local_forward.dart:12-126`） | Go Bridge 的 Dart 侧对照实现；也让 Dart 侧的单测可以照抄它的测试写法 |
| 注入点 | `sshTransportFactoryProvider`（`connection_state.dart:158`） | 覆盖它 = 全局生效；测试里已有先例（`test/remote/ssh_link_test.dart:53` `transportFactory: server.connect`） |
| 平台通道写法 | `RuntimePlugin.kt` + `runtime_bridge.dart` + `MainActivity.kt:43-65` | 新通道照抄 |
| 进程级单例 / 状态机 / 事件扇出 | `RuntimeController` + `EventSink` | 新 `TailnetBridgeManager` 照抄 |
| 前台服务与保活（可选） | `DshService` 的 `foreground()/acquireWakeLock()` 片段（:116-161） | 若要「后台保持 Tailnet」，抄这段而不要另写服务 |
| 网络变化信号 | `networkKicksProvider` / `networkKicks()`（`network_watch.dart:11-42`，connectivity_plus + AppLifecycleListener） | Tailnet 状态机同样要吃这个信号；**不要**自己再起一套 connectivity 监听 |
| 错误模型 | `HostLinkError` + `HostLinkErrorKind` + `HostLinkStatus`（`link_status.dart`） | 新错误码加进这个枚举，UI 已有渲染逻辑 |
| 测试替身 | `test/remote/support/fake_ssh.dart`（`FakeRemote`/`FakeChannel`/`server.connect`） | 可在纯 Dart 层完整测「LAN 失败 → 走 bridge」的分支，不需要真机 |
| DNS 注入 | `RuntimeController.refreshDns`（`DshService.kt:128-130` 调用处） | tsnet 的 DNS 若需要宿主解析，可参考其 `LinkProperties` 取法 |

---

## 8. 需要修改的代码（按侵入度从小到大）

> 前提：以下都基于 **fork 路线**（见第 9 节第 9 条）。如果负责人决定「独立插件仓 + 零改上游」，
> 那么「Dart 侧覆盖 Provider」这一步仍然需要在上游 app 内加一行 Provider 覆盖或用
> `flutter_inappwebview` 式的注入点——所以**完全零改动是不可能的，最小改动见 M1**。

### M1（最小侵入，Dart 侧 ~80 行，不动 Kotlin 的既有文件）

| 文件 | 改动 | 行数量级 |
|---|---|---|
| `app/lib/remote/tailnet/tailnet_bridge.dart` | **新增**：`MethodChannel('dsh/tailnet')` + `EventChannel('dsh/tailnet/events')` 封装，暴露 `start/stop/status/ensureEndpoint/releaseEndpoint/events`；模型照 `runtime_bridge.dart` | ~150 |
| `app/lib/remote/tailnet/tailnet_transport.dart` | **新增**：`SshTransportFactory` 的包装实现——先试直连，失败后 `ensureEndpoint` 并把 `SshConnectParams` 的 host/port 换成 loopback 端点（**保留 user/auth/secrets/connectTimeout**） | ~80 |
| `app/lib/state/connection_state.dart:158` | **改 1 行**：`sshTransportFactoryProvider` 的默认值换成上面的包装工厂（用 `ref` 读设置） | 1 |
| `app/lib/state/hosts_state.dart` + `ssh_host_config.dart` | **新增字段** `embeddedTailnet: bool`（默认 false）、`tailnetTargetHost/Port`（可选，默认取 host/port）；`toJson/fromJson/copyWith/==/hashCode` 各补一行 | ~20 |
| `app/lib/ui/remote/ssh_host_form.dart` | 表单加一个开关 + 状态行（复用 `FormFieldBlock`） | ~60 |
| `app/lib/remote/link_status.dart` | 新增 `HostLinkErrorKind.tailnetNotReady / tailnetAuthRequired` 等 | ~5 |

### M2（Kotlin 侧新文件，不动既有实现）

| 文件 | 内容 |
|---|---|
| `app/android/.../tailnet/TailnetPlugin.kt` | **新增** `FlutterPlugin`：`MethodChannel dsh/tailnet` + `EventChannel dsh/tailnet/events`；所有阻塞调用扔到单线程 executor；`onDetachedFromEngine` 只解绑 sink，不停 Go 实例 |
| `app/android/.../tailnet/TailnetBridgeManager.kt` | **新增** 进程级单例（照 `RuntimeController.get(ctx)`）：持有 Go 实例、状态机（STOPPED/STARTING/AUTH_REQUIRED/CONNECTING/CONNECTED/DEGRADED/ERROR）、事件扇出、`ensureEndpoint` 结果缓存 |
| `app/android/.../tailnet/TailnetStateDir.kt` | **新增**：`context.noBackupFilesDir/tailnet/<nodeId>/`（不用 cacheDir，见计划书 7.2），0700 收紧 |
| `app/android/app/src/main/kotlin/.../MainActivity.kt:43-65` | **改 1 行**：`engine.plugins.add(TailnetPlugin())` |
| `app/android/app/build.gradle.kts` | **加** AAR 依赖 + 按 flavor 的 abi 排除（见 5.1） |

### M3（Go 模块，全新）

计划书 3.2 的 `native/tailnet/` 目录建议**改成** `app/android/tailnet-go/`（跟随现有「原生相关放 app/android」的组织），
或独立仓库 `dsh-go-tailnet/`。文件职责分配本身没问题（server/bridge/tunnel/config/status/errors），
但需要补三个计划书没提的：

- `netstack_probe.go`：启动前自检（能否创建 netstack、UDP 出站、DNS 目标）——把 P2 的失败从「崩溃」变成「结构化错误码」。
- `log.go`：Go 日志 → Kotlin 的桥（`gomobile` 里 `log.SetOutput` 到一个 `io.Writer`，再由 Java 回调转 `Log.i`）。
  **必须脱敏**：auth key、node key、DSH token 一律不进日志。
- `statefs.go`：状态目录的文件权限、原子写、跨进程崩溃后的一致性检查（计划书 7.2 只说要收紧权限，没说要检测半写）。

---

## 9. 与原设计不一致的地方（重要，逐条给结论）

### 9.1 路径线索类（计划书 2.2 的假设 vs 实际）

| 计划书写的 | 实际 | 处理 |
|---|---|---|
| `app/lib/remote/ssh/ssh_transport_factory.dart（如果存在）` | **不存在**。`typedef SshTransportFactory` 在 `ssh_transport.dart:94`，Provider 在 `state/connection_state.dart:158` | 不需新建该文件，直接覆盖 Provider |
| `app/lib/remote/ssh/` 下找 `network_route.dart` | `network_route.dart` 在 `lib/remote/relay/`（34 行，是 DSH Remote 的 ICE 路径选择，**与 SSH 无关**） | 不要拿它做 SSH 路径判断，它是 relay 专用 |
| `DshService` 对应 Kotlin 文件 | 有，但职责是**本地引擎**前台服务（第 4 节） | 第九章要改写（见 9.2-2） |
| 「是否已有独立 Flutter Plugin」 | 没有独立插件目录：`packages/` 下是**纯 Dart 包**（`dsh_client`、`dsh_remote`），Kotlin 插件全部写在 `app/android` 内部并手动注册 | P3 的 Plugin 结构要重定（见 9.2-3） |
| 「Go 是否已经存在于仓库」 | **完全没有**（0 个 `.go`、0 个 `go.mod`） | 全新引入，需新建目录 + 版本锁定 |

### 9.2 设计类（会导致返工的）

**1）目标地址限制（计划书 6.2）在现有结构里怎么落地**
Bridge 的目标必须来自 `SshConnectParams.host/port`，而它来自用户可编辑的 Host 表单。
所以「第一版只允许 `NAS_IP:22`」不能是硬编码 IP —— 正确做法：**Go 侧只接受「与启动时配置的允许列表一致」的目标**，
白名单由 Kotlin 从 `SshHostConfig` 推导后传入（或 Kotlin 侧直接拒掉不匹配的 ensureEndpoint）。
硬编码 `100.x.y.z` 会违反约束 9（用户可用自己的 Host 配置）。

**2）Go 实例不能挂在 DshService 上**（第 4 节）
计划书 3.1 的图里 `Kotlin TailnetBridgeManager` 画在 Flutter 之下、隐含由 Service 持有。
实际：纯远程用户不跑 `DshService`。改成进程级单例后，P5 再决定「是否需要一个专门的前台服务保活」。

**3）Flutter Plugin 的物理位置要改**
计划书 5 建议 `app/packages/tailscale_bridge/`。本项目 `packages/` 是纯 Dart 包（无 Android 子工程），
现成的原生扩展方式是**写在 app 内**。建议：`app/lib/remote/tailnet/`（Dart）+ `app/android/.../tailnet/`（Kotlin），
**不做 out-of-tree Flutter Plugin**。否则要额外引入 path 依赖 + 在 `main.dart` 里手动注册插件，反而增加上游冲突面。

**4）第三章「Server.Dial 会使用 tsnet 管理的 Tailnet 网络栈」是对的，但 P2 要额外验证两个点**
- `tsnet.Server` 在**同一个 App 进程**里跑（不是 proot 里）。proot 里的 Linux 用户态**不能**作为宿主：
  它没有 TUN、没有 root、也没有独立的网络命名空间。这点计划书没说，但直接影响「Go 代码放哪跑」。
- `Server.Dial` 的目标如果是**主机名**（不是 IP），会依赖 MagicDNS；Android 没有 `/etc/resolv.conf`，
  tsnet 的 DNS 需要显式配置。**第一版建议只支持 IP 目标**（NAS 的 `100.x` 地址），把 DNS 风险推后。

**5）「不修改 ssh_transport.dart」可以实现，但要接受一个副作用**
覆盖工厂后，**错误信息来源变了**：LAN 直连失败时的 `SocketException` 现在发生在包装工厂里，
`describeSocketError`（`ssh_transport.dart:190-216`）的文案是基于 `params.host/port` 生成的。
如果包装工厂改了 host/port 却直接抛原异常，UI 会显示 `127.0.0.1:xxxxx 拒绝连接`——**对用户是误导**。
解决：包装工厂在换端点失败时，自己构造 `HostLinkError`，把**原始目标地址**写进文案（`params.host:params.port` 保留在闭包里）。

**6）「多 SSH 会话」的现状**
`hostLinkProvider` 是 `Provider.autoDispose.family<HostLink?, HostRef>`（`connection_state.dart:186`），
**每个 Host 一条链路**，同 Host 复用同一 `SshHostLink`；`LocalForwarder` 内支持多 socket（`_pairs`）。
所以 bridge 侧不需要「全局单 tunnel」，但**也不该是「每会话一条 tsnet Server」**——
正确模型：**一个 tsnet Server + 一个 loopback listener + 每连接一个 goroutine**（计划书 6.2 写对了）。

**7）计划书 8.1 的「LAN 优先」在现有代码里没有对应物**
现状：`SshHostLink` 直接连 `config.host`，没有「先试 LAN 再试 Tailnet」的分支。
新增的包装工厂就是这层逻辑的落点，但它**必须放在 `SshConnectParams` 层面**（而不是写进 UI），
否则「测试连接」和真实连接行为会不一致。

**8）LICENSE 与上游协作（最容易被忽略的一条）**
- 仓库是 **AGPL-3.0**（`LICENSE:1`）。把内嵌 Tailnet 合进 APK 分发 → 整个组合需按 AGPL 提供源码。
- 仓库 `AGENTS.md` 明确「**不接受任何外部 Pull Request**」「禁止合并外部 PR」。
- 结论：**不要走「给上游提 PR」路线**。建议 `dsh-go-tailnet` 作为独立 fork（保留 AGPL 与 NOTICE），
  或做成「上游 + 补丁目录」的构建方式（`runtime/patches/` 已有补丁机制的先例，但那是给 DSH 引擎用的，不是给 app 用的）。

**9）本报告的产出位置**
计划书写 `docs/embedded-tailnet/source-audit.md`。因为被调查的是第三方仓库且不接受 PR，
本报告放在**独立工作区** `/workspace/projects/embedded-tailnet/docs/embedded-tailnet/source-audit.md`，
clone 留在 `/workspace/tmp/dsh-audit/dsh-Go`（不入库、不提交）。如果要放进 fork 的 `docs/` 下，
负责人说一声即可移动。

**10）交互登录实测可行，不需要 auth key（计划书 7.1 的疑点已解）**

计划书说「如果 Android gomobile 环境下无法顺利完成交互登录，则单独评估 auth key 方案」。
本环境的实测（`p2-probe-log.md` §4）显示：`tsnet` 未登录时 `Up()` 会自己发起
`StartLoginInteractive` 并把登录 URL 打出来（`https://login.tailscale.com/a/...`），
认证在**用户自己的手机浏览器**里完成，设备端只要把 URL 递出去。

因此第一版**不需要 auth key**，7.1 的六条禁令不会被触碰。
Kotlin 侧要做的是把 `ipnstate` / `LocalClient.Status()` 里的 `AuthURL` 透出来（`AUTH_REQUIRED` 状态），
Dart 侧用 `url_launcher` 打开即可。auth key 只留给 CI/回归自动化，且必须走 `SecretStore`，不进 APK。

---

## 10. 环境实测结果（P2 前瞻探测，非 P2 验收）

### 10.1 本沙箱的工具链现状（实测）

```
$ which go flutter dart java gradle adb
（全部不存在）
$ ls ~/Android/Sdk/ndk            → 无
$ $ANDROID_NDK_HOME / $ANDROID_HOME → 空
磁盘 1.7T 可用 / 内存 14G（够做 Go 侧编译，不够跑 Android 构建）
```

结论：**P2 的真机 Gate 在当前环境无法执行**。任何「P2 完成」的结论都不能在这里下（计划书第十六章第 10 条）。

### 10.2 已做的替代探测（全部实测，原始输出在 `p2-probe-log.md`）

| 探测 | 命令 | 结果 |
|---|---|---|
| A 基线 | `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build` | ✅ 31 MB，2m17s，ELF x86-64 EXEC |
| B **关键** | `CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build` | ✅ **30 MB，1m56s，ELF AArch64 PIE**（type=3） |
| C cgo | `CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build` | ❌ `cgo: C compiler "gcc" not found` → 需要 NDK clang |
| D 运行 | 跑 linux 版 25s | ✅ Go runtime 起、netstack 初始化、`LocalBackend state is NeedsLogin`、**输出登录 URL** |
| E 状态目录 | 看 `/tmp/tsnet-state` | ✅ tsnet 自建 `0700`/`0600`，`tailscaled.state` 119 B（未登录） |
| F AAR | `gomobile bind -target=android/arm64 -androidapi 26` | ❌ `could not locate Android SDK`（需 SDK+NDK） |

版本：`tailscale.com v1.104.5`（与 NAS 宿主同版本）、`gvisor v0.0.0-20260915`、`wireguard-go v0.0.0-20260928`、
`golang.org/x/mobile v0.0.0-20261011`。

**这意味着**：P2 的「任务 A 编译验证」已经有一半答案是**肯定的**（纯 Go 无 cgo 可交叉编译），
剩下的是「AAR 构建 + 真机运行」，两项都卡在 NDK/真机上，必须换环境。

### 10.3 待负责人提供/确认的环境项（P1、P2 必需）

| # | 项 | 为什么必须要 |
|---|---|---|
| E1 | 一台能跑 `flutter`/`gradle`/`adb` 的机器（或 GitHub Actions） | 本沙箱只有 Go，没有 Android 构建链 |
| E2 | **真实 Android 手机**（arm64，Android 8+） | P2 的唯一验收环境；模拟器不算（计划书第十六章第 5 条） |
| E3 | Tailnet 的 auth 方式决策（交互式登录 vs 一次性 key） | 决定 AAR 的 API 形状；不得写进 APK |
| E4 | NAD 侧 `100.x.y.z:22` 可达性（已在前序会话确认宿主有 tailscale0） | P0/P1 的目标 |
| E5 | NDK 版本钉死值（计划书 13.1） | 现在仓库只有 `flutter.ndkVersion`，未钉死 |

---

## 11. 下一步（等审阅后再动）

1. 负责人审阅本报告，确认三条路线选择：
   - **路线 A**：fork `dsh-Go`（AGPL 合规，改动 M1+M2+M3 全做）；
   - **路线 B**：独立插件仓 + 最小 patch（上游加 ~1 行 Provider 覆盖），其余全在新仓；
   - **路线 C**：先只做 P1/P2 的独立 PoC（Go + AAR + 一个最小 Kotlin 测试 App），不碰 dsh-Go。
     —— 本鲸鱼娘建议 **C → A**：先用最小 App 过 P2 Gate，再决定怎么并进 dsh-Go。
2. 确认后进入 P1（Linux tsnet PoC，本沙箱可完整执行，不需要 NDK）。
3. P2 需要 E1/E2（人 + 真机），否则只能停在「编译通过」这一格。

---

## 附录 A：本次调查实际执行的命令（可复现）

```bash
# 定位与 clone
curl -s "https://api.github.com/search/repositories?q=dsh-go+in:name&per_page=20"   # 确认仓库
git clone --depth 50 https://github.com/ccch1mneyyy/dsh-Go.git                      # 601MB
git log -1 --format="%H %ci %s"                                                     # 基线提交

# 源码核对（全部只读）
grep -rn "SshHostLink(\|transportFactory:" app/lib/
grep -rn "sshTransportFactoryProvider" app/lib/
grep -rni "tsnet\|tailscale" --include=*.dart --include=*.kt --include=*.md app/ packages/ docs/
find . -name "*.go" -o -name "go.mod"        # 空 → 仓库无 Go
sed -n ... app/lib/remote/ssh/*.dart          # 逐文件读
wc -l app/lib/remote/**/*.dart app/android/.../runtime/*.kt

# 环境
which go flutter dart java gradle adb        # 全无
```

## 附录 B：Go / tsnet 编译探测原始输出

见本文件同目录的 **`p2-probe-log.md`**（已跑完，6 项实测：linux 基线 / android-arm64 交叉编译 /
cgo 失败 / 25 秒真跑输出登录 URL / 状态目录权限 / gomobile bind 报 SDK 缺失）。
探测工程：`/workspace/tmp/tsnet-probe`；Go 工具链：`/workspace/tmp/gotool/go`（go1.27.3）。
两处都在 workspace 内，未安装到系统、未改动任何仓库文件。
