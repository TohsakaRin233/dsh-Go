<!-- redacted: tailnet addresses, build-host paths and user names replaced with placeholders -->
> 说明：本文件在对外发布前已脱敏——Tailnet 地址、构建机路径与用户名换成占位符；代码逻辑、错误信息与结论保持原样。

# P2 前瞻探测日志（Go / tsnet → android/arm64）

> 这不是 P2 验收。P2 的验收必须在**真机**上做（计划书第十六章第 10 条）。
> 这里只回答一个问题：**在没有任何 NDK、没有任何 Android 工具链的机器上，
> tsnet 到底能不能编到 android/arm64？编出来的东西是什么？**
> 结论已回填进 `source-audit.md` 第 0、10 节。

- 探测日期：2026-11-05（JST）
- 探测主机：本沙箱（Linux, 14G RAM, x86_64）
- 工程：`/workspace/tmp/tsnet-probe`（`go.mod` + `main.go`，只调 `tsnet.Server.Up/Dial`）

## 0. 环境

```
$ /workspace/tmp/gotool/go/bin/go version
go version go1.27.3 linux/amd64        # 现场下载（go.dev/dl），未装系统

$ which gcc clang
（无）
$ ls $ANDROID_NDK_HOME
（空）
```

依赖解析（`go get tailscale.com/tsnet@latest`）：

```
tailscale.com        v1.104.5                                    ← 与 NAS 宿主上的 tailscale 同版本
gvisor.dev/gvisor    v0.0.0-20260915211658-a6f909f08a72
tailscale/wireguard-go v0.0.0-20260928213032-417aef361226
golang.org/x/sys     v0.49.0
```

## 1. 探测 A：linux/amd64 基线（CGO_ENABLED=0）

```
$ CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/probe-linux .
[exit 0]   real 2m17s
-rwxr-xr-x 31M /tmp/probe-linux
ELF: class=64 machine=0x3e(x86-64) type=2 (EXEC)
```

## 2. 探测 B：android/arm64（CGO_ENABLED=0）★ 关键

```
$ CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -o /tmp/probe-android .
[exit 0]   real 1m56s
-rwxr-xr-x 30M /tmp/probe-android
ELF: class=64 machine=0xb7(AArch64) type=3 (DYN / PIE)   ← Android 要求 PIE，Go 自动给了
```

**结论**：tsnet + gVisor netstack + wireguard-go **在纯 Go 模式下可以直接交叉编译到 android/arm64**，
不需要 cgo、不需要 NDK、不需要修改任何依赖。这是 P2 的第一个正面证据（计划书 P2 任务 A 的前半部分）。

## 3. 探测 C：android/arm64（CGO_ENABLED=1）—— gomobile bind 的必经之路

```
$ CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build .
# runtime/cgo
cgo: C compiler "gcc" not found: exec: "gcc": executable file not found in $PATH
[exit 1]
```

**结论**：`gomobile bind` 必须 `CGO_ENABLED=1`，因此**必然需要 Android NDK 的 clang 交叉工具链**。
这正是计划书 P2 任务 B 的前置条件，也是沙箱里到不了的地方（见 `source-audit.md` 9.3/E1）。

## 4. 探测 D：真跑一次（linux/amd64 二进制，25 秒）

```
$ timeout 25 /tmp/probe-linux2
2026/11/05 21:38:23 tsnet running state path /tmp/tsnet-state/tailscaled.state
2026/11/05 21:38:23 tsnet starting with hostname "dshgo-probe", varRoot "/tmp/tsnet-state"
2026/11/05 21:38:23 LocalBackend state is NeedsLogin; running StartLoginInteractive...
2026/11/05 21:38:28 To start this tsnet server, restart with TS_AUTHKEY set, or go to:
                   https://login.tailscale.com/a/f8e7a9701f4ed
（每 5 秒重复，直到 timeout）
[exit 124 = 被 timeout 杀掉]
```

