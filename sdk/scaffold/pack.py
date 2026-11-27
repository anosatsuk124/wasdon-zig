"""Example text language: _start logs the contents of message.txt."""
import json
from pathlib import Path
import sys


def uint(value):
    data = bytearray()
    while value >= 128:
        data.append(128 | (value & 127))
        value >>= 7
    data.append(value)
    return bytes(data)


def blob(data):
    return uint(len(data)) + data


def compile_message(message):
    def section(tag, data):
        return bytes([tag]) + blob(data)
    log = b"UnityEngineDebug.__Log__SystemString__SystemVoid"
    # i32.const takes signed LEB. A zero extension byte keeps bit 6 positive.
    size = bytearray(uint(len(message)))
    if size[-1] & 64:
        size[-1] |= 128
        size.append(0)
    body = b"\x00\x41\x00\x41" + size + b"\x10\x00\x0b"
    return b"".join((
        b"\0asm\x01\0\0\0", section(1, b"\x02\x60\x02\x7f\x7f\x00\x60\x00\x00"),
        section(2, b"\x01" + blob(b"udon.static") + blob(log) + b"\x00\x00"),
        section(3, b"\x01\x01"), section(5, b"\x01\x00" + uint(max(1, (len(message)+65535)//65536))),
        section(7, b"\x01" + blob(b"_start") + b"\x00\x01"), section(10, b"\x01" + blob(body)),
        section(11, b"\x01\x00\x41\x00\x0b" + blob(message)),
    ))


def handle(req):
    action = req["action"]
    if action in ("doctor", "setup"):
        return {"ready": True}
    if action == "bindings":
        calls = {n["name"]: n["name"] for n in req["nodes"] if n["kind"] == "extern"}
        if req["mode"] == "describe":
            return {"calls": calls}
        (Path(req["outputDir"]) / "externs.json").write_text(json.dumps(calls), encoding="utf-8")
        return {"count": len(calls)}
    source = Path(req["projectDir"]) / "message.txt"
    (Path(req["outputDir"]) / "sample.wasm").write_bytes(compile_message(source.read_text(encoding="utf-8").strip().encode()))
    return {"wasm": "sample.wasm", "dependencies": ["message.txt"]}


if __name__ == "__main__":
    print(json.dumps(dict(interfaceVersion=1, **handle(json.load(sys.stdin)))))
