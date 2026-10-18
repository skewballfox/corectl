#!/usr/bin/python3
"""Filtering D-Bus proxy between moonshine and the service user's session bus.

Installed as /usr/local/libexec/moonshine-bus-proxy, run by
moonshine-bus-proxy.service.

Moonshine launches its app with systemd's StartTransientUnit on the session
bus, and anything that can make that call can run any command as the service
user, outside any container. This proxy is the only bus the moonshine
container gets: it forwards the calls moonshine makes (session/application.rs
in moonshine v0.16.1), only for moonshine's unit and the Steam launcher, and
refuses everything else with AccessDenied.

Usage: moonshine-bus-proxy LISTEN_PATH BUS_PATH
"""

import asyncio
import logging
import os
import secrets
import socket
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("moonshine-bus-proxy")


class Policy:
    """What moonshine may do; the attribute names are match value patterns."""

    UNIT = "moonshine-session.service"
    UNIT_PATH = "/org/freedesktop/systemd1/unit/moonshine_2dsession_2eservice"
    LAUNCHER = "/etc/moonshine/launch-steam"
    SLICE = "moonshine.slice"
    BUS = "org.freedesktop.DBus"
    SYSTEMD = "org.freedesktop.systemd1"
    SYSTEMD_PATH = "/org/freedesktop/systemd1"
    MANAGER = "org.freedesktop.systemd1.Manager"
    PROPERTIES = "org.freedesktop.DBus.Properties"
    UNIT_INTERFACE = "org.freedesktop.systemd1.Unit"


# The variables moonshine sets (make_envs) and launch-steam forwards. The unit
# runs launch-steam and podman on the host, so anything else (LD_PRELOAD,
# BASH_ENV, PATH, XDG_CONFIG_HOME for containers.conf, ...) is refused.
ENV_NAMES = frozenset({
    "PULSE_SERVER", "PULSE_RUNTIME_PATH", "DISPLAY", "WAYLAND_DISPLAY",
    "MOONSHINE_WAYLAND_DISPLAY", "ENABLE_MOONSHINE_WSI", "MOONSHINE_HDR", "DXVK_HDR",
    "PROTON_USE_PIPEWIRE", "XDG_CURRENT_DESKTOP", "GAMESCOPE_WAYLAND_DISPLAY",
    "STEAM_GAME_DISPLAY_0", "STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER",
    "STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT", "STEAM_GAMESCOPE_NIS_SUPPORTED",
    "STEAM_GAMESCOPE_VRR_SUPPORTED", "STEAM_GAMESCOPE_HDR_SUPPORTED",
    "MOONSHINE_CLIENT_WIDTH", "MOONSHINE_CLIENT_HEIGHT", "MOONSHINE_CLIENT_FRAMERATE",
})

METHOD_CALL, METHOD_RETURN, ERROR, SIGNAL = 1, 2, 3, 4
NO_REPLY_EXPECTED = 0x1
PATH, INTERFACE, MEMBER, ERROR_NAME, REPLY_SERIAL, DESTINATION, SENDER, SIGNATURE, UNIX_FDS = range(1, 10)
MAX_MESSAGE = 1 << 27

FIXED = {"y": ("B", 1), "b": ("I", 4), "n": ("h", 2), "q": ("H", 2), "i": ("i", 4),
         "u": ("I", 4), "h": ("I", 4), "x": ("q", 8), "t": ("Q", 8), "d": ("d", 8)}


class ProtocolError(Exception):
    pass


class Refused(Exception):
    pass


def complete_type_end(sig: str, i: int) -> int:
    """Index just past the single complete type starting at sig[i]."""
    if i >= len(sig):
        raise ProtocolError(f"truncated signature {sig!r}")
    match sig[i]:
        case "a":
            return complete_type_end(sig, i + 1)
        case "(" | "{" as opening:
            closing = ")" if opening == "(" else "}"
            i += 1
            while i < len(sig) and sig[i] != closing:
                i = complete_type_end(sig, i)
            if i >= len(sig):
                raise ProtocolError(f"unbalanced signature {sig!r}")
            return i + 1
        case c if c in FIXED or c in "sogv":
            return i + 1
        case c:
            raise ProtocolError(f"bad type {c!r} in signature {sig!r}")