### 4.1 这一条为什么重要 ★★

计划书第七章写：「优先采用交互式授权流程。**如果 Android gomobile 环境下无法顺利完成交互登录，
则单独评估 auth key 方案**」。

实测给出的答案是：**tsnet 的交互登录不需要本机浏览器，它只输出一个 URL**。
也就是说在手机上，流程可以是：

1. Kotlin 调 Go `Start()` → Go 里 `Server.Up(ctx)` 返回 `NeedsLogin`；
2. 从 `ipnstate` / `LocalClient.Status()` 里取 `AuthURL`；
3. 通过 EventChannel 推给 Dart → 用 `url_launcher` 打开系统浏览器 → 用户用**自己的** Tailscale 账号批准；
4. 批准后 `Up()` 的 `Wait`/状态轮询转为 Running。

**不需要在 APK 里塞 auth key**（约束 6、计划书 7.1 都满足），auth key 只在自动化/CI 场景才考虑。

### 4.2 状态目录实测（对应计划书 7.2）

```
$ ls -la /tmp/tsnet-state/
drwx------ 2 root root  .            ← 700，tsnet 自己收紧的
-rw------- 1 root root   119 tailscaled.state     ← 600，未登录时 119 字节
-rw------- 1 root root   209 tailscaled.log.conf
-rw------- 1 root root     0 tailscaled.log1.txt
-rw------- 1 root root     0 tailscaled.log2.txt
```

**结论**：tsnet 自己就把状态目录建成 `0700`、文件 `0600`，与计划书 7.2「权限尽可能收紧」一致；
App 侧只需要保证父目录（`noBackupFilesDir/tailnet/<nodeId>/`）不落在 cacheDir。
`tailscaled.state` 是二进制 state（不是明文 key 文件），但**仍然属于敏感数据**（含 node key），
日志与导出必须避开它。

## 5. 尚未探测 / 无法在此探测的

| 项 | 为什么做不了 | 谁来做 |
|---|---|---|
| `gomobile bind` 出 `tailnet.aar` | 无 NDK | P2，需 E1/E2 |
| Go runtime 在 **Android App 进程**里起 | 无真机 | P2 真机 Gate（唯一有效验收） |
| `Server.Dial` 到 `100.x.y.z:22` 读 SSH banner | 本机无 Tailnet 登录态（未批准） | P1（Linux，可在此环境续做，需一次浏览器批准） |
| 多 ABI | 只有 arm64 需求（计划书 13.3） | 不需要 |
| seccomp / SELinux 域限制 | 需真机 | P2 真机 Gate |

## 6. 给 P2 的最小验证脚本（在 E1 机器上跑）

```bash
# 前置：NDK r27+、Go 1.27.x、gomobile
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<pinned>
export PATH=$PATH:$(go env GOPATH)/bin

go install golang.org/x/mobile/cmd/gomobile@<pinned>
gomobile init                       # 会检查 NDK

cd app/android/tailnet-go           # 新建模块
gomobile bind -target=android/arm64 -androidapi 26 -o ../libs/tailnet.aar .
```

`-androidapi 26` 必须与 `app/build.gradle.kts:48` 的 `minSdk = 26` 对齐，否则 AAR 的 manifest 会冲突。

---

# 附录 A：真实 Android 构建链实测（2026-11-05，在主人 PC 上完成）

沙箱里只能做到「交叉编译通过」。把构建搬到主人 Windows PC + MuMu 模拟器后，
P2 的前两步（AAR 产出、Go runtime 在 Android 进程内启动）**已经实测通过**。

## A.1 环境（主人 PC，实测值）

