package mobile

// Android app UIDs are denied the NETLINK_ROUTE socket and /proc/net, so
// net.Interfaces() always fails and tailscale's netmon cannot start:
//
//	tsnet.Up: tsnet: route ip+net: netlinkrib: permission denied
//
// tailscale ships a fallback for exactly this (feature/androidbin): it reports
// one synthetic interface whose addresses are found by asking the kernel to
// route an outbound UDP socket. Same package also fixes DNS (no
// /etc/resolv.conf) and points Go's CA loader at Android's system store.
//
// It is deliberately NOT linked into tsnet by default; an app opts in with this
// blank import.
import (
	_ "tailscale.com/feature/androidbin"
)
