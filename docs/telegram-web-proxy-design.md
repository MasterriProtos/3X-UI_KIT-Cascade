# Telegram WEB Proxy for KIT-Cascade — isolated design (proposal)

Status: **DESIGN ONLY / NOT DEPLOYED**. The existing ENTRY → Xray → EXIT installation is not changed. WEB support must remain opt-in, feature-flagged and absent from user links until tested on the actual Telegram Android client.

## 0. Compatibility gate — before any server changes

WEB is a distinct Telegram proxy type, **not** Telegram Web in a browser and not a stock MTProto link renamed to WEB. It needs a WEB-aware Telegram client (WebView carrier). The published tproxy-server docs describe the Android implementation as a proof of concept; community reports claim some newer official Android releases support WEB. Neither statement proves support in a given installed build.

On the **official Telegram for Android**, open Settings → Data and Storage → Proxy Settings → Add Proxy and check whether the **WEB** type is present. Record app version and origin (Google Play / official APK). If absent, stop: do not install a WEB relay or generate links. Do not assume the public `t.me/webproxy` link is registered; the direct `tg://webproxy` form may require explicit client support. No account credentials or live secrets are needed for this check.

References:
- https://github.com/telegramdesktop/tproxy-server/blob/master/README.md
- https://github.com/telegramdesktop/tproxy-server/blob/master/ANDROID.md
- https://github.com/telegramdesktop/tproxy-server/blob/master/PROTOCOL.md
- https://git.stelm.me/astelm/telemt/src/branch/master/docs/WEB/WEB_PROXY.en.md

## 1. Desired architecture

```text
Official Telegram Android (WEB capable)
  └─ app-owned WebView → real HTTPS/WSS → ENTRY_PUBLIC_IP:443 (WEB_HOST SNI)
       └─ existing nginx stream SNI dispatcher [preserve current users/routes]
            └─ localhost TLS terminator on NEW_LOOPBACK_TLS_PORT
                 └─ localhost WEB HTTP relay on NEW_LOOPBACK_WEB_PORT
                      └─ localhost dedicated MTProxy backend on NEW_LOOPBACK_MT_PORT
                           └─ Xray SOCKS bridge (ENTRY)
                                └─ to-next-hop → EXIT → Telegram DC
```

**Important**: WEB relay is a carrier, not a replacement for the MTProxy back end. A tproxy-server-style relay opens TCP connections to a *stock MTProxy*; existing `mtg :10445` must **not** be reused blindly. It expects PROXY protocol from nginx and uses its own FakeTLS/client-secret handling. Confirm wire compatibility and the client's supported secret type; otherwise use an isolated, compatible MTProxy backend with a verified outbound-to-Xray integration. Never allow the dedicated backend to bypass the required ENTRY → EXIT path. Without a tested solution for this backend and its Xray egress, **do not mark WEB as implemented**.

A separate WEB hostname (e.g. `web.<owned-domain>`) with valid DNS A/AAAA mapping to ENTRY and a valid public TLS certificate is required. SNI based routing is permissible on the existing nginx stream 443 if the name is unambiguous, the selected carrier sends SNI, and no existing route is disturbed. Otherwise use a separate IP/interface or a knowingly chosen isolated port only if the WEB protocol/client supports it; standard WEB expects HTTPS on 443.

WEB TLS must be genuinely terminated (nginx http/Caddy/etc.) downstream of the stream multiplexer; the existing TCP stream route to `mtg` alone does not implement WEB. HTTPS relay must enforce origin/Host, secret-derived bridge capability, limits and timeouts per upstream protocol. Do not publicly bind internal relay, backend or SOCKS ports.

## 2. Security/infrastructure constraints

