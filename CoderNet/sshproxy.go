package main

// SSH translation proxy (sshproxy.go): the NIOSSH client negotiates against
// an ephemeral ed25519 host key with none-auth (the only intersection with
// NIOSSH's algorithm set), while the upstream leg dials the workspace agent
// whose host key is hardcoded RSA (upstream constant, agentssh.go
// CoderSigner — no configuration can change it). Channel requests relay
// opaquely in both directions, so pty/shell/window-change/exit-status
// semantics pass through untouched.
//
// Trust posture: upstream uses InsecureIgnoreHostKey, matching the reference
// client (the authorized tailnet is the boundary, spec §10.5); downstream
// trust stays in the Swift HostKeyVerifier under .coderTunnelTrust.

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"net"
	"sync"

	gossh "golang.org/x/crypto/ssh"
)

// upstreamDialFunc supplies the raw byte stream toward the agent's SSH
// service (agent.SSH(ctx) in production).
type upstreamDialFunc func(ctx context.Context) (net.Conn, error)

// bindProxyUDS binds the per-session socket and starts serving proxied SSH.
func bindProxyUDS(dir string, dialUpstream upstreamDialFunc) (*sessionUDS, error) {
	socket, err := bindSessionUDS(dir)
	if err != nil {
		return nil, err
	}
	// Ephemeral per-session host key: presentation differs from the agent's
	// by design; the client's trust boundary never reads this key's identity.
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		socket.close()
		return nil, err
	}
	signer, err := gossh.NewSignerFromKey(private)
	if err != nil {
		socket.close()
		return nil, err
	}
	proxy := &sshProxy{hostSigner: signer, dialUpstream: dialUpstream}
	go socket.serveAccepting(proxy.serve)
	return socket, nil
}

type sshProxy struct {
	hostSigner   gossh.Signer
	dialUpstream upstreamDialFunc
}

func (proxy *sshProxy) newServerConfig() *gossh.ServerConfig {
	config := &gossh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(proxy.hostSigner)
	return config
}

// serve runs one downstream connection: server-side handshake, then session
// channels each riding their own upstream client connection.
func (proxy *sshProxy) serve(downstream net.Conn) {
	serverConn, newChannels, requests, err := gossh.NewServerConn(downstream, proxy.newServerConfig())
	if err != nil {
		emit(logWarn, "proxy: downstream handshake failed: "+err.Error())
		_ = downstream.Close()
		return
	}
	go gossh.DiscardRequests(requests)

	var wg sync.WaitGroup
	for newChannel := range newChannels {
		if newChannel.ChannelType() != "session" {
			_ = newChannel.Reject(gossh.UnknownChannelType, "only session channels")
			continue
		}
		channel, channelRequests, err := newChannel.Accept()
		if err != nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			proxy.serveSession(channel, channelRequests)
		}()
	}
	wg.Wait()
	_ = serverConn.Close()
	_ = downstream.Close()
}

// serveSession wires one downstream session channel to one upstream client
// session: open the upstream, then relay requests and data until either
// side ends.
func (proxy *sshProxy) serveSession(downstream gossh.Channel, downstreamRequests <-chan *gossh.Request) {
	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
	defer cancel()

	raw, err := proxy.dialUpstream(ctx)
	if err != nil {
		emit(logWarn, "proxy: upstream stream refused: "+err.Error())
		_ = downstream.Close()
		return
	}
	upstreamConn, newChannels, requests, err := gossh.NewClientConn(raw, "coder-agent", &gossh.ClientConfig{
		// nil Auth = RFC 4252 `none` only; the agent runs NoClientAuth.
		User:            "coder",
		HostKeyCallback: gossh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		emit(logWarn, "proxy: upstream handshake failed: "+err.Error())
		_ = raw.Close()
		_ = downstream.Close()
		return
	}
	go gossh.DiscardRequests(requests)
	go func() {
		for newChannel := range newChannels {
			_ = newChannel.Reject(gossh.UnknownChannelType, "proxy opens none")
		}
	}()
	upstream, upstreamRequests, err := upstreamConn.OpenChannel("session", nil)
	if err != nil {
		emit(logWarn, "proxy: upstream session channel refused: "+err.Error())
		_ = upstreamConn.Close()
		_ = downstream.Close()
		return
	}

	done := make(chan struct{}, 4)

	// Request relay: downstream -> upstream (replies flow back to the
	// downstream requester).
	go func() {
		for req := range downstreamRequests {
			ok, err := upstream.SendRequest(req.Type, req.WantReply, req.Payload)
			if req.WantReply {
				reply := err == nil && ok
				_ = req.Reply(reply, nil)
			}
		}
		_ = upstream.Close()
		done <- struct{}{}
	}()

	// Request relay: upstream -> downstream (exit-status and friends).
	go func() {
		for req := range upstreamRequests {
			ok, err := downstream.SendRequest(req.Type, req.WantReply, req.Payload)
			if req.WantReply {
				_ = req.Reply(err == nil && ok, nil)
			}
		}
		done <- struct{}{}
	}()

	go func() {
		_, _ = io.Copy(upstream, downstream)
		_ = upstream.CloseWrite()
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(downstream, upstream)
		_ = downstream.CloseWrite()
		done <- struct{}{}
	}()

	<-done
	_ = upstream.Close()
	_ = downstream.Close()
	_ = upstreamConn.Close()
	_ = raw.Close()
}
