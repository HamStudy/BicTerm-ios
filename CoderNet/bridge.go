// Command CoderNet is a c-archive bridge exposing the Coder workspace-SSH
// transport core to BicTerm over a minimal C ABI. T5 scope: prove the pinned
// coder/v2 v2.36.4 dependency graph (codersdk + workspacesdk, incl. the
// coder/tailscale, coder/wireguard-go, coder/gvisor forks) cross-compiles for
// ios/arm64. Networking (DialAgent) is T9; the start/dial entrypoints here
// are stubs that only parse/retain configuration.
//
// All diagnostics flow through the registered log callback — the Go bridge
// never writes to stdout/stderr.
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
	"encoding/json"
	"net/url"
	"sync"
	"unsafe"

	"github.com/coder/coder/v2/codersdk"
	"github.com/coder/coder/v2/codersdk/workspacesdk"
)

// Log levels mirrored to Swift.
const (
	logDebug C.int = 0
	logInfo  C.int = 1
	logWarn  C.int = 2
	logError C.int = 3
)

// session holds one Coder connection's parsed configuration. conn stays nil
// until T9 wires DialAgent; the field type is what forces the real tailnet /
// wireguard-go / gvisor fork graph into this spike's compile.
type session struct {
	client    *codersdk.Client
	agentID   string
	relayOnly bool
	conn      workspacesdk.AgentConn
}

var (
	mu          sync.Mutex
	sessions    = map[C.int]*session{}
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

//export CoderNetSetLogCallback
func CoderNetSetLogCallback(cb C.CoderNetLogCallback) {
	mu.Lock()
	logCallback = cb
	mu.Unlock()
}

//export CoderNetVersion
func CoderNetVersion() *C.char {
	return C.CString("CoderNet-BicTerm/0.1")
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
	mu.Lock()
	h := handleNext
	handleNext++
	sessions[h] = &session{
		client:    codersdk.New(serverURL, codersdk.WithSessionToken(cfg.SessionToken)),
		agentID:   cfg.AgentID,
		relayOnly: cfg.RelayOnly,
	}
	mu.Unlock()
	emit(logInfo, "start: session created")
	return h
}

//export CoderNetDialSSH
func CoderNetDialSSH(handle C.int) *C.char {
	mu.Lock()
	_, ok := sessions[handle]
	mu.Unlock()
	if !ok {
		emit(logError, "dial: unknown handle")
	}
	// T9 stub: the bridged SSH byte stream is not typed yet; callers receive
	// an empty string and must treat nil/empty as "no stream metadata".
	return C.CString("")
}

//export CoderNetClose
func CoderNetClose(handle C.int) {
	mu.Lock()
	delete(sessions, handle)
	mu.Unlock()
}

//export CoderNetRebind
func CoderNetRebind(handle C.int) {
	// T9 stub: rebind applies to a live tailnet.Conn; no-op until DialAgent.
}

func main() {}
