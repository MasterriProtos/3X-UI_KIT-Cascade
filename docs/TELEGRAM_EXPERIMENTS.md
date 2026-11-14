# Telegram in KIT-Cascade: experiments paused

**Status:** MTProto and WEB Proxy are not supported as working mobile Telegram cascade features in this release. No production node has been modified by this documentation change.

## Preserve the working foundation

- The supported network topology remains ENTRY → [RELAY …] → EXIT.
- The standard KIT protocol list remains selectable except that **MTProto is no longer selected by default** for *new* ENTRY installations. It remains selectable explicitly for experiments.
- Existing configured MTProto inbound, test users and nginx :8445 **are not automatically deleted or changed** by updating the Git repo. Operators must choose whether to disable them; do not force changes to deployed ENTRY.
- WEB is not activated. `cascade_v2/web_proxy_entry.py` is a preflight/staging-only helper that produces an offline SNI candidate; it never installs a relay or edits live nginx.

## Evidence from the investigated Android mobile case

1. The public nginx process listened on both IPv4 and IPv6 TCP/8445.
2. Raw capture on ENTRY showed mobile SYN → SYN-ACK → ACK and repeated **1088-byte** client TCP payloads.
3. Nginx forwarded PROXY-protocol data (50 bytes) and 1088-byte client payloads to local mtg at 127.0.0.1:10445.
4. `mtg` logged `cannot read client hello: cannot read handshake header: ... i/o timeout` on many connections. Some logs showed streams starting and finishing; those alone did **not** prove a successful Telegram connection.
5. The installed mtg version reported **1.15.0**; `x-ui` was active.
6. The read-only `entry-mtproto-probe` verified SOCKS5 at local 127.0.0.1:47999 → Xray `to-next-hop` → EXIT → TCP/443 Telegram access. This is **not** a full MTProto handshake check.
7. Temporarily disabling the nginx-public TCP/8445 MSS clamp `--set-mss 1100` did **not** restore mobile Telegram operation.
8. Desktop client connection worked in one controlled test, but that did not establish Android/mobile interoperability.

**Conclusion:** Failure in client-to-mtg initial handshake handling is reproducible under the tested mobile conditions. Do not call it a carrier block, a definite mtg bug, or a definite TCP truncation: the received 1088-byte segment alone does not establish the full TLS record length. Further investigation should correlate TLS record-header declared lengths with per-flow TCP sequence numbers using sanitized metadata only. Never publish secrets or full TLS packets.

## WEB Proxy investigation

- Official Telegram Android reportedly offered a WEB proxy type in the test device's user interface.
- WEB is **not** ordinary MTProto with a renamed link. It needs a genuine HTTPS relay and a compatible inner MTProxy backend.
- A stock WEB relay's separate MTProxy upstream cannot be assumed to route through Xray `to-next-hop`; current `mtg` local port 10445 expects PROXY protocol and is not validated as its compatible backend.
- Domain/certificate/public HTTPS client requirements are unfulfilled in the tested IP-only VPS setup.
- Source design: [WEB Proxy proposal](telegram-web-proxy-design.md).

## Safe actions on an existing installation

```bash
# Locate your actual checkout; example from the test deployment
cd /root/3X-UI_KIT-Cascade
git status --short
git branch --show-current
git pull --ff-only

# Read-only: confirms cascade state and the route to EXIT
python3 cascade_v2/install.py entry-status
python3 cascade_v2/install.py entry-probe
```

**Do not** rerun `bootstrap.sh` on an installed server. `git pull` does not update `/usr/local/bin/kit` or change running configurations. The new default protocol selection applies only to future installs after the corresponding installer is actually invoked.

## Handover checklist for a future contributor

- Reproduce Android 4G/5G handshake behavior against a segregated ENTRY with sanitized metadata.
- Check full TLS ClientHello length and mtg parser timeout with the exact Telegram build.
- Confirm PROXY protocol variant and verify authenticated backend routing through Xray → EXIT using a real Telegram session.
- For WEB, prove HTTPS relay + inner backend compatibility and secure loopback-only binds; verify no direct ENTRY egress, provide transactional rollback and real Android acceptance tests.
- Only after successful end-to-end tests make either Telegram path available by default.
