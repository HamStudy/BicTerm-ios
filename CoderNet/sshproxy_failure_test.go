package main

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	gossh "golang.org/x/crypto/ssh"
)

func TestSSHProxyReturnsWhenDownstreamWriteFails(t *testing.T) {
	assertProxyStopsAfterOutputFailure(t, false)
}

func TestSSHProxyReturnsWhenConsumerSendsEndOfWrite(t *testing.T) {
	assertProxyStopsAfterOutputFailure(t, true)
}

func assertProxyStopsAfterOutputFailure(t *testing.T, endOfWrite bool) {
	t.Helper()
	// Given a live upstream shell and a downstream consumer that stops accepting output.
	agent := newFakeAgent(t)
	requests := make(chan *gossh.Request, 1)
	requests <- &gossh.Request{Type: "shell", WantReply: false}
	downstream := &failedOutputChannel{
		closed: make(chan struct{}), attempted: make(chan struct{}), requests: requests,
		failWrites: !endOfWrite,
	}
	proxy := sshProxy{dialUpstream: func(context.Context) (net.Conn, error) {
		return agent.dialPipe(t), nil
	}}
	finished := make(chan struct{})
	t.Cleanup(func() {
		downstream.Close()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("proxy relays leaked after cleanup")
		}
	})

	// When the downstream reports output failure while input stays open.
	go func() {
		proxy.serveSession(downstream, requests)
		close(finished)
	}()
	select {
	case <-downstream.attempted:
	case <-time.After(5 * time.Second):
		t.Fatal("upstream did not produce output")
	}
	if endOfWrite {
		requests <- &gossh.Request{Type: "eow@openssh.com", WantReply: false}
	}

	// Then all proxy relays terminate without waiting for downstream EOF.
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("consumer ended output but upstream and relays stayed alive")
	}
}

var errOutputConsumerClosed = errors.New("output consumer closed")

type failedOutputChannel struct {
	closed     chan struct{}
	attempted  chan struct{}
	requests   chan *gossh.Request
	closeOnce  sync.Once
	writeOnce  sync.Once
	failWrites bool
}

func (channel *failedOutputChannel) Read([]byte) (int, error) {
	<-channel.closed
	return 0, io.EOF
}

func (channel *failedOutputChannel) Write(data []byte) (int, error) {
	channel.writeOnce.Do(func() { close(channel.attempted) })
	if channel.failWrites {
		return 0, errOutputConsumerClosed
	}
	return len(data), nil
}

func (channel *failedOutputChannel) Close() error {
	channel.closeOnce.Do(func() {
		close(channel.closed)
		close(channel.requests)
	})
	return nil
}

func (*failedOutputChannel) CloseWrite() error { return nil }

func (*failedOutputChannel) SendRequest(string, bool, []byte) (bool, error) {
	return true, nil
}

func (channel *failedOutputChannel) Stderr() io.ReadWriter { return channel }
