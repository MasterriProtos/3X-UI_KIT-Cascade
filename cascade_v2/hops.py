#!/usr/bin/env python3
"""Pure Xray-core VLESS/REALITY IPv6 hop builder. Never modifies a server."""
from __future__ import annotations

import ipaddress
import json
import re
import urllib.parse as url
import uuid


class ChainError(ValueError):
    """Invalid hop parameters or share link."""


def check_ip(value: str) -> str:
    try:
        address = ipaddress.IPv6Address(value)
    except (ValueError, TypeError) as exc:
        raise ChainError("Нужен глобальный IPv6 следующего узла") from exc
    if not address.is_global:
        raise ChainError("IPv6 должен быть глобальным unicast, не loopback/link-local")
    return address.compressed


def check_port(value: int | str) -> int:
    try:
        number = int(value)
    except (ValueError, TypeError) as exc:
        raise ChainError("Неверный TCP-порт") from exc
    if isinstance(value, bool) or not 1 <= number <= 65535:
        raise ChainError("TCP-порт должен быть от 1 до 65535")
    return number


def check_uuid(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ChainError("Неверный VLESS UUID") from exc


def check_sni(value: str) -> str:
    if not isinstance(value, str) or len(value) > 253 or "." not in value:
        raise ChainError("Для REALITY нужен корректный домен SNI")
    labels = value.rstrip(".").split(".")
    if not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part) for part in labels):
        raise ChainError("Неверный SNI")
    return ".".join(labels).lower()


def check_key(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", value):
        raise ChainError("X25519 ключ должен быть base64url без padding (43 символа)")
    return value


def check_sid(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{16}", value):
        raise ChainError("REALITY shortId должен содержать 16 hex символов")
    return value.lower()


def validated(data: dict, include_private: bool = False) -> dict:
    if not isinstance(data, dict):
        raise ChainError("Ожидался объект параметров узла")
    result = {
        "address": check_ip(data["address"]),
        "port": check_port(data["port"]),
        "id": check_uuid(data["id"]),
        "serverName": check_sni(data["serverName"]),
        "publicKey": check_key(data["publicKey"]),
        "shortId": check_sid(data["shortId"]),
    }
    if include_private:
        result["privateKey"] = check_key(data["privateKey"])
    return result


def link(local: dict, name: str = "KIT-Cascade") -> str:
    p = validated(local)
    query = url.urlencode({
        "encryption": "none", "security": "reality", "type": "tcp",
        "sni": p["serverName"], "fp": "chrome", "pbk": p["publicKey"],
        "sid": p["shortId"], "flow": "xtls-rprx-vision",
    })
    return (
        f'vless://{p["id"]}@[{p["address"]}]:{p["port"]}'
        f'?{query}#{url.quote(name, safe="")}'
    )


def parse_link(text: str) -> dict:
    if not isinstance(text, str) or not text.startswith("vless://"):
        raise ChainError("Ожидается VLESS-ссылка")
    try:
        parts = url.urlsplit(text.strip())
        if parts.scheme != "vless" or not parts.netloc.partition("@")[2].startswith("["):
            raise ChainError("Адрес сервера должен быть IPv6 в квадратных скобках")
        raw = url.parse_qs(parts.query, keep_blank_values=True, strict_parsing=True)
        if any(len(values) != 1 for values in raw.values()):
            raise ChainError("Повторяющиеся параметры ссылки недопустимы")
        q = {key: values[0] for key, values in raw.items()}
        if (q.get("security"), q.get("type"), q.get("encryption"),
                q.get("flow"), q.get("fp")) != (
                "reality", "tcp", "none", "xtls-rprx-vision", "chrome"):
            raise ChainError("Поддерживается VLESS + REALITY + TCP + Vision + Chrome")
        return validated({
            "address": parts.hostname, "port": parts.port, "id": parts.username,
            "serverName": q["sni"], "publicKey": q["pbk"], "shortId": q["sid"],
        })
    except (ValueError, TypeError, KeyError) as exc:
        if isinstance(exc, ChainError):
            raise
        raise ChainError("Неверный формат VLESS-ссылки") from exc


def inbound(local: dict) -> dict:
    p = validated(local, include_private=True)
    return {
        "tag": "from-previous-hop",
        "listen": p["address"],  # no IPv4 listeners on a relay/exit
        "port": p["port"],
        "protocol": "vless",
        "settings": {
            "users": [{"id": p["id"], "flow": "xtls-rprx-vision"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "raw", "security": "reality",
            "realitySettings": {
                "show": False, "target": p["serverName"] + ":443",
                "serverNames": [p["serverName"]],
                "privateKey": p["privateKey"],
                "shortIds": [p["shortId"]],
            },
        },
    }


def outbound(next_hop: dict) -> dict:
    p = validated(next_hop)
    return {
        "tag": "to-next-hop", "protocol": "vless",
        "settings": {
            "address": p["address"], "port": p["port"], "id": p["id"],
            "encryption": "none", "flow": "xtls-rprx-vision",
        },
        "streamSettings": {
            "network": "raw", "security": "reality",
            "realitySettings": {
                "serverName": p["serverName"], "fingerprint": "chrome",
                "password": p["publicKey"],  # renamed from publicKey in newer Xray
                "shortId": p["shortId"], "spiderX": "/",
            },
        },
    }


def node_config(role: str, local: dict, next_link: str | None = None) -> dict:
    if role not in ("exit", "relay"):
        raise ChainError("Роль должна быть exit или relay")
    if (role == "relay") != (next_link is not None):
        raise ChainError("Только RELAY принимает ссылку следующего узла")
    first = outbound(parse_link(next_link)) if role == "relay" else {
        "tag": "internet", "protocol": "freedom", "settings": {},
    }
    destination = "to-next-hop" if role == "relay" else "internet"
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [inbound(local)],
        "outbounds": [first, {
            "tag": "block", "protocol": "blackhole", "settings": {},
        }],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [{
                "type": "field", "inboundTag": ["from-previous-hop"],
                "outboundTag": destination,
            }],
        },
    }


def entry_plan(next_link: str) -> dict:
    """Plans ENTRY outbound; integration with KIT panel is a later milestone."""
    return {"outbound": outbound(parse_link(next_link)), "default": "to-next-hop"}


def format_plan(config: dict) -> str:
    return json.dumps(config, indent=2, ensure_ascii=False) + "\n"
