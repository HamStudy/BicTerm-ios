#!/bin/bash
# Repo-local cache directories for Go, Rust, and SPM toolchains.
# Source this before ANY go/cargo/swift package command.
export GOMODCACHE="$PWD/.build-artifacts/go-mod"
export GOCACHE="$PWD/.build-artifacts/go-build"
export GOPATH="$PWD/.build-artifacts/gopath"
export GOTELEMETRY=off
export CARGO_HOME="$PWD/.build-artifacts/cargo"
export CARGO_TARGET_DIR="$PWD/.build-artifacts/cargo-target"
export TMPDIR="$PWD/.scratch/tmp"
mkdir -p "$GOMODCACHE" "$GOCACHE" "$GOPATH" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$TMPDIR"
