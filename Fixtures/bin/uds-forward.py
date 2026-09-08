#!/usr/bin/env python3
"""uds-forward.py — bridge a unix-domain-socket listener to a loopback TCP target.

BicTerm fixture bridge (plan T8): makes the fixture sshd on 127.0.0.1:12222
reachable over a unix domain socket so SSHTransport's UDS dial path can be
conformance-tested from the simulator with key auth. stdlib only.

Ownership/lifecycle contract (mirrors the per-session Coder bridge contract):
  * Unless a LIVE listener already owns the socket path, a stale leftover
    (from a crashed/killed bridge) is unlinked before bind.
  * The bound socket carries mode 0600 from creation (umask, not chmod —
    no permissive window).
  * On SIGTERM/SIGINT/normal exit the socket path is unlinked; a crash is
    cleaned up by the NEXT run's stale-path sweep.
"""
import argparse
import os
import select
import signal
import socket
import sys
import threading

# sockaddr_un.sun_path holds 104 bytes (incl. NUL) on Darwin.
MAX_SUN_PATH_BYTES = 103


def parse_target(spec):
    host, sep, port = spec.rpartition(":")
    if not sep or not host:
        raise SystemExit(f"uds-forward: --target must be HOST:PORT, got {spec!r}")
    try:
        return host, int(port)
    except ValueError:
        raise SystemExit(f"uds-forward: --target port must be numeric, got {spec!r}")


def clear_stale_path(path):
    """Unlink a leftover socket path unless a live listener still owns it."""
    if not os.path.lexists(path):
        return
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(1.0)
        probe.connect(path)
    except OSError:
        # Nothing listening: stale file from a previous run — safe to replace.
        os.unlink(path)
        return
    finally:
        probe.close()
    raise SystemExit(f"uds-forward: {path} has a live listener; refusing to replace it")


def pump(client, target):
    """Full-duplex pipe UDS client <-> TCP target with half-close on EOF."""
    sockets = [client, target]
    try:
        while sockets:
            readable, _, _ = select.select(sockets, [], [])
            for sock in readable:
                other = target if sock is client else client
                data = sock.recv(65536)
                if data:
                    other.sendall(data)
                    continue
                sockets.remove(sock)
                try:
                    other.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
    except OSError:
        pass
    finally:
        for sock in (client, target):
            try:
                sock.close()
            except OSError:
                pass


def serve_one(client, target_address):
    try:
        target = socket.create_connection(target_address, timeout=5.0)
    except OSError:
        client.close()
        return
    pump(client, target)


def main():
    parser = argparse.ArgumentParser(description="Bridge a unix domain socket to a TCP target.")
    parser.add_argument("--socket", required=True, metavar="PATH", help="UDS path to bind")
    parser.add_argument("--target", required=True, metavar="HOST:PORT", help="TCP target to forward to")
    args = parser.parse_args()

    socket_path = os.path.abspath(args.socket)
    if len(socket_path.encode("utf-8")) > MAX_SUN_PATH_BYTES:
        raise SystemExit(f"uds-forward: socket path exceeds {MAX_SUN_PATH_BYTES} bytes: {socket_path}")
    target_address = parse_target(args.target)

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stopped = threading.Event()

    def handle_signal(_signum, _frame):
        stopped.set()
        # Closing from the handler wakes the accept loop with EBADF.
        try:
            listener.close()
        except OSError:
            pass

    try:
        clear_stale_path(socket_path)
        old_umask = os.umask(0o177)  # socket is created 0600 — no permissive window
        try:
            listener.bind(socket_path)
        finally:
            os.umask(old_umask)
        listener.listen(8)
    except SystemExit:
        listener.close()
        raise
    except OSError as error:
        listener.close()
        raise SystemExit(f"uds-forward: cannot bind {socket_path}: {error}")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    print(f"uds-forward: listening on {socket_path} -> {target_address[0]}:{target_address[1]}", flush=True)

    while not stopped.is_set():
        try:
            client, _ = listener.accept()
        except OSError:
            break  # closed by signal handler or shutdown
        threading.Thread(target=serve_one, args=(client, target_address), daemon=True).start()

    try:
        listener.close()
    except OSError:
        pass
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    print(f"uds-forward: removed {socket_path}", flush=True)


if __name__ == "__main__":
    main()