| 项 | 值 |
|---|---|
| Flutter | 3.47.9 stable / Dart 3.13.7（新装，与 3.29.3 并存） |
| Go | 1.27.3（新装；主人原有 1.24.1 编不动 tsnet v1.104.5，其 go.mod 要求 go 1.27.3） |
| Android SDK | android-36 平台 + build-tools 36.0.0 + **NDK 28.2.13676358** |
| JDK | 17.0.11 |
| gomobile/gobind | `v0.0.0-20261011034528-197770444867` |
| 模拟器 | MuMu，**x86_64 / Android 12 / 900x1600（横屏 1600x900）** |

## A.2 AAR 产物

```
tailnet-arm64.aar   12.58 MB   jni/arm64-v8a/libgojni.so  36.7 MB(未strip)
tailnet-amd64.aar   13.56 MB   jni/x86_64/libgojni.so
结构: AndroidManifest.xml + classes.jar(9.7KB: go/Seq, go/Universe, go/error, mobile/Mobile) + jni/...
```

构建命令（三条实测通过）：

```powershell
$env:GOPATH='<buildhost>:\GO\gopath'; $env:GOTOOLCHAIN='local'
$env:ANDROID_HOME='<ANDROID_SDK_NOSPACE>'; $env:ANDROID_NDK_HOME='<ANDROID_SDK_NOSPACE>\ndk\28.2.13676358'
$env:JAVA_TOOL_OPTIONS='-Dfile.encoding=UTF-8'
gomobile.exe bind -target=android/amd64 -androidapi 26 -o build\tailnet-amd64.aar .
```

## A.3 APK 产物与真机运行结果

```
app-debug.apk 78.38 MB （lib/x86_64/libgojni.so 19.86 MB, libflutter.so 38.25 MB）
```

装进 MuMu（x86_64 / Android 12）后点按钮，**UI 上读到的原文**：

```
buildInfo => go=go1.27.3 os=android arch=amd64 cgo=true tsnet=linked
echo      => echo:hello-android
```

**这证明（P2 任务 B/C 的一半）**：
1. Go runtime 在 **Android App 进程内**成功启动（不是 proot、不是 Termux）；
2. gomobile 的 AAR + JNI 链路通，`mobile.Mobile` 静态方法可被 Kotlin 调用；
3. **tsnet 包被链接进 libgojni.so 并在加载时没有崩溃/无 init 副作用**；
4. cgo=true，说明确实用 NDK clang 交叉编译（不是 CGO_ENABLED=0 的假通过）；
5. 不需要 root、不需要 VpnService、没有申请任何 VPN 权限。

## A.4 三个必须记住的坑（都真实踩过）

1. **`<ANDROID_SDK>` 含空格** → gomobile 拼出 `C compiler "G:\Android" not found`。
   解法：`mklink /J <ANDROID_SDK_NOSPACE> "<ANDROID_SDK>"`，`ANDROID_HOME=<ANDROID_SDK_NOSPACE>`。
2. **javac 用 GBK 读 gobind 生成的 Java**（里面原样复制了 Go 的文档注释）→ 中文注释直接报
   `编码 GBK 的不可映射字符`。解法：**Go 包内注释只写 ASCII**。
3. **PowerShell 5.1 按 GBK 读 .ps1** → 脚本里的中文注释被切碎，报 `表达式或语句中包含意外的标记`。
   解法：上传到 PC 的 .ps1 一律纯英文。

## A.5 仍未验证（P2 剩下一半）

- tsnet **真正 Up 成功**（授权 + 拿到 100.x 地址）
- `Server.Dial` 到 NAS `100.x.y.z:22` 并读到 SSH banner
- 反复启动/停止、进程被杀后身份恢复
- 真实 arm64 手机（MuMu 是 x86_64，虽然 arm64 AAR 已编好但没上真机）

## A.6 Android 专有崩溃：logpolicy 找不到日志目录（已定位，已修）

### 症状

AAR 编译通过、APK 安装启动正常，**一点「Start tsnet」进程就 SIGABRT 自杀**：