def split_signature(sig: str) -> list[str]:
    types, i = [], 0
    while i < len(sig):
        end = complete_type_end(sig, i)
        types.append(sig[i:end])
        i = end
    return types


def alignment(t: str) -> int:
    match t[0]:
        case "y" | "g" | "v":
            return 1
        case "(" | "{":
            return 8
        case "a" | "s" | "o":
            return 4
        case c:
            return FIXED[c][1]


class Reader:
    """Unmarshals values from a message; offsets count from the message start."""

    __slots__ = ("data", "pos", "order")

    def __init__(self, data: bytes, little: bool, pos: int = 0) -> None:
        self.data, self.pos = data, pos
        self.order = "<" if little else ">"

    def align(self, n: int) -> None:
        self.pos += -self.pos % n

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise ProtocolError("value runs past the end of the message")
        chunk = self.data[self.pos:self.pos + n]
        self.pos += n
        return chunk

    def fixed(self, code: str, size: int):
        self.align(size)
        (value,) = struct.unpack(self.order + code, self.take(size))
        return value

    def text(self, length: int) -> str:
        raw = self.take(length + 1)
        if raw[-1] != 0:
            raise ProtocolError("string is not NUL-terminated")
        try:
            return raw[:-1].decode()
        except UnicodeDecodeError as e:
            raise ProtocolError("string is not UTF-8") from e

    def read(self, t: str):
        match t[0]:
            case "s" | "o":
                return self.text(self.fixed("I", 4))
            case "g":
                return self.text(self.fixed("B", 1))
            case "v":
                sig = self.read("g")
                if len(split_signature(sig)) != 1:
                    raise ProtocolError(f"variant signature {sig!r} is not one type")
                return sig, self.read(sig)
            case "a":
                length = self.fixed("I", 4)
                element = t[1:]
                self.align(alignment(element))
                end = self.pos + length
                if end > len(self.data):
                    raise ProtocolError("array runs past the end of the message")
                items = []
                while self.pos < end:
                    items.append(self.read(element))
                return items
            case "(" | "{":
                self.align(8)
                return tuple(self.read(member) for member in split_signature(t[1:-1]))
            case "b":
                return bool(self.fixed("I", 4))
            case c:
                return self.fixed(*FIXED[c])


@dataclass(slots=True)
class Message:
    raw: bytes
    little: bool
    type: int
    flags: int
    serial: int
    fields: dict
    body_start: int

    def args(self, expected: str) -> tuple:
        sig = self.fields.get(SIGNATURE, "")
        if sig != expected:
            raise Refused(f"signature {sig!r}, expected {expected!r}")
        reader = Reader(self.raw, self.little, self.body_start)
        return tuple(reader.read(t) for t in split_signature(sig))

    def describe(self) -> str:
        f = self.fields
        return f"{f.get(DESTINATION)} {f.get(PATH)} {f.get(INTERFACE)}.{f.get(MEMBER)}"


async def read_message(reader: asyncio.StreamReader) -> Message | None:
    try:
        fixed = await reader.readexactly(16)
    except asyncio.IncompleteReadError as e:
        if e.partial:
            raise ProtocolError("connection closed mid-message") from e
        return None
    match fixed[0:1]:
        case b"l":
            little = True
        case b"B":
            little = False
        case _:
            raise ProtocolError("bad endianness byte")
    order = "<" if little else ">"
    msg_type, flags, version = fixed[1], fixed[2], fixed[3]
    body_len, serial, fields_len = struct.unpack(order + "III", fixed[4:16])
    if version != 1:
        raise ProtocolError(f"protocol version {version}")
    body_start = 16 + fields_len + (-(16 + fields_len) % 8)
    total = body_start + body_len
    if total > MAX_MESSAGE:
        raise ProtocolError(f"{total}-byte message")
    raw = fixed + await reader.readexactly(total - 16)
    header = Reader(raw, little, 12)
    fields = {code: value for code, (_sig, value) in header.read("a(yv)")}
    return Message(raw, little, msg_type, flags, serial, fields, body_start)


class Writer:
    """Little-endian marshalling, just enough for an error reply."""

    __slots__ = ("buf",)

    def __init__(self) -> None:
        self.buf = bytearray()

    def align(self, n: int) -> None:
        self.buf += bytes(-len(self.buf) % n)

    def u32(self, value: int) -> None:
        self.align(4)
        self.buf += struct.pack("<I", value)

    def string(self, value: str) -> None:
        raw = value.encode()
        self.u32(len(raw))
        self.buf += raw + b"\0"

    def signature(self, value: str) -> None:
        raw = value.encode()
        self.buf.append(len(raw))
        self.buf += raw + b"\0"


