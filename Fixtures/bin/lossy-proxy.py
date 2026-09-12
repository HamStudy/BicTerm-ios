#!/usr/bin/env python3
"""lossy-proxy.py — userspace lossy/latent TCP proxy for terminal
sync-integrity characterization (herdr-support T12).

A pure-userspace, repo-local impairment proxy: NO pf/dummynet/ system
network configuration is touched. Listens on a loopback port and forwards
to a loopback target (default: the fixture sshd on 127.0.0.1:12222),
applying per-chunk impairments to the byte stream in BOTH directions:

  drop=<n>pct   drop ~n% of read chunks (TCP retransmits -> stalls;
                sustained loss eventually kills slow consumers)
  delay=<n>ms   add ~n ms latency per forwarded chunk
  dupe=<n>pct   duplicate ~n% of forwarded chunks (before delay)

Because the proxy sits ABOVE TCP, "drops" never corrupt the byte stream
in-band (TCP retransmits); they stall it. The abrupt `kill` control
closes all active connections so the SSH layer sees a real connection
death — the drop -> auto-reconnect -> fresh-shell scenario.

Runtime control: pass --control PATH; the file is tailed (line-offset
based, so commands append safely) and polled every 100 ms. Commands:

  drop=0pct|delay=0ms|dupe=0pct   change a knob immediately
  kill                            abort every active connection now
  reset                           restore the startup knobs

Every applied impairment and control command is logged to --log with a
timestamp, so test evidence shows exactly what the path suffered.

stdlib only; loopback only.
"""
import argparse
import os
import random
import socket
import struct
import sys
import threading
import time

POLL_INTERVAL = 0.1
CHUNK = 65536


def parse_pct(value):
    if not value.endswith("pct"):
        raise ValueError(f"expected Npct, got {value!r}")
    pct = float(value[:-3])
    if not 0 <= pct <= 100:
        raise ValueError(f"percentage out of range: {value!r}")
    return pct


def parse_ms(value):
    if not value.endswith("ms"):
        raise ValueError(f"expected Nms, got {value!r}")
    ms = float(value[:-2])
    if ms < 0:
        raise ValueError(f"negative delay: {value!r}")
    return ms


class Knobs:
    """Impairment knobs guarded by a lock; percentages are per-chunk."""

    def __init__(self, drop_pct, delay_ms, dupe_pct):
        self.lock = threading.Lock()
        self.start = (drop_pct, delay_ms, dupe_pct)
        self.drop_pct = drop_pct
        self.delay_ms = delay_ms
        self.dupe_pct = dupe_pct

    def reset(self):
        with self.lock:
            (self.drop_pct, self.delay_ms, self.dupe_pct) = self.start

    def snapshot(self):
        with self.lock:
            return (self.drop_pct, self.delay_ms, self.dupe_pct)