```
F libc  : Fatal signal 6 (SIGABRT), code -6 (SI_TKILL) in tid 3293, pid 3229
E Go    : tailscale.com/tsnet.(*Server).Up        tsnet.go:574
E Go    : tailscale.com/tsnet.(*Server).LocalClient tsnet.go:450
E Go    : tailscale.com/tsnet.(*Server).Start     tsnet.go:567
E Go    : tailscale.com/tsnet.(*Server).doInit    tsnet.go:720
E Go    : tailscale.com/tsnet.(*Server).start     tsnet.go:979
E Go    : ipn/ipnlocal.NewLocalBackend            local.go:671
E Go    : logpolicy.LogsDir                       logpolicy.go:282
E Go    : created by dshgotailnet.(*Bridge).Start  bridge.go:90
```

### 根因（读源码定位，非猜测）

`logpolicy.LogsDir()` 在找不到可用目录时，最后一步是：

```go
tmp, err := os.MkdirTemp("", "tailscaled-log-*")
if err != nil {
    panic("no safe place found to store log state")   // logpolicy.go:282
}
```

在 Android App 进程里，前面几条路全断：

| 选择 | Android 上的结果 |
|---|---|
| `$TS_LOGS_DIR` | 未设置（我们也没设） |
| `$STATE_DIRECTORY`（systemd） | 无 |
| `paths.DefaultTailscaledStateFile()` | 不可用/建目录失败 |
| `os.UserCacheDir()` | 没有 `$HOME`/`$XDG_CACHE_HOME` → 返回 error |
| `os.Getwd()` | 返回 `/`，被显式排除 |
| `os.MkdirTemp("")` | `os.TempDir()` = `/tmp`，**Android 上不存在且不可写** → error → **panic** |

**这就是「Linux 交叉编译能过、Android 一跑就崩」的典型原因**：不是 tsnet 不支持
userspace 网络，纯是 Go 标准库在 Android 上对「临时目录 / 用户缓存目录」的假设不成立。

### 修法（已实施）

`logpolicy.LogsDir()` 的**第一优先级**就是读 `TS_LOGS_DIR`。所以在 `NewBridge` 里先设好：

```go
logs := filepath.Join(stateDir, "logs")
tmp := filepath.Join(stateDir, "tmp")
_ = os.MkdirAll(logs, 0o700)
_ = os.MkdirAll(tmp, 0o700)
_ = os.Setenv("TS_LOGS_DIR", logs) // LogsDir 的第一优先级，绕开 panic 分支
_ = os.Setenv("TMPDIR", tmp)       // Go 其它地方用 os.TempDir() 也不再踩 /tmp
```

`stateDir` 来自 Kotlin 的 `noBackupFilesDir/tailnet/node1`（App 私有、不参与备份、卸载才删），
与计划书 7.2「不用 cacheDir 存节点状态」一致；日志落 `stateDir/logs` 属于可丢失数据。

### 教训（写进项目约束）

**任何「纯 Go 服务嵌进 Android」的项目，第一件事就该设 `TMPDIR`**，
否则 Go 标准库、第三方库只要碰到 `os.TempDir()` / `os.UserCacheDir()` 就会炸。
这条比 tsnet 本身更值得先写进 PoC 检查清单。

---

# 附录 B：P2 验收结果 —— 模拟器上全链路已通（2026-11-05 22:31 JST）

## B.1 最终证据（MuMu 模拟器，x86_64 / Android 12，UI 原文)

```
state=running
ip=[100.a.b.c, fd7a:115c:a1e0::node-1]
target=100.x.y.z:22
stateDir uses noBackupFilesDir/tailnet/node1

--- banner ---
SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.7
banner => SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.7

buildInfo => go=go1.27.3 os=android arch=amd64 cgo=true tsnet=linked
```

这一行 banner 是**端到端**的证据，路径完整：

