// Command CoderNet is a c-archive bridge exposing the Coder workspace-SSH
// transport core to BicTerm over a minimal C ABI. T9 wires the real network
// path: per session the bridge runs workspacesdk DialAgent → agent SSH
// stream → per-session unix listener (udsbridge.go) and hands the socket
// path to the NIOSSH client.
//
// All diagnostics flow through the registered log callback — the Go bridge
// never writes to stdout/stderr, and never mirrors the session token or
// stream payload into any log line.
package main

/*
#include <stdlib.h>

typedef void (*CoderNetLogCallback)(int level, const char *message);

static inline void codernet_emit(CoderNetLogCallback cb, int level, const char *message) {
	if (cb != NULL) {
		cb(level, message);
	}
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"net"
	"net/url"
	"sync"
	"time"
	"unsafe"

	"cdr.dev/slog/v3"
	"github.com/google/uuid"

	"github.com/coder/coder/v2/codersdk"
	"github.com/coder/coder/v2/codersdk/workspacesdk"
	"github.com/coder/coder/v2/tailnet"
)

// Log levels mirrored to Swift.
const (
	logDebug C.int = 0
	logInfo  C.int = 1
	logWarn  C.int = 2
	logError C.int = 3
)

// dialTimeout bounds one tailnet establishment; the client promises a fresh
// attempt rather than a retry inside the bridge.
const dialTimeout = 90 * time.Second

// session holds one Coder connection's live state. conn (the authenticated
// tailnet coordination) is established on first dial and survives re-dials;
// only the SSH stream and its unix listener are replaced. All mutable fields
// are guarded by mu.
type session struct {
	client    *codersdk.Client
	agentID   string
	relayOnly bool
	socketDir string

	mu     sync.Mutex
	conn   workspacesdk.AgentConn
	bridge *sessionUDS
}

var (
	mu          sync.Mutex
	sessions          = map[C.int]*session{}
	handleNext  C.int = 1
	logCallback C.CoderNetLogCallback
)

func emit(level C.int, msg string) {
	mu.Lock()
	cb := logCallback
	mu.Unlock()
	cmsg := C.CString(msg)
	C.codernet_emit(cb, level, cmsg)
	C.free(unsafe.Pointer(cmsg))
}

// emitSink forwards the coder SDK/tailnet log stream to the Swift-side
// callback, keeping every diagnostic on the one sanctioned channel.
type emitSink struct{}

func (emitSink) LogEntry(_ context.Context, entry slog.SinkEntry) {
	level := logDebug
	switch entry.Level {
	case slog.LevelInfo:
		level = logInfo
	case slog.LevelWarn:
		level = logWarn
	case slog.LevelError, slog.LevelCritical, slog.LevelFatal:
		level = logError
	}
	emit(level, entry.Message)
}

func (emitSink) Sync() {}

var bridgeLogger = slog.Make(emitSink{})

//export CoderNetSetLogCallback
func CoderNetSetLogCallback(cb C.CoderNetLogCallback) {
	mu.Lock()
	logCallback = cb
	mu.Unlock()
}

//export CoderNetVersion
func CoderNetVersion() *C.char {
	return C.CString("CoderNet-BicTerm/0.2")
}

//export CoderNetFreeString
func CoderNetFreeString(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// startConfig is the boundary-parsed configuration for CoderNetStart.
type startConfig struct {
	ServerURL    string `json:"server_url"`
	SessionToken string `json:"session_token"`
	AgentID      string `json:"agent_id"`
	RelayOnly    bool   `json:"relay_only"`
	// SocketDir overrides the unix-socket base directory (Darwin sun_path is
	// 104 bytes — callers pass a short, app-controlled directory). Empty
	// falls back to os.TempDir, which is unsuitable under long container
	// prefixes. NOTE: Go snapshots the process environment at startup, so an
	// environment variable would be opaque to a host app setting it at
	// runtime; an explicit config field is the honest seam.
	SocketDir string `json:"socket_dir"`
}

//export CoderNetStart
func CoderNetStart(cfgJSON *C.char) C.int {
	if cfgJSON == nil {
		emit(logError, "start: nil config")
		return 0
	}
	var cfg startConfig
	if err := json.Unmarshal([]byte(C.GoString(cfgJSON)), &cfg); err != nil {
		emit(logError, "start: invalid config JSON: "+err.Error())
		return 0
	}
	serverURL, err := url.Parse(cfg.ServerURL)
	if err != nil || serverURL.Scheme == "" || cfg.SessionToken == "" {
		emit(logError, "start: config requires server_url and session_token")
		return 0
	}
	if _, err := uuid.Parse(cfg.AgentID); err != nil {
		emit(logError, "start: agent_id is not a UUID")
		return 0
	}
	mu.Lock()
	h := handleNext
	handleNext++
	sessions[h] = &session{
		client:    codersdk.New(serverURL, codersdk.WithSessionToken(cfg.SessionToken)),
		agentID:   cfg.AgentID,
		relayOnly: cfg.RelayOnly,
		socketDir: cfg.SocketDir,
	}
	mu.Unlock()
	emit(logInfo, "start: session created")
	return h
}

//export CoderNetDialSSH
func CoderNetDialSSH(handle C.int) *C.char {
	mu.Lock()
	s, ok := sessions[handle]
	mu.Unlock()
	if !ok {
		emit(logError, "dial: unknown handle")
		return nil
	}

	agentUUID, err := uuid.Parse(s.agentID)
	if err != nil {
		emit(logError, "dial: stored agent_id is not a UUID")
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
	defer cancel()

	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()

	if conn == nil {
		fresh, err := workspacesdk.New(s.client).DialAgent(ctx, agentUUID, &workspacesdk.DialAgentOptions{
			Logger:         bridgeLogger,
			BlockEndpoints: s.relayOnly,
		})
		if err != nil {
			emit(logError, "dial: tailnet establish failed: "+err.Error())
			return nil
		}
		conn = fresh
		s.mu.Lock()
		s.conn = conn
		s.mu.Unlock()
		emit(logInfo, "dial: tailnet coordination established agent_ipv6="+tailnet.TailscaleServicePrefix.AddrFromUUID(agentUUID).String())
	}

	s.mu.Lock()
	existing := s.bridge
	s.mu.Unlock()
	if existing != nil {
		return C.CString(existing.socketPath)
	}

	dir := s.socketDir
	if dir == "" {
		dir = socketBaseDir()
	}
	agentConn := conn
	bridge, err := bindProxyUDS(dir, func(streamCtx context.Context) (net.Conn, error) {
		return agentConn.SSH(streamCtx)
	})
	if err != nil {
		emit(logError, "dial: socket bridge failed: "+err.Error())
		return nil
	}

	s.mu.Lock()
	s.bridge = bridge
	s.mu.Unlock()

	emit(logInfo, "dial: ssh proxy bound "+bridge.socketPath)
	return C.CString(bridge.socketPath)
}

//export CoderNetRebind
func CoderNetRebind(handle C.int) {
	mu.Lock()
	s, ok := sessions[handle]
	mu.Unlock()
	if !ok {
		return
	}
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	if conn == nil {
		return
	}
	conn.TailnetConn().Rebind()
	emit(logInfo, "rebind: network path re-anchored")
}

//export CoderNetClose
func CoderNetClose(handle C.int) {
	mu.Lock()
	s, ok := sessions[handle]
	delete(sessions, handle)
	mu.Unlock()
	if !ok {
		return
	}
	s.mu.Lock()
	bridge, conn := s.bridge, s.conn
	s.bridge = nil
	s.conn = nil
	s.mu.Unlock()
	if bridge != nil {
		bridge.close()
	}
	if conn != nil {
		_ = conn.Close()
	}
	emit(logInfo, "close: session torn down")
}

func main() {}