def error_reply(call: Message, serial: int, reason: str) -> bytes:
    body = Writer()
    body.string(f"moonshine-bus-proxy: {reason}")
    fields = [(REPLY_SERIAL, "u", call.serial),
              (ERROR_NAME, "s", "org.freedesktop.DBus.Error.AccessDenied"),
              (SENDER, "s", Policy.BUS),
              (SIGNATURE, "g", "s")]
    w = Writer()
    w.buf += bytes([ord("l"), ERROR, NO_REPLY_EXPECTED, 1])
    w.u32(len(body.buf))
    w.u32(serial)
    w.u32(0)  # header fields length, patched below
    for code, sig, value in fields:
        w.align(8)
        w.buf.append(code)
        w.signature(sig)
        match sig:
            case "u":
                w.u32(value)
            case "s":
                w.string(value)
            case "g":
                w.signature(value)
    struct.pack_into("<I", w.buf, 12, len(w.buf) - 16)
    w.align(8)
    return bytes(w.buf + body.buf)


def check_environment(entries: list) -> None:
    for entry in entries:
        name, sep, _ = entry.partition("=")
        if not sep or name not in ENV_NAMES:
            raise Refused(f"environment variable {name!r}")


def check_transient_unit(name: str, mode: str, properties: list, aux: list) -> None:
    if (name, mode, aux) != (Policy.UNIT, "replace", []):
        raise Refused(f"transient unit {name!r} (mode {mode!r}, {len(aux)} aux units)")
    seen = set()
    for key, (sig, value) in properties:
        if key in seen:
            raise Refused(f"duplicate property {key}")
        seen.add(key)
        match key, sig, value:
            case ("Type", "s", "exec") | ("Slice", "s", Policy.SLICE) \
                    | ("CollectMode", "s", "inactive-or-failed") | ("TimeoutStopUSec", "t", _):
                pass
            case ("StandardOutput" | "StandardError", "s", "journal" | "null"):
                pass
            case ("Environment", "as", _):
                check_environment(value)
            # One command, the launcher; its arguments go to Steam inside the container
            case ("ExecStart", "a(sasb)", [(Policy.LAUNCHER, [Policy.LAUNCHER, *_], _)]):
                pass
            case _:
                raise Refused(f"property {key} ({sig}) = {value!r}")
    if "ExecStart" not in seen:
        raise Refused("transient unit without ExecStart")


def check_call(msg: Message) -> None:
    """Raise Refused unless msg is a call moonshine needs to make."""
    if msg.type != METHOD_CALL:
        raise Refused(f"message type {msg.type}")
    if UNIX_FDS in msg.fields:
        raise Refused("file descriptors")
    f = msg.fields
    match f.get(DESTINATION), f.get(INTERFACE), f.get(MEMBER):
        case (Policy.BUS, Policy.BUS, "Hello" | "GetNameOwner" | "NameHasOwner" | "GetId" | "RemoveMatch"):
            pass
        case (Policy.BUS, Policy.BUS, "AddMatch"):
            (rule,) = msg.args("s")
            if "eavesdrop" in rule:
                raise Refused(f"match rule {rule!r}")
        case (Policy.SYSTEMD, Policy.MANAGER, member) if f.get(PATH) != Policy.SYSTEMD_PATH:
            raise Refused(f"{member} on {f.get(PATH)}")
        case (Policy.SYSTEMD, Policy.MANAGER, "Subscribe"):
            msg.args("")
        case (Policy.SYSTEMD, Policy.MANAGER, "GetUnit"):
            if msg.args("s") != (Policy.UNIT,):
                raise Refused(f"GetUnit {msg.args('s')}")
        case (Policy.SYSTEMD, Policy.MANAGER, "StopUnit"):
            if msg.args("ss") != (Policy.UNIT, "replace"):
                raise Refused(f"StopUnit {msg.args('ss')}")
        case (Policy.SYSTEMD, Policy.MANAGER, "StartTransientUnit"):
            check_transient_unit(*msg.args("ssa(sv)a(sa(sv))"))
        case (Policy.SYSTEMD, Policy.PROPERTIES, "Get"):
            wanted = (Policy.UNIT_INTERFACE, "ActiveState")
            if f.get(PATH) != Policy.UNIT_PATH or msg.args("ss") != wanted:
                raise Refused(f"Get {msg.args('ss')} on {f.get(PATH)}")
        case _:
            raise Refused("not on the allowlist")


