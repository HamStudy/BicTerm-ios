package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	gossh "golang.org/x/crypto/ssh"
)

func TestSSHProxyDrainsOutputAndStatusAfterStdinEOF(t *testing.T) {
	// Given an SSH server that produces output only after receiving stdin EOF.
	agent := newFakeAgent(t)
	serverResult := make(chan error, 1)
	bridge, err := bindProxyUDS(shortSessionDir(t), func(context.Context) (net.Conn, error) {
		client, server := bufferedPipe()
		go func() { serverResult <- serveEOFCommand(server, agent.config) }()
		return client, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bridge.close)
	conn, err := net.DialTimeout("unix", bridge.socketPath, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	sshConn, channels, requests, err := gossh.NewClientConn(conn, "fixture", &gossh.ClientConfig{
		User: "coder", HostKeyCallback: gossh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		t.Fatal(err)
	}
	client := gossh.NewClient(sshConn, channels, requests)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	input := []byte{0, 1, 10, 13, 127, 128, 255}
	session.Stdin = bytes.NewReader(input)
	var stdout, stderr bytes.Buffer
	session.Stdout, session.Stderr = &stdout, &stderr

	// When the command's input is half-closed.
	err = session.Run("drain")

	// Then stdout, stderr and the remote status survive independently.
	var exit *gossh.ExitError
	if !errors.As(err, &exit) || exit.ExitStatus() != 37 {
		t.Errorf("exit = %v; want remote status 37", err)
	}
	if want := append(input, []byte("trailing-output")...); !bytes.Equal(stdout.Bytes(), want) {
		t.Errorf("stdout = %x; want %x", stdout.Bytes(), want)
	}
	if stderr.String() != "stderr-after-eof" {
		t.Errorf("stderr = %q; want stderr-after-eof", stderr.String())
	}
	select {
	case err := <-serverResult:
		if err != nil {
			t.Error(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("upstream fixture did not terminate")
	}
}

func serveEOFCommand(raw net.Conn, config *gossh.ServerConfig) error {
	defer raw.Close()
	conn, channels, requests, err := gossh.NewServerConn(raw, config)
	if err != nil {
		return err
	}
	defer conn.Close()
	go gossh.DiscardRequests(requests)
	opening, ok := <-channels
	if !ok {
		return fmt.Errorf("upstream closed before opening a session")
	}
	channel, requests, err := opening.Accept()
	if err != nil {
		return err
	}
	defer channel.Close()
	request, ok := <-requests
	if !ok || request.Type != "exec" {
		return fmt.Errorf("missing exec request")
	}
	if err := request.Reply(true, nil); err != nil {
		return err
	}
	input, err := io.ReadAll(channel)
	if err != nil {
		return err
	}
	if _, err := channel.Write(append(input, []byte("trailing-output")...)); err != nil {
		return err
	}
	if _, err := io.WriteString(channel.Stderr(), "stderr-after-eof"); err != nil {
		return err
	}
	_, err = channel.SendRequest("exit-status", false, gossh.Marshal(struct{ Status uint32 }{37}))
	return err
}
