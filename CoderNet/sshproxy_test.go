package main

// RED (T9): the bridge's SSH translation layer — downstream presents an
// ephemeral ed25519 host key and none-auth (the only intersection with
// NIOSSH's algorithm set); upstream dials the agent over the tailnet with
// its hardcoded RSA host key (coder upstream constant, agentssh.go) under
// none-auth. All channel requests relay opaquely so pty/shell/window-change
// semantics survive untouched.

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/binary"
	"io"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	gossh "golang.org/x/crypto/ssh"
)

// fakeAgent is an in-process stand-in for the agent's SSH server: RSA host
// key (upstream constant), none-auth accepted, pty/shell granted with a
// greeting, input echoed, window changes recorded.
type fakeAgent struct {
	signer gossh.Signer
	config *gossh.ServerConfig

	mu            sync.Mutex
	windowChanges [][2]int
	ptyTerms      []string
}

func newFakeAgent(t *testing.T) *fakeAgent {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := gossh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	config := &gossh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(signer)
	return &fakeAgent{signer: signer, config: config}
}

func (a *fakeAgent) windowChangeCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.windowChanges)
}

func (a *fakeAgent) lastWindow() (int, int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	last := a.windowChanges[len(a.windowChanges)-1]
	return last[0], last[1]
}

// serveOne accepts exactly one SSH connection over conn.
func (a *fakeAgent) serveOne(t *testing.T, conn net.Conn) {
	serverConn, newChannels, requests, err := gossh.NewServerConn(conn, a.config)
	if err != nil {
		t.Errorf("fake agent handshake: %v", err)
		return
	}
	t.Logf("fake agent peer version: %s", serverConn.ClientVersion())
	go gossh.DiscardRequests(requests)

	for newChannel := range newChannels {
		if newChannel.ChannelType() != "session" {
			_ = newChannel.Reject(gossh.UnknownChannelType, "only session")
			continue
		}
		channel, channelRequests, err := newChannel.Accept()
		if err != nil {
			t.Errorf("fake agent accept channel: %v", err)
			return
		}
		go a.serveSession(t, channel, channelRequests)
	}
}

func (a *fakeAgent) serveSession(t *testing.T, channel gossh.Channel, requests <-chan *gossh.Request) {
	for req := range requests {
		switch req.Type {
		case "pty-req":
			termLen := binary.BigEndian.Uint32(req.Payload[0:4])
			term := string(req.Payload[4 : 4+termLen])
			a.mu.Lock()
			a.ptyTerms = append(a.ptyTerms, term)
			a.mu.Unlock()
			if req.WantReply {
				_ = req.Reply(true, nil)
			}
		case "window-change":
			width := binary.BigEndian.Uint32(req.Payload[0:4])
			height := binary.BigEndian.Uint32(req.Payload[4:8])
			a.mu.Lock()
			a.windowChanges = append(a.windowChanges, [2]int{int(width), int(height)})
			a.mu.Unlock()
		case "shell":
			if req.WantReply {
				_ = req.Reply(true, nil)
			}
			_, _ = channel.Write([]byte("fake-agent ready\r\n"))
			go io.Copy(channel, channel)
		case "exit-command-test":
			_, _ = channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
			if req.WantReply {
				_ = req.Reply(true, nil)
			}
		default:
			if req.WantReply {
				_ = req.Reply(false, nil)
			}
		}
	}
}

// dialPipe returns an upstream stream backed by the in-process fake agent.
// A buffered pair is mandatory — net.Pipe is synchronous, and the x/crypto
// handshake writes before it reads, so a bare pipe deadlocks both sides in
// exchangeVersions.
func (a *fakeAgent) dialPipe(t *testing.T) net.Conn {
	t.Helper()
	clientHalf, agentHalf := bufferedPipe()
	go a.serveOne(t, agentHalf)
	return clientHalf
}

func bufferedPipe() (net.Conn, net.Conn) {
	a1, a2 := net.Pipe()
	b1, b2 := net.Pipe()
	go func() { _, _ = io.Copy(b1, a2); _ = a2.Close(); _ = b1.Close() }()
	go func() { _, _ = io.Copy(a2, b1); _ = b1.Close(); _ = a2.Close() }()
	return a1, b2
}

func TestSSHProxyEndToEnd(t *testing.T) {
	dir := shortSessionDir(t)
	agent := newFakeAgent(t)

	bridge, err := bindProxyUDS(dir, func(_ context.Context) (net.Conn, error) {
		return agent.dialPipe(t), nil
	})
	if err != nil {
		t.Fatalf("bindProxyUDS: %v", err)
	}
	defer bridge.close()

	base := filepath.Base(bridge.socketPath)
	if !strings.HasPrefix(base, "coder-ssh-") {
		t.Fatalf("proxy socket must keep the coder-ssh naming contract, got %q", base)
	}

	socket, err := net.DialTimeout("unix", bridge.socketPath, 5*time.Second)
	if err != nil {
		t.Fatalf("dial proxy socket: %v", err)
	}
	defer socket.Close()

	// The downstream handshake is locked to ed25519 host keys: an RSA answer
	// here would be the negotiation failure NIOSSH hits on the raw agent.
	clientConfig := &gossh.ClientConfig{
		User:              "coder",
		HostKeyCallback:   gossh.InsecureIgnoreHostKey(),
		HostKeyAlgorithms: []string{"ssh-ed25519"},
	}
	clientConn, newChannels, requests, err := gossh.NewClientConn(socket, bridge.socketPath, clientConfig)
	if err != nil {
		t.Fatalf("downstream ed25519 handshake: %v", err)
	}
	defer clientConn.Close()
	go gossh.DiscardRequests(requests)
	go func() {
		for ch := range newChannels {
			_ = ch.Reject(gossh.UnknownChannelType, "client opens none")
		}
	}()
	client := gossh.NewClient(clientConn, newChannels, requests)

	session, err := client.NewSession()
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	defer session.Close()

	if err := session.RequestPty("xterm-256color", 24, 80, gossh.TerminalModes{}); err != nil {
		t.Fatalf("pty-req: %v", err)
	}
	stdin, err := session.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := session.Shell(); err != nil {
		t.Fatalf("shell: %v", err)
	}

	readExpect(t, stdout, "fake-agent ready")

	if _, err := stdin.Write([]byte("proxy-roundtrip\n")); err != nil {
		t.Fatal(err)
	}
	readExpect(t, stdout, "proxy-roundtrip")

	if err := session.WindowChange(40, 120); err != nil {
		t.Fatalf("window-change send: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && agent.windowChangeCount() == 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if agent.windowChangeCount() == 0 {
		t.Fatal("window-change never reached the upstream agent")
	}
	if w, h := agent.lastWindow(); w != 120 || h != 40 {
		t.Fatalf("window-change relayed as (%d,%d), want (120,40)", w, h)
	}
}

func readExpect(t *testing.T, reader io.Reader, expect string) {
	t.Helper()
	type result struct {
		text string
		err  error
	}
	out := make(chan result, 1)
	go func() {
		var collected strings.Builder
		buf := make([]byte, 256)
		for !strings.Contains(collected.String(), expect) {
			n, err := reader.Read(buf)
			if n > 0 {
				collected.Write(buf[:n])
			}
			if err != nil {
				out <- result{collected.String(), err}
				return
			}
		}
		out <- result{collected.String(), nil}
	}()
	select {
	case got := <-out:
		if got.err != nil {
			t.Fatalf("read: %v (collected %q)", got.err, got.text)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("never saw %q within 5s", expect)
	}
}