async def serve_auth(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Server side of SASL. Identity comes from SO_PEERCRED (checked by the
    caller): the uid the client claims is in the container's user namespace."""
    if await reader.readexactly(1) != b"\0":
        raise ProtocolError("missing leading NUL byte")
    authed = waiting_for_data = False
    while True:
        line = await reader.readuntil(b"\r\n")
        match line[:-2].decode("ascii", "replace").split():
            case ["AUTH", "EXTERNAL", _]:
                authed, reply = True, f"OK {secrets.token_hex(16)}"
            case ["AUTH", "EXTERNAL"]:
                waiting_for_data, reply = True, "DATA"
            case ["DATA", *_] if waiting_for_data:
                authed, reply = True, f"OK {secrets.token_hex(16)}"
            case ["NEGOTIATE_UNIX_FD"]:
                reply = "ERROR file descriptor passing is not supported"
            case ["BEGIN"] if authed:
                return
            case ["AUTH", *_] | ["CANCEL"] | ["ERROR", *_]:
                authed = waiting_for_data = False
                reply = "REJECTED EXTERNAL"
            case _:
                reply = "ERROR"
        writer.write(reply.encode() + b"\r\n")
        await writer.drain()


async def client_auth(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    writer.write(b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
    reply = await reader.readuntil(b"\r\n")
    if not reply.startswith(b"OK "):
        raise ProtocolError(f"bus refused authentication: {reply!r}")
    writer.write(b"BEGIN\r\n")
    await writer.drain()


async def client_to_bus(client_r, client_w, bus_w, peer: str) -> None:
    serial = 0x80000000
    while (msg := await read_message(client_r)) is not None:
        try:
            check_call(msg)
        except Refused as e:
            log.warning("%s: refused %s: %s", peer, msg.describe(), e)
            if msg.type == METHOD_CALL and not msg.flags & NO_REPLY_EXPECTED:
                serial += 1
                client_w.write(error_reply(msg, serial, str(e)))
                await client_w.drain()
            continue
        bus_w.write(msg.raw)
        await bus_w.drain()


async def bus_to_client(bus_r, client_w, peer: str) -> None:
    while (msg := await read_message(bus_r)) is not None:
        # Nothing should call moonshine; replies and signals pass through
        if msg.type == METHOD_CALL:
            log.warning("%s: dropped incoming call %s", peer, msg.describe())
            continue
        client_w.write(msg.raw)
        await client_w.drain()


async def handle(client_r, client_w, bus_path: Path) -> None:
    sock = client_w.get_extra_info("socket")
    pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    peer = f"pid {pid}"
    bus_w = None
    try:
        if uid != os.getuid():
            raise ProtocolError(f"uid {uid} is not the service user")
        await serve_auth(client_r, client_w)
        bus_r, bus_w = await asyncio.open_unix_connection(bus_path)
        await client_auth(bus_r, bus_w)
        pumps = [asyncio.create_task(client_to_bus(client_r, client_w, bus_w, peer)),
                 asyncio.create_task(bus_to_client(bus_r, client_w, peer))]
        done, pending = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            task.result()
    except (ProtocolError, OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as e:
        log.warning("%s: closing connection: %s", peer, e)
    finally:
        for writer in (client_w, bus_w):
            if writer is not None:
                writer.close()


def notify_ready() -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(address)
        sock.sendall(b"READY=1")


async def serve(listen: Path, bus_path: Path) -> None:
    listen.unlink(missing_ok=True)
    os.umask(0o077)
    server = await asyncio.start_unix_server(lambda r, w: handle(r, w, bus_path), path=listen)
    log.info("forwarding %s to %s", listen, bus_path)
    notify_ready()
    async with server:
        await server.serve_forever()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    match sys.argv[1:]:
        case [listen, bus_path]:
            asyncio.run(serve(Path(listen), Path(bus_path)))
        case _:
            sys.exit(f"usage: {sys.argv[0]} LISTEN_PATH BUS_PATH")


if __name__ == "__main__":
    main()
