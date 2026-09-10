package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/coder/v2/codersdk"
	"github.com/coder/coder/v2/codersdk/workspacesdk"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	gossh "golang.org/x/crypto/ssh"
)

func TestNativeDERPMapUpdatePreservesSSHStream(t *testing.T) {
	// Given
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	env, err := os.ReadFile("../Fixtures/run/coder-dev.env")
	require.NoError(t, err)
	settings := make(map[string]string)
	for _, line := range strings.Split(string(env), "\n") {
		if key, value, ok := strings.Cut(line, "="); ok {
			settings[key] = value
		}
	}
	nativeURL, err := url.Parse(settings["CODER_URL"])
	require.NoError(t, err)
	require.Equal(t, "http://127.0.0.1:7080", nativeURL.String())
	update := make(chan struct{})
	proxy := newNativeDERPProxy(t, nativeURL, update)
	proxyURL, err := url.Parse(proxy.URL)
	require.NoError(t, err)
	client := codersdk.New(proxyURL, codersdk.WithSessionToken(settings["CODER_SESSION_TOKEN"]))
	workspaces, err := client.Workspaces(ctx, codersdk.WorkspaceFilter{Owner: codersdk.Me})
	require.NoError(t, err)
	var agentID uuid.UUID
	for _, workspace := range workspaces.Workspaces {
		if workspace.Name != "bicterm-host" {
			continue
		}
		for _, resource := range workspace.LatestBuild.Resources {
			for _, agent := range resource.Agents {
				agentID = agent.ID
			}
		}
	}
	require.NotEqual(t, uuid.Nil, agentID)
	conn, err := workspacesdk.New(client).DialAgent(ctx, agentID, &workspacesdk.DialAgentOptions{Logger: bridgeLogger})
	require.NoError(t, err)
	defer conn.Close()
	bridge, err := bindProxyUDS(shortSessionDir(t), func(ctx context.Context) (net.Conn, error) {
		return conn.SSH(ctx)
	})
	require.NoError(t, err)
	defer bridge.close()
	socket, err := (&net.Dialer{}).DialContext(ctx, "unix", bridge.socketPath)
	require.NoError(t, err)
	defer socket.Close()
	require.NoError(t, socket.SetDeadline(time.Now().Add(45*time.Second)))
	sshConn, channels, requests, err := gossh.NewClientConn(socket, "native-coder", &gossh.ClientConfig{
		User: "coder", HostKeyCallback: gossh.InsecureIgnoreHostKey(),
	})
	require.NoError(t, err)
	sshClient := gossh.NewClient(sshConn, channels, requests)
	defer sshClient.Close()
	session, err := sshClient.NewSession()
	require.NoError(t, err)
	defer session.Close()
	input, err := session.StdinPipe()
	require.NoError(t, err)
	output, err := session.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, session.Start("while IFS= read -r line; do printf '%s\\n' \"$line\"; done"))
	reader := bufio.NewReader(output)
	_, err = fmt.Fprintln(input, "before-map-update")
	require.NoError(t, err)
	line, err := reader.ReadString('\n')
	require.NoError(t, err)
	require.Equal(t, "before-map-update\n", line)
	require.NotContains(t, conn.TailnetConn().DERPMap().Regions, 12345)

	// When
	close(update)
	require.Eventually(t, func() bool {
		region := conn.TailnetConn().DERPMap().Regions[12345]
		return region != nil && region.RegionCode == "g12-added"
	}, 10*time.Second, 20*time.Millisecond)

	// Then
	for index := range 32 {
		expected := fmt.Sprintf("after-map-update-%02d", index)
		_, err := fmt.Fprintln(input, expected)
		require.NoError(t, err)
		line, err := reader.ReadString('\n')
		require.NoError(t, err)
		require.Equal(t, expected+"\n", line)
	}
	require.NoError(t, input.Close())
	require.NoError(t, session.Wait())
	t.Log("native DERP region update applied; original SSH channel preserved 32 ordered messages")
}
