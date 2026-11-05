package mobile

// Android denies app UIDs the NETLINK_ROUTE socket, so net.Interfaces() fails
// with "route ip+net: netlinkrib: permission denied" and tailscale's netmon
// cannot start.
//
// tailscale's own feature/androidbin package would fix this, but its register.go
// carries this build constraint:
//
//	//go:build (linux && !android) || (android && !cgo)
//
// with the comment "not registered in GOOS=android cgo builds (the Android app),
// which register a Java-backed interface getter of their own". gomobile always
// builds with cgo, so that package stays inert here.
//
// So we register the getter ourselves, reusing the same trick tailscale uses:
// dial a UDP socket (sends no packets) and let the kernel pick the source
// address, which is permitted inside the app sandbox.

import (
	"errors"
	"net"
	"net/netip"
	"runtime"
	"time"

	"tailscale.com/net/netmon"
)

func init() {
	if runtime.GOOS != "android" {
		return
	}
	netmon.RegisterInterfaceGetter(androidInterfaces)
}

// androidInterfaces reports one synthetic interface carrying the process's
// outbound IPv4/IPv6 source addresses.
func androidInterfaces() ([]netmon.Interface, error) {
	var addrs []net.Addr
	// The dial targets never receive packets: dialing UDP only makes the
	// kernel choose a route and a source address.
	if ip, ok := outboundIP("udp4", "8.8.8.8:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(32, 32)})
	}
	if ip, ok := outboundIP("udp6", "[2001:4860:4860::8888]:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(128, 128)})
	}
	if len(addrs) == 0 {
		return nil, errors.New("android: no outbound route found")
	}
	return []netmon.Interface{{
		Interface: &net.Interface{
			MTU:   1500,
			Name:  "android",
			Flags: net.FlagUp | net.FlagRunning,
		},
		AltAddrs: addrs,
	}}, nil
}

func outboundIP(network, addr string) (netip.Addr, bool) {
	d := net.Dialer{Timeout: 2 * time.Second}
	c, err := d.Dial(network, addr)
	if err != nil {
		return netip.Addr{}, false
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	ip, ok := netip.AddrFromSlice(ua.IP)
	if !ok {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsUnspecified() {
		return netip.Addr{}, false
	}
	return ip, true
}