class ConnectionRegistry:
    """Tracks active proxied connections so `kill` can abort them all."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sockets = []

    def add(self, pair):
        with self.lock:
            self.sockets.append(pair)

    def discard(self, pair):
        with self.lock:
            try:
                self.sockets.remove(pair)
            except ValueError:
                pass

    def kill_all(self):
        with self.lock:
            pairs = list(self.sockets)
        for a, b in pairs:
            for sock in (a, b):
                try:
                    # SO_LINGER(1,0): abrupt RST death, not a clean-FIN race.
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                    struct.pack("ii", 1, 0))
                except OSError:
                    pass
                try:
                    sock.close()
                except OSError:
                    pass
        return len(pairs)


def log_line(path, message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".%03dZ" % (
        int(time.time() * 1000) % 1000)
    line = f"{stamp} {message}\n"
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line)
    else:
        sys.stderr.write(line)
        sys.stderr.flush()


def relay(src, dst, knobs, registry_pair, direction, log):
    while True:
        try:
            data = src.recv(CHUNK)
        except OSError:
            break
        if not data:
            break
        drop_pct, delay_ms, dupe_pct = knobs.snapshot()
        if drop_pct > 0 and random.random() * 100 < drop_pct:
            log(f"{direction}: dropped {len(data)}B chunk")
            continue
        try:
            if dupe_pct > 0 and random.random() * 100 < dupe_pct:
                dst.sendall(data)
                log(f"{direction}: duplicated {len(data)}B chunk")
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)
            dst.sendall(data)
        except OSError:
            break
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle_connection(client, target_addr, knobs, registry, log):
    try:
        target = socket.create_connection(target_addr, timeout=10)
    except OSError as error:
        log(f"upstream connect to {target_addr[0]}:{target_addr[1]} failed: {error}")
        try:
            client.close()
        except OSError:
            pass
        return
    client.settimeout(None)
    target.settimeout(None)
    pair = (client, target)
    registry.add(pair)
    threads = [
        threading.Thread(target=relay, args=(client, target, knobs, pair, "c->s", log),
                         daemon=True),
        threading.Thread(target=relay, args=(target, client, knobs, pair, "s->c", log),
                         daemon=True),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    registry.discard(pair)
    for sock in pair:
        try:
            sock.close()
        except OSError:
            pass
    log("connection closed")


def tail_control(path, knobs, registry, log):
    """Byte-offset tail of the control file; acts on each NEW complete
    line exactly once. An unterminated trailing fragment is held back
    until its newline arrives (writers may not write atomically)."""
    offset = 0
    pending = b""
    while True:
        time.sleep(POLL_INTERVAL)
        try:
            if os.path.getsize(path) < offset:
                offset = 0  # file was rewritten/truncated — restart
                pending = b""
            with open(path, "rb") as handle:
                handle.seek(offset)
                data = handle.read()
                offset = handle.tell()
        except OSError:
            continue
        if not data:
            continue
        pending += data
        *complete, pending = pending.split(b"\n")
        for raw in complete:
            command = raw.decode("utf-8", "replace").strip()
            if not command:
                continue
            try:
                if command == "kill":
                    count = registry.kill_all()
                    log(f"control: kill -> aborted {count} connection(s)")
                elif command == "reset":
                    knobs.reset()
                    drop, delay, dupe = knobs.snapshot()
                    log(f"control: reset -> drop={drop}pct delay={delay}ms dupe={dupe}pct")
                elif command.startswith("drop="):
                    knobs.drop_pct = parse_pct(command[5:])
                    log(f"control: drop={knobs.drop_pct}pct")
                elif command.startswith("delay="):
                    knobs.delay_ms = parse_ms(command[6:])
                    log(f"control: delay={knobs.delay_ms}ms")
                elif command.startswith("dupe="):
                    knobs.dupe_pct = parse_pct(command[5:])
                    log(f"control: dupe={knobs.dupe_pct}pct")
                else:
                    log(f"control: UNKNOWN command {command!r}")
            except ValueError as error:
                log(f"control: BAD command {command!r}: {error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=int, required=True)
    parser.add_argument("--target", default="127.0.0.1:12222")
    parser.add_argument("--drop", default="0pct")
    parser.add_argument("--delay", default="0ms")
    parser.add_argument("--dupe", default="0pct")
    parser.add_argument("--control")
    parser.add_argument("--log")
    args = parser.parse_args()

    host, sep, port = args.target.rpartition(":")
    if not sep or not host:
        raise SystemExit(f"lossy-proxy: --target must be HOST:PORT, got {args.target!r}")
    target_port = int(port)
    try:
        drop_pct = parse_pct(args.drop)
        delay_ms = parse_ms(args.delay)
        dupe_pct = parse_pct(args.dupe)
    except ValueError as error:
        raise SystemExit(f"lossy-proxy: {error}")

    knobs = Knobs(drop_pct, delay_ms, dupe_pct)
    registry = ConnectionRegistry()

    def log(message):
        log_line(args.log, message)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("127.0.0.1", args.listen))
    except OSError as error:
        raise SystemExit(f"lossy-proxy: cannot bind 127.0.0.1:{args.listen}: {error}")
    server.listen(16)
    log(f"listening on 127.0.0.1:{args.listen} -> {host}:{target_port} "
        f"drop={drop_pct}pct delay={delay_ms}ms dupe={dupe_pct}pct")

    if args.control:
        open(args.control, "a", encoding="utf-8").close()  # ensure it exists
        threading.Thread(target=tail_control,
                         args=(args.control, knobs, registry, log), daemon=True).start()

    while True:
        try:
            client, peer = server.accept()
        except OSError:
            break
        log(f"accepted connection from {peer[0]}:{peer[1]}")
        threading.Thread(target=handle_connection,
                         args=(client, (host, target_port), knobs, registry, log),
                         daemon=True).start()


if __name__ == "__main__":
    main()
