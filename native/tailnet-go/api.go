// Package mobile is the gomobile binding smoke layer: it first proves the Go
// runtime and tsnet can load inside an Android process (P2 step 1), then grows
// the real bridge (P2 step 2).
//
// NOTE: keep every comment in this package ASCII-only. gobind copies Go doc
// comments into generated Java files, and javac on a zh-CN Windows host reads
// them as GBK and fails with "unmappable character".
package mobile

import (
	"fmt"
	"runtime"

	"tailscale.com/tsnet"
)

// Echo proves the AAR -> JNI -> Go path end to end.
func Echo(s string) string {
	return "echo:" + s
}

// BuildInfo reports the Go runtime and forces tsnet into the binary.
// If tsnet had an init-time side effect (probing host networking, for
// example), loading this symbol would surface it.
func BuildInfo() string {
	var marker *tsnet.Server
	_ = marker
	return fmt.Sprintf("go=%s os=%s arch=%s cgo=%v tsnet=linked",
		runtime.Version(), runtime.GOOS, runtime.GOARCH, cgoEnabled)
}
