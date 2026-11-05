// Package mobile exposes the embedded tailnet bridge to Android through
// gomobile. All comments in this package stay ASCII-only: gobind copies them
// into generated Java, and javac on a zh-CN Windows host reads that as GBK.
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/tsnet"
)

// states reported through StatusJSON.
const (
	StateIdle      = "idle"
	StateStarting  = "starting"
	StateNeedsAuth = "needs_login"
	StateRunning   = "running"
	StateError     = "error"
	StateStopped   = "stopped"
)

// Status is the JSON shape Kotlin polls. Keep the field names stable.
type Status struct {
	State      string   `json:"state"`
	AuthURL    string   `json:"authUrl,omitempty"`
	TailnetIP  []string `json:"tailnetIp,omitempty"`
	ListenPort int      `json:"listenPort,omitempty"`
	Target     string   `json:"target,omitempty"`
	Error      string   `json:"error,omitempty"`
	ConnCount  int      `json:"connCount"`
}

// Bridge owns one tsnet server plus one loopback TCP listener.
//
// Only one Bridge may exist per state directory; a second one would fight the
// first over the node identity.
type Bridge struct {
	mu       sync.Mutex
	stateDir string
	hostname string
	target   string // "ip:port", fixed at construction: no generic forwarding
	state    atomic.Value
	errText  atomic.Value
	authURL  atomic.Value
	ips      atomic.Value

	srv      *tsnet.Server
	ln       net.Listener
	conns    map[net.Conn]struct{}
	stopped  bool
	connSeq  atomic.Int64
	connLive atomic.Int64
	started  atomic.Bool
}

// NewBridge prepares a bridge. allowedTarget is the only destination this
// bridge will ever dial ("100.x.y.z:22" for the NAS in the first version).
func NewBridge(stateDir, hostname, allowedTarget string) *Bridge {
	// Android has no writable /tmp and no $HOME. logpolicy.LogsDir falls through
	// to os.MkdirTemp("") there and panics with "no safe place found to store log
	// state" (logpolicy.go:282), which aborts the whole process. TS_LOGS_DIR is
	// checked first by LogsDir, so pointing it at the app-private state dir skips
	// that fallback entirely. TMPDIR is set as well for the rest of the Go code.
	logs := filepath.Join(stateDir, "logs")
	tmp := filepath.Join(stateDir, "tmp")
	_ = os.MkdirAll(logs, 0o700)
	_ = os.MkdirAll(tmp, 0o700)
	_ = os.Setenv("TS_LOGS_DIR", logs)
	_ = os.Setenv("TMPDIR", tmp)

	b := &Bridge{stateDir: stateDir, hostname: hostname, target: allowedTarget, conns: map[net.Conn]struct{}{}}
	b.state.Store(StateIdle)
	return b
}

// Version reports build facts; handy as the very first JNI call.
func (b *Bridge) Version() string {
	return BuildInfo()
}

// Start launches tsnet in the background and returns immediately with the
// current status JSON. Up() blocks until the node is authorised, so it must
// never run on the caller's thread.
func (b *Bridge) Start() string {
	b.mu.Lock()
	if b.started.Load() {
		b.mu.Unlock()
		return b.StatusJSON()
	}
	b.started.Store(true)
	b.state.Store(StateStarting)
	b.mu.Unlock()

	go b.run()
	return b.StatusJSON()
}

func (b *Bridge) run() {
	srv := &tsnet.Server{
		Hostname: b.hostname,
		Dir:      b.stateDir,
		Logf:     func(string, ...any) {}, // never log keys or node state
	}
	b.mu.Lock()
	b.srv = srv
	b.mu.Unlock()

	// Watch for the auth URL while Up() is still blocked in NeedsLogin.
	go b.watchAuth()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	st, err := srv.Up(ctx)
	if err != nil {
		b.state.Store(StateError)
		b.errText.Store(err.Error())
		return
	}
	var ips []string
	for _, ip := range st.TailscaleIPs {
		ips = append(ips, ip.String())
	}
	b.ips.Store(ips)
	b.state.Store(StateRunning)
}

