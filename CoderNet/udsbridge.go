package main

// Per-session unix-domain-socket endpoint (spec §11.1, Docs/SECURITY.md UDS
// contract): one bound listener per tunnel session, accepting connections
// that a per-connection handler serves. Ownership and invariants live here:
// per-session random path, stale sweep, 0600, unlink on close.

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/uuid"
)

// sessionUDS is one bound listener plus its accept loop state.
type sessionUDS struct {
	socketPath string
	listener   net.Listener

	mu       sync.Mutex
	closed   bool
	accepted []net.Conn
}

// socketBaseDir honors CODER_NET_SOCKET_DIR so hosts can place sockets under
// a short path (Darwin's sun_path cap is 104 bytes); default is os.TempDir.
func socketBaseDir() string {
	if dir := os.Getenv("CODER_NET_SOCKET_DIR"); dir != "" {
		return dir
	}
	return os.TempDir()
}

// bindUDSAtPath sweeps any stale crash leftover at path, binds, and forces
// 0600. bindUDSAtPath at a path with a LIVE listener fails type-safely
// (EADDRINUSE), since the sweep removes only filesystem state.
func bindUDSAtPath(path string) (net.Listener, error) {
	_ = os.Remove(path)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("bind %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("chmod %s: %w", path, err)
	}
	return listener, nil
}

// bindSessionUDS binds a fresh per-session socket path under dir. A fresh
// UUID per call keeps concurrent sessions on distinct sockets by
// construction.
func bindSessionUDS(dir string) (*sessionUDS, error) {
	path := filepath.Join(dir, "coder-ssh-"+uuid.NewString()+".sock")
	if len(path) >= 104 {
		return nil, fmt.Errorf("socket path too long for Darwin sun_path: %d bytes", len(path))
	}
	listener, err := bindUDSAtPath(path)
	if err != nil {
		return nil, err
	}
	return &sessionUDS{socketPath: path, listener: listener}, nil
}

// serveAccepting runs the accept loop: each accepted connection is handed
// to serveConn on its own goroutine. Accept failure after close() ends it.
func (socket *sessionUDS) serveAccepting(serveConn func(net.Conn)) {
	for {
		conn, err := socket.listener.Accept()
		if err != nil {
			return
		}
		socket.mu.Lock()
		if socket.closed {
			socket.mu.Unlock()
			_ = conn.Close()
			return
		}
		socket.accepted = append(socket.accepted, conn)
		socket.mu.Unlock()
		go serveConn(conn)
	}
}

// close finishes the listener and every accepted connection, then unlinks
// the socket path. Idempotent and safe before Accept returns.
func (socket *sessionUDS) close() {
	socket.mu.Lock()
	if socket.closed {
		socket.mu.Unlock()
		return
	}
	socket.closed = true
	listener, accepted := socket.listener, socket.accepted
	socket.accepted = nil
	socket.mu.Unlock()

	_ = listener.Close()
	for _, conn := range accepted {
		_ = conn.Close()
	}
	_ = os.Remove(socket.socketPath)
}
