# k3s Public Edge (Traefik + WireGuard)

How `*.eduindev.com` reaches the k3s cluster. Replaced frp (frps on the VPS, an `frpc`
pod per namespace) in Oct 2026. The VPS half is in `services/vps/`.

```
client ─443─▶ VPS Traefik (TLS, wildcard cert, router "k8s" priority 10)
          ─▶ wg-easy container :8000 ── DNAT ─▶ 10.8.0.3:8000 over wg0 (SNAT to 10.8.0.1)
          ─▶ traefik pod (ns traefik) — wg0 = 10.8.0.3 lives inside this pod
          ─▶ Ingress (Host) ─▶ Service
client ─udp 7000─▶ wg-easy (published) ── DNAT ─▶ 10.8.0.3:7000 ─▶ IngressRouteUDP ─▶ livekit:7000
```

| File | What |
|------|------|
| `traefik-values.yaml` | Helm values for `traefik/traefik` **41.7.1** (Traefik v3.7.14) |
| `coredns-custom.yaml` | forwards the `.lan` zone to BIND (LXC 111), so pods resolve `s3.lan` etc. |
| `wg0.conf.example` | shape of the `traefik/wg0` Secret, keys removed |

## Install / upgrade

```sh
helm repo add traefik https://traefik.github.io/charts
kubectl create ns traefik
kubectl -n traefik create secret generic wg0 --from-file=wg0.conf=<real wg0.conf>
kubectl apply -f services/k8s-edge/coredns-custom.yaml
helm upgrade --install traefik traefik/traefik --version 41.7.1 -n traefik \
  -f services/k8s-edge/traefik-values.yaml --wait
```

The strategy is `Recreate`, so every upgrade drops public traffic for ~10 s.

## Why it is built this way

- **The WireGuard interface is inside the Traefik pod** (native sidecar
  `procustodibus/wireguard`, `NET_ADMIN`, root). Traefik then listens on 10.8.0.3 itself, so
  there are no LAN routes, no masquerade at home and no extra gateway box. Its
  startupProbe (`wg show wg0`) keeps Traefik from starting before the tunnel is up; its
  livenessProbe restarts it if the last handshake is older than 3 minutes.
- **One replica, `Recreate`.** Two pods would both claim peer 10.8.0.3 and fight over the
  endpoint.
- **`AllowedIPs = 10.8.0.1/32`**, not the `0.0.0.0/0` that wg-easy hands out — otherwise every
  egress packet from the pod (including to cluster Services) is routed to the VPS.
- **`MTU = 1380`**: the WireGuard packets leave through flannel's vxlan (MTU 1450).
- **`PersistentKeepalive = 25`**: home is behind NAT; the VPS can only reach the pod after the
  pod has spoken.
- **`forwardedHeaders.trustedIPs = 10.8.0.1/32`** on `web`: the VPS SNATs into the tunnel, so
  every request arrives from 10.8.0.1. Trusting it passes `X-Forwarded-Proto: https` and the
  real client in `X-Forwarded-For` to the apps (takuteku's `trust proxy`, Keycloak
  `KC_PROXY_HEADERS=xforwarded`).
- **`livekit` UDP entrypoint with `udp.timeout=60s`**: the default 3 s would tear down WebRTC
  sessions between keepalives.
- **`ingressEndpoint.ip = 51.44.40.82`**: without an address in `status.loadBalancer`, ArgoCD
  reports every Ingress — and so every app — as `Progressing` forever.
- **Mail entrypoints `smtp` 2525, `submissions` 4465, `submission` 5587, `imaps` 9993** with
  `proxyProtocol.trustedIPs = 10.8.0.1/32` and `readTimeout=0`: the VPS sends PROXY v2 over the
  tunnel, and `email-cd`'s IngressRouteTCPs pass it on to Stalwart with a `ServersTransportTCP`.
- **`allowExternalNameServices: true`**: `lightchat/media` is an ExternalName Service for
  `s3.lan` (Garage). ArgoCD excludes `Endpoints`/`EndpointSlice` from sync by default, so a
  selectorless Service with a hand-written EndpointSlice silently never gets its endpoints.

## Publishing a service

Add a rule to the namespace's `Ingress` in its CD repo (`ingressClassName: traefik`, no
`tls:`). DNS and certificates need nothing — `*.eduindev.com` already points at the VPS and the
wildcard cert covers it.

## Checks

```sh
kubectl -n traefik logs deploy/traefik -c wireguard
kubectl -n traefik exec deploy/traefik -c wireguard -- wg show wg0
kubectl get ingress -A
ssh-my-lightsail 'sudo docker exec wg-easy wg show wg0 latest-handshakes'
```
