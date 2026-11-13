#!/usr/bin/env python3
"""Disposable CI integration: real Xray SOCKS → VLESS/REALITY relay → exit → echo."""
from __future__ import annotations

import json
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hops

XRAY = "/usr/local/bin/xray"
PUBLIC_SAMPLE = "2606:4700:4700::1111"


def port_of(family, address):
    with socket.socket(family, socket.SOCK_STREAM) as s:
        s.bind((address, 0))
        return s.getsockname()[1]


def pair():
    data = subprocess.check_output([XRAY, "x25519"], text=True)
    fields = {}
    for line in data.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip().lower().replace(" ", "")] = v.strip()
    private = fields.get("privatekey")
    public = next((v for k, v in fields.items()
                   if k.startswith("password") or k.startswith("publickey")), None)
    if not private or not public:
        raise RuntimeError("Cannot parse Xray x25519 output")
    return private, public


def node(port):
    private, public = pair()
    return {
        "address": PUBLIC_SAMPLE, "port": port,
        "id": str(uuid.uuid4()), "serverName": "www.microsoft.com",
        "privateKey": private, "publicKey": public,
        "shortId": "0123456789abcdef",
    }


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        part = sock.recv(n - len(data))
        if not part:
            raise RuntimeError("unexpected socket EOF")
        data += part
    return data


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        if self.request.recv(4) == b"ping":
            self.request.sendall(b"cascade-okay")


def check_socks(port, echo_port):
    with socket.create_connection(("127.0.0.1", port), timeout=15) as s:
        s.settimeout(15)
        s.sendall(b"\x05\x01\x00")
        assert read_exact(s, 2) == b"\x05\x00"
        s.sendall(
            b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1")
            + echo_port.to_bytes(2, "big")
        )
        answer = read_exact(s, 4)
        if answer[1] != 0:
            raise RuntimeError(f"SOCKS returned failure {answer[1]}")
        size = {1: 4, 4: 16}.get(answer[3])
        if answer[3] == 3:
            size = read_exact(s, 1)[0]
        if size is None:
            raise RuntimeError("invalid SOCKS response type")
        read_exact(s, size + 2)
        s.sendall(b"ping")
        assert read_exact(s, 12) == b"cascade-okay"
    print("Real two-hop VLESS/REALITY transport succeeded")


def main():
    ex_port = port_of(socket.AF_INET6, "::1")
    relay_port = port_of(socket.AF_INET6, "::1")
    socks_port = port_of(socket.AF_INET, "127.0.0.1")
    if len({ex_port, relay_port}) != 2:
        raise RuntimeError("port allocation collision")
    exit_node, relay_node = node(ex_port), node(relay_port)
    exit_cfg = hops.node_config("exit", exit_node)
    exit_cfg["inbounds"][0]["listen"] = "::1"
    relay_cfg = hops.node_config("relay", relay_node, hops.link(exit_node))
    relay_cfg["inbounds"][0]["listen"] = "::1"
    relay_cfg["outbounds"][0]["settings"]["address"] = "::1"
    entry_outbound = hops.outbound(hops.parse_link(hops.link(relay_node)))
    entry_outbound["settings"]["address"] = "::1"
    entry_cfg = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "127.0.0.1", "port": socks_port,
            "protocol": "socks", "settings": {"auth": "noauth"},
        }],
        "outbounds": [entry_outbound],
    }
    echo = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo)
    echo.daemon_threads = True
    thread = threading.Thread(target=echo.serve_forever, daemon=True)
    thread.start()
    processes = []
    streams = []
    try:
        with tempfile.TemporaryDirectory(prefix="cascade-live-") as temp:
            for name, cfg in (("exit", exit_cfg), ("relay", relay_cfg), ("entry", entry_cfg)):
                config = Path(temp) / f"{name}.json"
                config.write_text(hops.format_plan(cfg))
                subprocess.run([XRAY, "run", "-test", "-config", str(config)], check=True)
                logs = open(Path(temp) / f"{name}.log", "w", encoding="utf-8")
                streams.append(logs)
                proc = subprocess.Popen([XRAY, "run", "-config", str(config)],
                                        stdout=logs, stderr=logs)
                processes.append(proc)
                time.sleep(0.5)
                if proc.poll() is not None:
                    raise RuntimeError(f"{name} Xray exited immediately; logs: " +
                                       (Path(temp) / f"{name}.log").read_text()[-2000:])
            check_socks(socks_port, echo.server_address[1])
    except Exception:
        for process in processes:
            if process.poll() is not None:
                continue
        for stream in streams:
            stream.flush()
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for stream in streams:
            stream.close()
        echo.shutdown()
        echo.server_close()


if __name__ == "__main__":
    main()