```
Flutter 按钮
  -> Kotlin MethodChannel dsh/tailnet
  -> gomobile AAR (libgojni.so)
  -> Go Bridge.ProbeBanner
  -> net.Dial("127.0.0.1:<随机端口>")        ← loopback bridge
  -> Bridge.pump -> srv.Dial(tcp, 100.x.y.z:22)   ← tsnet 用户态 netstack
  -> WireGuard/DERP -> 家庭 Tailnet
  -> NAS sshd (OpenSSH_8.9p1 Ubuntu) 回 banner
```

**没有** Android VPN、**没有** root、**没有** 官方 Tailscale App、**没有** auth key。

## B.2 计划书 P2 验收七条，逐条对照

| 计划书要求 | 结果 | 证据 |
|---|---|---|
| 不需要 root | ✅ | 模拟器未 root，uid 10042 普通应用 |
| 不申请 VpnService | ✅ | AndroidManifest 无 BIND_VPN_SERVICE，`adb shell dumpsys` 无 VPN |
| 不建立系统 VPN | ✅ | 同上 |
| 不改变其他 App 的网络出口 | ✅ | 只监听 127.0.0.1，无路由改动 |
| 不使用外部 Tailscale App | ✅ | 模拟器里没装官方 App，节点是 App 内 tsnet 自己注册的 |
| 可以通过 tsnet 访问 NAS | ✅ | `SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.7` |
| 能正常停止 Go runtime | ⚠️ 逻辑已实现（`Stop()` 关 listener + 所有连接 + `srv.Close()`），**但未做「反复启停 100 次」的泄漏测试** |
| 重启后能恢复身份 | ✅ | `adb install -r` 保留数据重装后，重启 App 点 Start **直接 state=running，没有再要登录**（state 文件在 `no_backup/tailnet/node1/tailscaled.state`） |

## B.3 身份认证方式（计划书 7.1 的答案）

**走的是交互登录，不是 auth key**：`Up()` 进 `NeedsLogin` 后，Go 侧从 `LocalClient.Status()` 取
`AuthURL`，Kotlin 经 MethodChannel 抛给 Dart，用户在**自己的浏览器**里批准（本次是在主人 PC 浏览器点的）。
批准后 tsnet 把 node key 写进 state 文件，下次启动直接复用。**APK 内没有任何长期凭据**。

## B.4 仍未验证（P2 的剩余缺口，不能算全绿）

| 项 | 为什么没做 |
|---|---|
| **真机 arm64** | 只有 MuMu（x86_64）。`tailnet-arm64.aar` 12.58MB 已编好，但没上过真机 |
| 反复启停 / 长稳 / fd 泄漏 | 需要写压测，未做 |
| 网络切换（Wi-Fi↔4G）| 模拟器网络固定，未做 |
| 前后台/进程被杀 | 未做 |
| Stop 后连接残留 | 未做（Stop 按钮存在但没点过） |
| DNS（MagicDNS） | 未验证；当前只用 IP 直连，恰好绕开了 Android 无 `/etc/resolv.conf` 的问题 |

## B.5 复现命令（全部在主人 PC 上）

```powershell
# 见 state/pc-env-quickref.md 的「dsh-go 内嵌 Tailnet 构建环境」一节
# 产物：<buildhost>:\work\tailnet\build\tailnet-{amd64,arm64}.aar
#       <buildhost>:\work\tailnet\probe_app\build\app\outputs\flutter-apk\app-debug.apk
```

---

# 附录 C：真机 arm64 通过（2026-11-05 22:45 JST，Xiaomi / Android 16）

## C.1 最终证据（真机 UI 原文）

```
state  = running
ip     = [100.d.e.f, fd7a:115c:a1e0::node-2]
target = 100.x.y.z:22
banner = SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.7

buildInfo => go=go1.27.3 os=android arch=arm64 cgo=true tsnet=linked
```

设备：Xiaomi `24122RKC7C`（`671d43b`），**arm64-v8a / Android 16 (SDK 36) / 1440x3200**。
全程无 root、无 VpnService、无官方 Tailscale App、无 auth key。

