package main

// Manual probe: dials the LIVE dev fixture through workspacesdk and reports
// each stage. Runs only when CODER_LIVE_PROBE=1 (normal test runs skip it).

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"net/url"

	"github.com/google/uuid"

	"github.com/coder/coder/v2/codersdk"
	"github.com/coder/coder/v2/codersdk/workspacesdk"
)

func TestLiveFixtureProbe(t *testing.T) {
	if os.Getenv("CODER_LIVE_PROBE") != "1" {
		t.Skip("set CODER_LIVE_PROBE=1 to run the live dial probe")
	}
	envBytes, err := os.ReadFile("../Fixtures/run/coder-dev.env")
	if err != nil {
		t.Fatal(err)
	}
	vals := map[string]string{}
	for _, line := range strings.Split(string(envBytes), "\n") {
		if i := strings.Index(line, "="); i > 0 {
			vals[line[:i]] = line[i+1:]
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	serverURL, err := url.Parse(vals["CODER_URL"])
	if err != nil {
		t.Fatal(err)
	}
	client := codersdk.New(serverURL, codersdk.WithSessionToken(vals["CODER_SESSION_TOKEN"]))

	ws, err := client.Workspaces(ctx, codersdk.WorkspaceFilter{Owner: codersdk.Me})
	if err != nil {
		t.Fatalf("REST list: %v", err)
	}
	var agentID uuid.UUID
	for _, w := range ws.Workspaces {
		if w.Name == "bicterm-host" {
			for _, r := range w.LatestBuild.Resources {
				for _, a := range r.Agents {
					agentID = a.ID
					t.Logf("workspace %s agent %s %s status %s", w.Name, a.Name, a.ID, a.Status)
				}
			}
		}
	}
	if agentID == uuid.Nil {
		t.Fatal("no agent found")
	}

	info, err := workspacesdk.New(client).AgentConnectionInfo(ctx, agentID)
	if err != nil {
		t.Fatalf("AgentConnectionInfo: %v", err)
	}
	t.Logf("conninfo: disableDirect=%v derpRegions=%d", info.DisableDirectConnections, len(info.DERPMap.Regions))

	conn, err := workspacesdk.New(client).DialAgent(ctx, agentID, &workspacesdk.DialAgentOptions{
		Logger: bridgeLogger,
	})
	if err != nil {
		t.Fatalf("DialAgent: %v", err)
	}
	t.Log("DialAgent OK")

	stream, err := conn.SSH(ctx)
	if err != nil {
		t.Fatalf("SSH: %v", err)
	}
	t.Log("SSH stream OK")
	fmt.Println("probe complete")
	_ = stream.Close()
	_ = conn.Close()
}
