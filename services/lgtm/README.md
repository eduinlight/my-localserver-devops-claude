# LGTM Stack (LXC 122)

All-in-one observability backend using [`grafana/otel-lgtm`](https://hub.docker.com/r/grafana/otel-lgtm)
— Grafana + Loki (logs) + Tempo (traces) + Prometheus (metrics, the "M") + Pyroscope
(profiles), fronted by an OpenTelemetry Collector.

- **LXC:** 122 `lgtm`, pool `tools`, 4 cores / 8 GB / 40 GB
- **IP:** 192.168.0.122
- **UI:** http://grafana.lan (via Traefik LXC 114)
- **Compose file on host:** `/home/admin/docker-compose.yaml`

## Endpoints

| Purpose | Address |
|---------|---------|
| Grafana UI | http://grafana.lan (Traefik) or http://192.168.0.122:3000 |
| OTLP gRPC ingest | `otlp.grafana.lan:4317` |
| OTLP HTTP ingest | `http://otlp.grafana.lan:4318` |
| Loki API | `http://loki.grafana.lan:3100` |
| Tempo API | `http://tempo.grafana.lan:3200` |
| Prometheus API | `http://prom.grafana.lan:9090` |
| Pyroscope | `http://192.168.0.122:4040` |

Ingest ports are exposed directly on the LXC rather than through Traefik — OTLP gRPC
needs h2c end to end, and telemetry agents have no reason to go through the proxy.

## Auth

Grafana keeps the image default of **anonymous access with the Admin role**, so the UI
opens without a login. A real admin account also exists (`admin` / `REDACTED`) for API
calls. To require a login, add `GF_AUTH_ANONYMOUS_ENABLED=false` to the compose
environment and recreate the container.

## Sending telemetry

Point any OpenTelemetry SDK/agent at the collector:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otlp.grafana.lan:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=my-service
```

Smoke test:

```sh
curl -X POST -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoketest"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)000000000"'","severityText":"INFO","body":{"stringValue":"hello"}}]}]}]}' \
  http://otlp.grafana.lan:4318/v1/logs
```

## Persistence

Everything (Grafana DB + plugins, Loki chunks, Tempo blocks, Prometheus TSDB, Pyroscope)
lives under `/data` in the container, backed by the named volume `admin_lgtm-data`.
Retention is whatever each component defaults to — no retention policy has been tuned.

## Operations

```sh
ssh root@192.168.0.15
pct exec 122 -- bash -c 'cd /home/admin && docker compose ps'
pct exec 122 -- docker exec lgtm /otel-lgtm/docker/healthcheck.sh
pct exec 122 -- docker logs --tail 50 lgtm
pct exec 122 -- bash -c 'cd /home/admin && docker compose up -d'   # apply changes
```

Docker Hub is blackholed on this network, so `/etc/docker/daemon.json` in the LXC points
at the local pull-through cache `mirror.docker.lan`. Pulling the image without that
mirror will hang.
