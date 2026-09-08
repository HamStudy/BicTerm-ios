package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/coder/coder/v2/tailnet"
)

// TestAgentServiceAddressSpecVector pins spec §9: the agent virtual IPv6
// address is its UUID with the first six bytes replaced by the
// fd7a:115c:a1e0::/48 service prefix — the address DialAgent targets.
func TestAgentServiceAddressSpecVector(t *testing.T) {
	id := uuid.MustParse("00112233-4455-6677-8899-aabbccddeeff")
	got := tailnet.TailscaleServicePrefix.AddrFromUUID(id).String()
	want := "fd7a:115c:a1e0:6677:8899:aabb:ccdd:eeff"
	if got != want {
		t.Fatalf("agent service address = %q, want %q", got, want)
	}
}

// TestSessionUDSListenerLifecycle pins the per-session UDS endpoint contract
// (Docs/SECURITY.md): per-session random coder-ssh-<uuid>.sock name, stale
// leftover swept before bind, 0600 permissions, accepted conn served through
// the handler hook, and the path removed on close.
func TestSessionUDSListenerLifecycle(t *testing.T) {
	dir := shortSessionDir(t)

	t.Run("stale path is swept then bound as a socket", func(t *testing.T) {
		path := filepath.Join(dir, "stale.sock")
		if err := os.WriteFile(path, []byte("stale-crash-leftover"), 0o644); err != nil {
			t.Fatal(err)
		}
		listener, err := bindUDSAtPath(path)
		if err != nil {
			t.Fatalf("bindUDSAtPath with stale file: %v", err)
		}
		defer func() {
			_ = listener.Close()
			_ = os.Remove(path)
		}()
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode()&os.ModeSocket == 0 {
			t.Fatalf("expected socket at %s, got mode %v", path, info.Mode())
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Fatalf("socket perms = %o, want 600", perm)
		}
	})

	t.Run("bound socket carries 0600 and per-session name", func(t *testing.T) {
		uds, err := bindSessionUDS(dir)
		if err != nil {
			t.Fatalf("bindSessionUDS: %v", err)
		}
		defer uds.close()

		base := filepath.Base(uds.socketPath)
		if !strings.HasPrefix(base, "coder-ssh-") || !strings.HasSuffix(base, ".sock") {
			t.Fatalf("socket name %q drifts from the coder-ssh-<uuid>.sock contract", base)
		}
		info, err := os.Stat(uds.socketPath)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Fatalf("socket perms = %o, want 600", perm)
		}
		if got := filepath.Dir(uds.socketPath); got != dir {
			t.Fatalf("socket dir = %q, want %q", got, dir)
		}
	})

	t.Run("concurrent sessions bind distinct sockets", func(t *testing.T) {
		first, err := bindSessionUDS(dir)
		if err != nil {
			t.Fatal(err)
		}
		defer first.close()
		second, err := bindSessionUDS(dir)
		if err != nil {
			t.Fatal(err)
		}
		defer second.close()
		if first.socketPath == second.socketPath {
			t.Fatalf("two sessions aliased one socket: %s", first.socketPath)
		}
	})

	t.Run("accepted conn is served through the hook", func(t *testing.T) {
		uds, err := bindSessionUDS(dir)
		if err != nil {
			t.Fatal(err)
		}
		defer uds.close()
		go uds.serveAccepting(func(conn net.Conn) {
			defer conn.Close()
			_, _ = io.Copy(conn, conn)
		})

		client, err := net.DialTimeout("unix", uds.socketPath, 5*time.Second)
		if err != nil {
			t.Fatalf("dial socket: %v", err)
		}
		defer client.Close()

		if _, err := client.Write([]byte("bicterm-ok")); err != nil {
			t.Fatalf("write: %v", err)
		}
		buf := make([]byte, 64)
		_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := client.Read(buf)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if got := string(buf[:n]); got != "bicterm-ok" {
			t.Fatalf("echo = %q, want %q", got, "bicterm-ok")
		}
	})

	t.Run("close removes the socket path", func(t *testing.T) {
		uds, err := bindSessionUDS(dir)
		if err != nil {
			t.Fatal(err)
		}
		path := uds.socketPath
		uds.close()
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("socket path survives close: %s (stat err %v)", path, err)
		}
	})
}

// shortSessionDir returns a temp directory whose full path stays well under
// Darwin's 104-byte sun_path cap — t.TempDir() nests too deeply for sockets.
// The root is the repo-local Fixtures/run tree, the same convention the
// Swift-side UDS fixtures use, so the suffix budget holds: 58 (dir) + 52
// (coder-ssh-<uuid>.sock) < 104.
func shortSessionDir(t *testing.T) string {
	t.Helper()
	base := filepath.Join("..", "Fixtures", "run", "gs")
	if err := os.MkdirAll(base, 0o700); err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(base, "d")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}
