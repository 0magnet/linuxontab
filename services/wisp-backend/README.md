# wisp-backend (linuxontab-net.fly.dev)

WebSocket WISP v1 server providing real TCP egress for the v86 Alpine guest's NIC.

The v86 page (`https://linuxontab.com/shell/`) connects its `WispNetworkAdapter` to:

```
wisps://linuxontab-net.fly.dev/wisp
```

This Fly app is the upstream that handles DHCP, ARP, TCP connect, and DNS-over-TCP/53 for everything inside the guest. The Cloudflare Worker `relay.linuxontab.com` only handles `/dns-query` (DoH) and the helper-tunnel endpoints; real network egress goes here.

## What it runs

It runs the **same `traits` binary** as the upstream traits.build server (`apptron-traits-build` Fly app). The binary's `sys.serve` HTTP server handles `/wisp` WebSocket upgrade via [`traits/sys/serve/wisp.rs`](https://github.com/kilian-ai/traits.build/blob/main/traits/sys/serve/wisp.rs) — a tokio TCP-bridge implementation of [WISP v1](https://github.com/MercuryWorkshop/wisp-protocol).

## Deploy

**Do not build from traits.build `main`.** Its `traits` binary changed config
format after May 2026 (`Missing [implementation] section (required unless
command= is set)`) and crash-loops under this app's config — that took the
relay down for four minutes on 2026-10-17. The production image is built from
the traits.build branch **`wisp-v2-on-may14`** = commit 22d15788 (the May-14
deploy) + the Wisp v2 negotiation patch. Rebuild from that branch (or a
descendant of it) and smoke-test the image on a throwaway app before
pointing production at it:

```sh
# in a checkout of traits.build at branch wisp-v2-on-may14
fly deploy -c ~/.ai/LinuxOnTab-kernel/services/wisp-backend/fly.toml \
  --build-only --push --remote-only --image-label <label>
# canary: same fly.toml with app renamed and the [[mounts]] section removed
fly apps create linuxontab-net-canary && fly deploy -c fly-canary.toml \
  --image registry.fly.io/linuxontab-net:<label> --ha=false
# verify: /health 200, /wisp/debug, a handshake offering Sec-WebSocket-Protocol:
# wisp-v2 gets it echoed, and wasm.html?wisp=wss://linuxontab-net-canary.fly.dev/wisp
# logs "[WISP] session open: v2". Then:
fly deploy -c fly.toml --image registry.fly.io/linuxontab-net:<label> --ha=false
fly apps destroy linuxontab-net-canary -y
```

Rollback: `fly deploy -c fly.toml --image registry.fly.io/linuxontab-net:<previous deployment tag> --ha=false`
(`fly releases -a linuxontab-net` lists them).

## Protocol

Wisp v1, plus v2 with the UDP extension. A client offering the `wisp-v2`
subprotocol gets it echoed and an INFO frame (version 2.0, extension 0x01 UDP)
before the initial CONTINUE, so WispSlirp (offers v2 since linuxontab PR #15)
connects with no failed handshake and carries guest UDP — DNS to any
resolver, NTP, QUIC — as Wisp UDP streams.

UDP streams: one connected `UdpSocket` each, one DATA frame per datagram,
closed after 60 s idle, at most 64 per WebSocket. Refusals carry a CLOSE
reason that WispSlirp turns into ICMP port-unreachable for the guest:
0x42 unresolvable host or ICMP-refused target, 0x48 loopback / link-local
(incl. 169.254.169.254 metadata) / unique-local v6 (Fly's 6PN), 0x49 over
the per-connection cap. `/wisp/debug` reports the limits.

### Per-client limits

A client is its IPv4 address or IPv6 /64, read from `Fly-Client-IP` (Fly's
edge overwrites a client-supplied value — verified; off Fly the peer address
is used, because the header would be spoofable there).

| Limit | Default | Env override | When exceeded |
|---|---|---|---|
| concurrent WebSockets | 64 | `WISP_MAX_CONNS_PER_IP` | HTTP 429 on upgrade |
| stream opens (TCP + UDP) | 20/s, burst 200 | `WISP_OPENS_PER_SEC`, `WISP_OPENS_BURST` | CLOSE 0x49 |
| concurrent UDP streams | 256 | `WISP_MAX_UDP_STREAMS_PER_IP` | CLOSE 0x49 |
| outbound UDP packets | 500/s, burst 1000 | `WISP_UDP_PPS`, `WISP_UDP_PPS_BURST` | datagram dropped |
| outbound UDP bytes | 1 MiB/s, burst 2 MiB | `WISP_UDP_BYTES_PER_SEC`, `WISP_UDP_BYTES_BURST` | datagram dropped |

Defaults are generous on purpose: a tabs-as-containers stack is one socket
per tab, and offices / mobile carriers share one IPv4. To tune, add the env
vars to `[env]` in `fly.toml` and redeploy the same image
(`fly deploy -c fly.toml --image registry.fly.io/linuxontab-net:<tag>`) — no
rebuild. `/wisp/debug` shows the active limits, the caller's client key and
how many clients are tracked; refusals log as `conn_limit`, `throttled (…)`
and `udp_rate_dropped … datagrams=N`.

Current image: `registry.fly.io/linuxontab-net:wisp-ratelimit` (branch
`wisp-v2-on-may14` @ ccd5fcd5). Rollback chain: `wisp-udp` (UDP, no
per-client limits) → `wisp-v2-may14` (TCP-only v2).

## Deploy (historical notes)

```sh
# One-time
fly apps create linuxontab-net

# Deploy using the prebuilt image from the upstream traits.build app
IMAGE=$(fly image show -a apptron-traits-build --json | jq -r '.[0].FullImageRef')
fly deploy -c fly.toml --image "$IMAGE" --ha=false
```

To rebuild from source instead, deploy from the `traits.build` repo using its `Dockerfile`:

```sh
cd ~/.ai/traits/Polygrait/A.\ traits.build
fly deploy -c ~/.ai/LinuxOnTab/services/wisp-backend/fly.toml --ha=false
```

## Verify

```sh
curl -si https://linuxontab-net.fly.dev/health        # HTTP 200
curl -si 'https://linuxontab-net.fly.dev/wisp/debug'  # JSON status
```

For end-to-end, open https://linuxontab.com/shell/ → wait for prompt → run `wget https://example.com -O -`.

## Why a separate app from the relay Worker

Cloudflare Workers' `connect()` API has built-in loopback prevention and cannot reach CF-fronted targets (most of Alpine apk repos, etc.). Fly machines have unrestricted outbound TCP, so we keep WISP on Fly and only DoH on the CF Worker. See [traits/sys/serve/wisp.rs](https://github.com/kilian-ai/traits.build/blob/main/traits/sys/serve/wisp.rs) header comment.
