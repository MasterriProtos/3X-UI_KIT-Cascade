#!/usr/bin/env python3
"""Offline builder for multi-hop VLESS + REALITY chain. No system changes."""
import ipaddress
import json
import re
import urllib.parse as url
import uuid

class ChainError(ValueError):
    pass

def check_ip(value):
    try:
        ip = ipaddress.IPv6Address(value)
    except ValueError as exc:
        raise ChainError("Global IPv6 required") from exc
    if not ip.is_global:
        raise ChainError("Global unicast IPv6 required")
    return ip.compressed

def check_port(value):
    n = int(value)
    if not 1 <= n <= 65535:
        raise ChainError("Invalid port")
    return n

def check_uuid(value):
    try:
        return str(uuid.UUID(value))
    except ValueError as exc:
        raise ChainError("Invalid UUID") from exc

def check_sni(value):
    labels = value.split(".")
    if len(value) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in labels):
        raise ChainError("Invalid SNI")
    return value.lower()

def check_key(value):
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,48}", value):
        raise ChainError("Expected base64url X25519 key")
    return value

def check_sid(value):
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}){0,8}", value):
        raise ChainError("Invalid REALITY shortId")
    return value.lower()

def link(local, name="Cascade"):
    ip, port = check_ip(local["address"]), check_port(local["port"])
    user = check_uuid(local["id"])
    q = url.urlencode({"encryption":"none","security":"reality","type":"tcp",
                       "sni":check_sni(local["serverName"]), "fp":"chrome",
                       "pbk":check_key(local["publicKey"]), "sid":check_sid(local["shortId"]),
                       "flow":"xtls-rprx-vision"})
    return f"vless://{user}@[{ip}]:{port}?{q}#{url.quote(name, safe='')}"

def parse_link(text):
    try:
        u = url.urlsplit(text.strip())
        if u.scheme != "vless" or not u.username or not u.netloc.partition("@")[2].startswith("["):
            raise ChainError("Expected VLESS URL with bracketed IPv6")
        raw = url.parse_qs(u.query, keep_blank_values=True, strict_parsing=True)
        if any(len(v) != 1 for v in raw.values()):
            raise ChainError("Duplicate URL parameters")
        q = {k: v[0] for k,v in raw.items()}
        if (q.get("security"),q.get("type"),q.get("encryption"),q.get("flow"),q.get("fp")) != (
              "reality","tcp","none","xtls-rprx-vision","chrome"):
            raise ChainError("Requires VLESS/REALITY/TCP/Vision/chrome")
        return {"address":check_ip(u.hostname), "port":check_port(u.port),
                "id":check_uuid(u.username), "publicKey":check_key(q["pbk"]),
                "shortId":check_sid(q["sid"]), "serverName":check_sni(q["sni"])}
    except (ValueError,TypeError,KeyError) as exc:
        if isinstance(exc, ChainError):
            raise
        raise ChainError("Malformed link") from exc

def inbound(local):
    return {"tag":"from-previous-hop","listen":"::","port":check_port(local["port"]),
            "protocol":"vless","settings":{"clients":[
                {"id":check_uuid(local["id"]),"flow":"xtls-rprx-vision"}],
                "decryption":"none"},
            "streamSettings":{"network":"tcp","security":"reality",
                "realitySettings":{"show":False,"dest":check_sni(local["serverName"])+":443",
                  "serverNames":[check_sni(local["serverName"])],
                  "privateKey":check_key(local["privateKey"]),
                  "shortIds":[check_sid(local["shortId"])]}}}

def outbound(next_hop):
    p=next_hop
    return {"tag":"to-next-hop","protocol":"vless",
            "settings":{"address":check_ip(p["address"]),"port":check_port(p["port"]),
                        "id":check_uuid(p["id"]),"encryption":"none","flow":"xtls-rprx-vision"},
            "streamSettings":{"network":"tcp","security":"reality",
              "realitySettings":{"serverName":check_sni(p["serverName"]),
                "fingerprint":"chrome","publicKey":check_key(p["publicKey"]),
                "shortId":check_sid(p["shortId"]),"spiderX":"/"}}}

def node_config(role,local,next_link=None):
    if role not in ("exit","relay"):
        raise ChainError("Role must be exit or relay")
    if (role=="relay") != (next_link is not None):
        raise ChainError("Only relay accepts next-hop link")
    first=outbound(parse_link(next_link)) if role=="relay" else {
        "tag":"internet","protocol":"freedom","settings":{}}
    return {"log":{"loglevel":"warning"},"inbounds":[inbound(local)],
            "outbounds":[first,{"tag":"block","protocol":"blackhole","settings":{}}]}

def entry_plan(next_link):
    """Outbound only; ENTRY routing must retain panel API and local routes."""
    return {"outbound":outbound(parse_link(next_link)), "default":"to-next-hop"}

def format_plan(plan):
    return json.dumps(plan,indent=2,ensure_ascii=False)
