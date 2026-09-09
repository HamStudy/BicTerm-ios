//go:build ignore

package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	target, err := url.Parse("http://127.0.0.1:7080")
	if err != nil {
		slog.Error("invalid fixture target")
		os.Exit(1)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ModifyResponse = func(response *http.Response) error {
		if response.Request.URL.Path == "/derp" {
			slog.Info("relay request", "upgrade", strings.ToLower(response.Request.Header.Get("Upgrade")), "status", response.StatusCode)
		}
		return nil
	}
	proxy.ErrorHandler = func(writer http.ResponseWriter, request *http.Request, err error) {
		slog.Error("fixture upstream failed")
		http.Error(writer, "upstream unavailable", http.StatusBadGateway)
	}
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if os.Getenv("CODER_GATE_REJECT_DERP") == "1" && strings.EqualFold(request.Header.Get("Upgrade"), "DERP") {
			slog.Info("relay request", "upgrade", "derp", "status", http.StatusForbidden)
			http.Error(writer, "custom upgrade rejected by fixture", http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(writer, request)
	})
	server := &http.Server{Addr: "127.0.0.1:7081", Handler: handler, ReadHeaderTimeout: 10 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		if err := server.Close(); err != nil {
			slog.Error("fixture shutdown failed")
		}
	}()
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("fixture listen failed")
		os.Exit(1)
	}
}
