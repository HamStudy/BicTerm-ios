#!/usr/bin/env python3
"""BicTerm fixture: OpenSSH agent-protocol client (TEST-ONLY).

Speaks the ssh-agent wire protocol on $SSH_AUTH_SOCK. Intended to run
INSIDE a fixture SSH session (hop-1/hop-2) to exercise BicTerm's forwarded
agent (T8/T14), including malformed/fragmented frame injection.

Usage:
  python3 agent_client.py list
  python3 agent_client.py sign <pubkey-file> <data>
  python3 agent_client.py sign-raw <hex-frame> [chunk-size]
  python3 agent_client.py flood <n> [pubkey-file]

Protocol framing: uint32 big-endian length + payload.
Opcodes: 11 REQUEST_IDENTITIES, 12 IDENTITIES_ANSWER, 13 SIGN_REQUEST,
         14 SIGN_RESPONSE, 5 FAILURE.
"""
import os
import socket
import struct
import sys

SSH_AGENT_FAILURE = 5
SSH_AGENTC_REQUEST_IDENTITIES = 11
SSH_AGENT_IDENTITIES_ANSWER = 12
SSH_AGENTC_SIGN_REQUEST = 13
SSH_AGENT_SIGN_RESPONSE = 14


def fail(msg, code=2):
    print("agent-client-error: %s" % msg, file=sys.stderr)
    sys.exit(code)


def sock_path():
    p = os.environ.get("SSH_AUTH_SOCK")
    if not p:
        fail("SSH_AUTH_SOCK not set", 1)
    return p


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path())
    return s


def u32(n):
    return struct.pack(">I", n)


def string(b):
    return u32(len(b)) + b


def get_u32(buf, off):
    return struct.unpack(">I", buf[off:off + 4])[0], off + 4


def get_string(buf, off):
    n, off = get_u32(buf, off)
    return buf[off:off + n], off + n


def recv_exact(s, n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            fail("socket closed after %d/%d bytes" % (len(out), n), 1)
        out += chunk
    return out


def transact(s, payload, chunk_size=None):
    """Send one frame (optionally fragmented), read one frame back."""
    frame = u32(len(payload)) + payload
    if chunk_size and chunk_size > 0:
        for i in range(0, len(frame), chunk_size):
            s.sendall(frame[i:i + chunk_size])
    else:
        s.sendall(frame)
    hdr = recv_exact(s, 4)
    (length,) = struct.unpack(">I", hdr)
    if length > 256 * 1024:
        fail("implausible frame length %d" % length, 1)
    return recv_exact(s, length)


def key_blob_type(blob):
    try:
        t, _ = get_string(blob, 0)
        return t.decode("ascii", "replace")
    except Exception:
        return "<unparseable>"


def load_blob(pubkey_file):
    """Extract the base64 blob from an OpenSSH .pub file."""
    with open(pubkey_file, "r") as f:
        parts = f.read().strip().split()
    if len(parts) < 2:
        fail("bad pubkey file: %s" % pubkey_file)
    import base64
    return base64.b64decode(parts[1])


def parse_identities(payload):
    if not payload or payload[0] != SSH_AGENT_IDENTITIES_ANSWER:
        fail("unexpected response type %s" % (payload[0] if payload else "EOF"), 1)
    nkeys, off = get_u32(payload, 1)
    keys = []
    for _ in range(nkeys):
        blob, off = get_string(payload, off)
        comment, off = get_string(payload, off)
        keys.append((blob, comment.decode("utf-8", "replace")))
    return keys


def cmd_list():
    s = connect()
    keys = parse_identities(transact(s, bytes([SSH_AGENTC_REQUEST_IDENTITIES])))
    print("identities: %d" % len(keys))
    for blob, comment in keys:
        print("  type=%s comment=%s blob_len=%d" % (key_blob_type(blob), comment, len(blob)))
    s.close()


def resolve_blob(pubkey_file=None):
    if pubkey_file:
        return load_blob(pubkey_file)
    s = connect()
    keys = parse_identities(transact(s, bytes([SSH_AGENTC_REQUEST_IDENTITIES])))
    s.close()
    if not keys:
        fail("agent has no identities", 1)
    return keys[0][0]


def sign_once(s, blob, data):
    payload = bytes([SSH_AGENTC_SIGN_REQUEST]) + string(blob) + string(data) + u32(0)
    resp = transact(s, payload)
    if not resp:
        fail("empty response", 1)
    if resp[0] == SSH_AGENT_FAILURE:
        return None
    if resp[0] != SSH_AGENT_SIGN_RESPONSE:
        fail("unexpected response type %d" % resp[0], 1)
    sigblob, _ = get_string(resp, 1)
    alg, off = get_string(sigblob, 0)
    sig, off = get_string(sigblob, off)
    return alg.decode("ascii", "replace"), sig


def cmd_sign(pubkey_file, data):
    blob = load_blob(pubkey_file)
    s = connect()
    result = sign_once(s, blob, data.encode())
    s.close()
    if result is None:
        fail("agent returned SSH_AGENT_FAILURE", 1)
    alg, sig = result
    print("algorithm: %s" % alg)
    print("signature: %s" % sig.hex())


def cmd_sign_raw(hexframe, chunk_size=None):
    try:
        frame = bytes.fromhex(hexframe)
    except ValueError:
        fail("invalid hex frame")
    s = connect()
    # Raw path: caller supplies the COMPLETE frame including uint32 length.
    cs = int(chunk_size) if chunk_size else None
    if cs and cs > 0:
        for i in range(0, len(frame), cs):
            s.sendall(frame[i:i + cs])
    else:
        s.sendall(frame)
    try:
        hdr = recv_exact(s, 4)
        (length,) = struct.unpack(">I", hdr)
        resp = recv_exact(s, length)
        print("response-type: %d" % (resp[0] if resp else -1))
        print("response-hex: %s" % resp.hex())
    except Exception as e:
        # Malformed frames may cause the agent to hang up; that is a result too.
        print("agent-closed-or-error: %s" % e)
    s.close()


def cmd_flood(n, pubkey_file=None):
    n = int(n)
    blob = resolve_blob(pubkey_file)
    s = connect()
    ok = failed = 0
    for i in range(n):
        result = sign_once(s, blob, b"flood-%d" % i)
        if result is None:
            failed += 1
        else:
            ok += 1
    s.close()
    print("flood: sent=%d ok=%d failed=%d" % (n, ok, failed))
    if ok == 0:
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        fail(__doc__, 2)
    cmd = sys.argv[1]
    if cmd == "list":
        cmd_list()
    elif cmd == "sign":
        if len(sys.argv) != 4:
            fail("usage: sign <pubkey-file> <data>")
        cmd_sign(sys.argv[2], sys.argv[3])
    elif cmd == "sign-raw":
        if len(sys.argv) < 3:
            fail("usage: sign-raw <hex-frame> [chunk-size]")
        cmd_sign_raw(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == "flood":
        if len(sys.argv) < 3:
            fail("usage: flood <n> [pubkey-file]")
        cmd_flood(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        fail("unknown subcommand: %s" % cmd)


if __name__ == "__main__":
    main()