// watchAuth polls the local API for the interactive login URL so the phone can
// open it in a browser. No auth key is ever stored in the APK.
func (b *Bridge) watchAuth() {
	for i := 0; i < 120; i++ {
		if s := b.currentState(); s == StateRunning || s == StateError || s == StateStopped {
			return
		}
		b.mu.Lock()
		srv := b.srv
		b.mu.Unlock()
		if srv != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			lc, err := srv.LocalClient()
			if err == nil {
				if st, err := lc.Status(ctx); err == nil {
					if st.AuthURL != "" && b.authURL.Load() != st.AuthURL {
						b.authURL.Store(st.AuthURL)
						b.state.Store(StateNeedsAuth)
					}
					if st.BackendState == "Running" {
						b.state.Store(StateRunning)
					}
				}
			}
			cancel()
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func (b *Bridge) currentState() string {
	if v, _ := b.state.Load().(string); v != "" {
		return v
	}
	return StateIdle
}

// StatusJSON returns the pollable status as JSON.
func (b *Bridge) StatusJSON() string {
	s := Status{State: b.currentState(), Target: b.target, ConnCount: int(b.connLive.Load()), ListenPort: b.listenPort()}
	if v, ok := b.authURL.Load().(string); ok {
		s.AuthURL = v
	}
	if v, ok := b.ips.Load().([]string); ok {
		s.TailnetIP = v
	}
	if v, ok := b.errText.Load().(string); ok {
		s.Error = v
	}
	out, _ := json.Marshal(s)
	return string(out)
}

func (b *Bridge) listenPort() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln == nil {
		return 0
	}
	if a, ok := b.ln.Addr().(*net.TCPAddr); ok {
		return a.Port
	}
	return 0
}

// EnsureEndpoint opens the loopback listener (once) and returns its port.
// The listener only accepts connections from this device (127.0.0.1).
func (b *Bridge) EnsureEndpoint() (int32, error) {
	if b.currentState() != StateRunning {
		return 0, fmt.Errorf("tailnet not running (state=%s)", b.currentState())
	}
	b.mu.Lock()
	if b.stopped {
		b.mu.Unlock()
		return 0, errors.New("bridge stopped")
	}
	if b.ln != nil {
		port := b.ln.Addr().(*net.TCPAddr).Port
		b.mu.Unlock()
		return int32(port), nil
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.mu.Unlock()
		return 0, err
	}
	b.ln = ln
	b.mu.Unlock()

	go b.acceptLoop(ln)
	return int32(ln.Addr().(*net.TCPAddr).Port), nil
}

func (b *Bridge) acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
		}
		b.connSeq.Add(1)
		b.mu.Lock()
		if b.stopped {
			b.mu.Unlock()
			c.Close()
			return
		}
		b.conns[c] = struct{}{}
		b.connLive.Add(1)
		b.mu.Unlock()
		go b.pump(c)
	}
}

// pump forwards one loopback connection to the fixed tailnet target.
func (b *Bridge) pump(local net.Conn) {
	defer func() {
		b.mu.Lock()
		if _, ok := b.conns[local]; ok {
			delete(b.conns, local)
			b.connLive.Add(-1)
		}
		b.mu.Unlock()
		local.Close()
	}()

	b.mu.Lock()
	srv := b.srv
	b.mu.Unlock()
	if srv == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	remote, err := srv.Dial(ctx, "tcp", b.target)
	if err != nil {
		return
	}
	defer remote.Close()

	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(remote, local); done <- struct{}{} }()
	go func() { _, _ = io.Copy(local, remote); done <- struct{}{} }()
	<-done
	// Close both sides so a half-open TCP does not linger.
	local.Close()
	remote.Close()
	<-done
}

// Stop tears everything down; safe to call twice.
func (b *Bridge) Stop() {
	b.mu.Lock()
	if b.stopped {
		b.mu.Unlock()
		return
	}
	b.stopped = true
	ln := b.ln
	b.ln = nil
	conns := make([]net.Conn, 0, len(b.conns))
	for c := range b.conns {
		conns = append(conns, c)
	}
	srv := b.srv
	b.mu.Unlock()

	b.state.Store(StateStopped)
	if ln != nil {
		_ = ln.Close()
	}
	for _, c := range conns {
		_ = c.Close()
	}
	if srv != nil {
		_ = srv.Close()
	}
}

// ProbeBanner opens the loopback endpoint, connects through it, and returns the
// first bytes the far side sends (the SSH banner). This is the end-to-end
// check: loopback listener -> tsnet dial -> NAS sshd.
func (b *Bridge) ProbeBanner(timeoutSec int) string {
	if timeoutSec <= 0 {
		timeoutSec = 15
	}
	port, err := b.EnsureEndpoint()
	if err != nil {
		return "ERR endpoint: " + err.Error()
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout("tcp", addr, time.Duration(timeoutSec)*time.Second)
	if err != nil {
		return "ERR dial " + addr + ": " + err.Error()
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Duration(timeoutSec) * time.Second))
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil && n == 0 {
		return "ERR read: " + err.Error()
	}
	return strings.TrimSpace(string(buf[:n]))
}
