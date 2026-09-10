package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"testing"

	"cdr.dev/slog/v3"
	"github.com/coder/coder/v2/codersdk/drpcsdk"
	"github.com/coder/coder/v2/tailnet"
	"github.com/coder/coder/v2/tailnet/proto"
	"github.com/coder/websocket"
	"github.com/hashicorp/yamux"
	"golang.org/x/sync/errgroup"
	"storj.io/drpc/drpcmux"
	"storj.io/drpc/drpcserver"
)

type nativeDERPProxy struct {
	proto.DRPCTailnetUnimplementedServer
	upstream proto.DRPCTailnetClient
	update   <-chan struct{}
}

func newNativeDERPProxy(t *testing.T, target *url.URL, update <-chan struct{}) *httptest.Server {
	t.Helper()
	reverse := httputil.NewSingleHostReverseProxy(target)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/coordinate") {
			reverse.ServeHTTP(w, r)
			return
		}
		upstreamURL := *target
		upstreamURL.Path, upstreamURL.RawQuery = r.URL.Path, r.URL.RawQuery
		headers := http.Header{}
		headers.Set("Coder-Session-Token", r.Header.Get("Coder-Session-Token"))
		headers.Set("Cookie", r.Header.Get("Cookie"))
		ws, response, err := websocket.Dial(r.Context(), upstreamURL.String(), &websocket.DialOptions{HTTPHeader: headers})
		if err != nil {
			if response != nil {
				defer response.Body.Close()
			}
			http.Error(w, "native coordinator dial failed", http.StatusBadGateway)
			return
		}
		defer ws.CloseNow()
		upstream, err := tailnet.NewDRPCClient(websocket.NetConn(r.Context(), ws, websocket.MessageBinary), slog.Make())
		if err != nil {
			http.Error(w, "native DRPC client failed", http.StatusBadGateway)
			return
		}
		defer upstream.DRPCConn().Close()
		downstream, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer downstream.CloseNow()
		config := yamux.DefaultConfig()
		config.LogOutput = io.Discard
		multiplexed, err := yamux.Server(websocket.NetConn(r.Context(), downstream, websocket.MessageBinary), config)
		if err != nil {
			return
		}
		defer multiplexed.Close()
		mux := drpcmux.New()
		if err := proto.DRPCRegisterTailnet(mux, &nativeDERPProxy{upstream: upstream, update: update}); err != nil {
			t.Errorf("register native DERP proxy: %v", err)
			return
		}
		service := drpcserver.NewWithOptions(mux, drpcserver.Options{Manager: drpcsdk.DefaultDRPCOptions(nil)})
		if err := service.Serve(r.Context(), multiplexed); err != nil && r.Context().Err() == nil {
			t.Logf("native DERP proxy connection finished (%T)", err)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func (p *nativeDERPProxy) Coordinate(stream proto.DRPCTailnet_CoordinateStream) error {
	ctx, cancel := context.WithCancel(stream.Context())
	defer cancel()
	upstream, err := p.upstream.Coordinate(ctx)
	if err != nil {
		return err
	}
	defer upstream.Close()
	group, _ := errgroup.WithContext(ctx)
	group.Go(func() error {
		defer cancel()
		for {
			message, err := stream.Recv()
			if err != nil {
				return err
			}
			if err := upstream.Send(message); err != nil {
				return err
			}
		}
	})
	group.Go(func() error {
		defer cancel()
		for {
			message, err := upstream.Recv()
			if err != nil {
				return err
			}
			if err := stream.Send(message); err != nil {
				return err
			}
		}
	})
	return group.Wait()
}

func (p *nativeDERPProxy) StreamDERPMaps(request *proto.StreamDERPMapsRequest, stream proto.DRPCTailnet_StreamDERPMapsStream) error {
	upstream, err := p.upstream.StreamDERPMaps(stream.Context(), request)
	if err != nil {
		return err
	}
	defer upstream.Close()
	initial, err := upstream.Recv()
	if err != nil {
		return err
	}
	if err := stream.Send(initial); err != nil {
		return err
	}
	select {
	case <-stream.Context().Done():
		return stream.Context().Err()
	case <-p.update:
	}
	if len(initial.Regions) == 0 {
		return fmt.Errorf("native DERP map has no regions")
	}
	initial.Regions[12345] = &proto.DERPMap_Region{
		RegionId: 12345, RegionCode: "g12-added", RegionName: "Native acceptance added region",
	}
	if err := stream.Send(initial); err != nil {
		return err
	}
	<-stream.Context().Done()
	return stream.Context().Err()
}

func (p *nativeDERPProxy) RefreshResumeToken(ctx context.Context, request *proto.RefreshResumeTokenRequest) (*proto.RefreshResumeTokenResponse, error) {
	return p.upstream.RefreshResumeToken(ctx, request)
}

func (p *nativeDERPProxy) PostTelemetry(ctx context.Context, request *proto.TelemetryRequest) (*proto.TelemetryResponse, error) {
	return p.upstream.PostTelemetry(ctx, request)
}
