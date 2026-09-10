#!/usr/bin/env python3
"""mock-bridge.py — deterministic herdr remote-client-bridge fixture.

T15 transport fixture: speaks herdr's OUTER framing contract (4-byte
little-endian length + payload, upstream src/protocol/wire.rs) over
stdin/stdout so the Swift exec transport can be exercised end-to-end
without a real herdr server. stdlib only; spawned per exec channel by the
fixture sshd via the `mock-herdr` shim.

Protocol (deterministic):
  1. argv: [--session NAME] remote-client-bridge (NAME validated against
     herdr's session-name grammar; anything else exits non-zero).
  2. One diagnostic line goes to STDERR (stderr isolation probe).
  3. Reads the client "hello" frame (payload ignored, envelope enforced).
  4. Sends the canned WELCOME frame, then the canned SNAPSHOT frame (both
     carry non-UTF-8 bytes and NULs to prove binary opacity).
  5. Echoes every subsequent frame back byte-identically.
  6. stdin EOF -> exit 0 (remote half-close semantics).
"""
import re
import sys

MAX_FRAME_BYTES = 16 * 1024 * 1024
SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

# Canned payloads: deliberately NOT valid UTF-8 anywhere it matters.
WELCOME_PAYLOAD = b"MOCK-WELCOME-v1\x00\x01\xff\x80\xfe" + bytes(range(1, 17))
SNAPSHOT_PAYLOAD = b"MOCK-SNAPSHOT-v1" + bytes(range(256)) * 4  # 1047 bytes


def die(code, message):
    sys.stderr.write("mock-bridge: %s\n" % message)
    sys.exit(code)


def parse_argv(argv):
    session = None
    rest = list(argv)
    if len(rest) >= 2 and rest[0] == "--session":
        session = rest[1]
        rest = rest[2:]
    if session is not None and not SESSION_NAME_RE.match(session):
        die(3, "invalid session name %r" % session)
    if rest != ["remote-client-bridge"]:
        die(2, "usage: mock-bridge.py [--session NAME] remote-client-bridge")
    return session


def read_exact(count):
    data = b""
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            return None if not data else data
        data += chunk
    return data


def read_frame():
    header = read_exact(4)
    if header is None:
        return None  # clean EOF before any header byte
    if len(header) < 4:
        die(4, "truncated frame header")
    length = int.from_bytes(header, "little")
    if length > MAX_FRAME_BYTES:
        die(5, "frame length %d exceeds cap" % length)
    if length == 0:
        return b""
    payload = read_exact(length)
    if payload is None or len(payload) < length:
        die(4, "truncated frame payload (want %d bytes)" % length)
    return payload


def write_frame(payload):
    sys.stdout.buffer.write(len(payload).to_bytes(4, "little"))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def main():
    session = parse_argv(sys.argv[1:])
    sys.stderr.write(
        "mock-bridge: ready session=%s\n" % (session if session is not None else "default")
    )
    sys.stderr.flush()

    hello = read_frame()
    if hello is None:
        die(4, "no hello frame")
    write_frame(WELCOME_PAYLOAD)
    write_frame(SNAPSHOT_PAYLOAD)

    while True:
        payload = read_frame()
        if payload is None:
            sys.exit(0)
        write_frame(payload)


if __name__ == "__main__":
    main()