- **Opt-in, fail closed**. No new listeners, package installation, cert issuance, nginx edits or 3X-UI database edits on default `kit update` / `entry install`.
- Never copy the existing MTProto secret automatically. Use a fresh test profile; avoid showing credentials in logs, shell history and QR previews.
- Bind all added services to `127.0.0.1`; ensure upstream requests cannot redirect to arbitrary TCP addresses (fixed backend).
- Pin relay source revision / release and verify executable/hash before deployment. Do not implicitly fetch latest executable.
- Validate TLS certificate and hostname, HTTPS request handling, and backend compatibility before exposing the WEB link.
- Keep existing nginx stream 443 mapping, reality/xhttp and MTProto 8445 untouched. Check `nginx -t` before any reload.
- Preserve EXIT isolation: route Xray SOCKS traffic only via `to-next-hop`. Test from a WEB session, not merely with an independent SOCKS CONNECT.
- WEB does not imply Telegram voice calls work; client support and proxy limitations must be tested separately.

## 3. Proposed integration units (not yet implemented)

1. `cascade_v2/web_proxy.py`: read-only `preflight` to inspect WEB client gate (operator confirmed), DNS/cert, available local ports, nginx stream config, backend compatibility requirements, Xray outbound tag, and optional runtime prerequisites. No secret dumps.
2. `scripts/webproxy-entry.sh`: **explicit** install/remove/status with `--enable-web` and `--dry-run`; defaults to dry-run. Obtain operator confirmation before live config edits.
3. A dedicated systemd `kit-web-relay.service` and `kit-web-backend.service` plus TLS termination. Bind only loopback, run as restricted users, use systemd credentials or root-readable files (mode 0600). Protect against accidental public listeners.
4. Dedicated nginx stream `WEB_HOST` → `NEW_LOOPBACK_TLS_PORT` map entry. Do not overwrite the mapping wholesale or reuse the MTProto 8445 route.
5. Opt-in `kit user link NAME --web` only after an end-to-end healthy WEB deployment. WEB links use `tg://webproxy?server=HOST&secret=...` with no port. Format depends on protocol/secret encoding, including base-path rules. Never silently rewrite `tg://proxy` links to `tg://webproxy`.
6. Read-only `kit web status/check` reporting DNS, TLS, listener, backend, confirmed Xray routing and **mobile-client test pending/passed** as separate checks.

## 4. Transactional install and rollback

Preflight → create timestamped backup of the exact nginx stream file (plus referenced cert/config paths and local state inventory) → generate candidate local service configs → start/test loopback services → render only the required SNI map entry → `nginx -t` → atomic file replacement + nginx reload → functional WEB test → mark enabled only on confirmed success.

If validation/startup/health check fails: stop only newly installed WEB services, restore the exact backed-up stream file, `nginx -t`, reload nginx, remove the WEB-only candidate files; leave 443's other upstreams, 8445, `mtg`, Xray, ENTRY and EXIT unchanged. Expose a rollback command idempotently; no automated deletion of existing users, secrets or panel data.

**Stop condition**: If WEB integration requires swapping 3X-UI's existing `mtg` or changing its `routeThroughXray` settings, redesign with a separate backend instead.

## 5. Required acceptance tests

| Gate | Test / expected result |
|---|---|
| Client | Official Telegram Android version actually offers WEB, accepts direct WEB settings and identifies WEB links |
| Public TLS | `WEB_HOST:443` uses trusted certificate; existing SNI routes unchanged |
| Relay auth | Wrong WEB capability/secret cannot reach backend; regular browser gets benign site |
| Stream | WEB relay opens backend stream; matches configured secret |
| Egress | Backend traffic demonstrably traverses ENTRY Xray → EXIT → Telegram, **not** direct ENTRY |
| Mobile | With phone on 4G/5G (Wi-Fi off): proxy connects, sends/receives messages, uploads/downloads files |
| Stability | App restart, LTE↔5G switch, idle/reconnect, foreground/background limitations tested |
| Rollback | With WEB disabled, old users and stream 443/MTProto 8445 behave identically |

**Do not ship installer or WEB user-link generation until the Android client gate and verified dedicated backend routing have passed.**

## 6. Status as of design

- Existing MTProto path from mobile reaches nginx and `mtg`, but `mtg` reports `cannot read handshake header: i/o timeout`; lowering MSS did not fix it.
- Existing read-only `entry-mtproto-probe` verifies local Xray SOCKS → EXIT → Telegram TCP reachability, **not** full WEB or MTProto handshakes.
- **No WEB implementation has been installed on ENTRY**. This design is a guarded proposal only.