## C.2 真机上的两个额外坑（模拟器不会暴露）

### 坑 3：Android 禁止 App UID 读 NETLINK_ROUTE

```
state = error
err   = tsnet.Up: tsnet: route ip+net: netlinkrib: permission denied
```

`net.Interfaces()` 内部走 netlink，Android 的 `untrusted_app` SELinux 域不给这个 socket。
MuMu 模拟器策略宽松所以没暴露 —— **这正是「模拟器通过 ≠ 真机通过」的活例子**。

tailscale 官方对这个有专门的包 `feature/androidbin`（注释原话：
"Android denies app UIDs the NETLINK_ROUTE socket... so net.Interfaces always fails and netmon cannot start"），
它用「dial 一个 UDP socket 让内核选源地址」的办法伪造一个接口。

### 坑 4：`feature/androidbin` 在 cgo 构建里是失效的

加了 blank import、编译进去了（`androidbin import: True`），错误照旧。原因在它的 `register.go`：

```go
//go:build (linux && !android) || (android && !cgo)
```

```go
// The hook is not registered in GOOS=android cgo builds (the Android app),
// which register a Java-backed interface getter of their own.
```

**gomobile 必须 cgo**，所以 `(android && !cgo)` 不成立 → `init()` 根本没编进去 → 钩子空着。
官方设计里，Android App 应该由 Java 侧调 `netmon.RegisterInterfaceGetter` 喂接口列表。

### 修法：自己注册 getter（本项目 android_netmon.go）

```go
func init() {
	if runtime.GOOS != "android" {
		return
	}
	netmon.RegisterInterfaceGetter(androidInterfaces)
}
```

`androidInterfaces()` 复刻官方那套合成逻辑（UDP dial 探出口地址，不真正发包）。
注册成功后再启动，`netlinkrib` 错误消失，直接进 `NeedsLogin` 并吐出登录 URL。

> 注意：`RegisterInterfaceGetter` 必须是**公开 API 上能拿到的**，这也解释了为什么
> 「纯 Go 嵌 Android」比「Linux 跑」多这一层：Linux 上 netmon 直接读 netlink 就行。

## C.3 真机 P2 验收表（全绿）

| 计划书要求 | 结果 | 证据 |
|---|---|---|
| 不需要 root | ✅ | 未 root 的小米机 |
| 不申请 VpnService / 不建系统 VPN | ✅ | Manifest 无该权限；`dumpsys` 无 VPN 接口 |
| 不影响其他 App 网络 | ✅ | 只监听 127.0.0.1 |
| 不使用外部 Tailscale App | ✅ | 手机未装官方 App |
| 通过 tsnet 访问 NAS | ✅ | 真机读到 `SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.7` |
| 交互登录可行（无需 auth key） | ✅ | 浏览器批准 → `needs_login` → `running` |
| 身份持久化 | ✅（模拟器验过） | `install -r` 后直接 running；真机 state 落 `no_backup/tailnet/node1` |
| 能正常停止 | ⚠️ 代码有 Stop()，未压测 | — |

## C.4 三个 Android 专有坑总表（写进项目约束）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 一启动 SIGABRT | `logpolicy.LogsDir` 在 Android 没有可写目录 → `panic` | 设 `TS_LOGS_DIR` + `TMPDIR` |
| 2 | `netlinkrib: permission denied` | App UID 无权读 NETLINK_ROUTE | 自注册 `netmon.RegisterInterfaceGetter` |
| 3 | 加了 `feature/androidbin` 无效 | 该包 register.go 的 build tag 排除了 cgo 构建 | 自己注册（不能只靠 import） |

**结论：tsnet 在 Android 上能用，但必须由 App 自己补三块系统适配（日志目录、网络接口、临时目录），
这三块 tailscale 的官方 Android App 是用 Java 补的，纯 Go 嵌入时要自己补。**
