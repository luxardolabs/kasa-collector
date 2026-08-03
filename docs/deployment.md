# Deployment

Kasa Collector is maintained by **Luxardo Labs** and published to the GitHub Container Registry as [`ghcr.io/luxardolabs/kasa-collector`](https://github.com/luxardolabs/kasa-collector/pkgs/container/kasa-collector). Images are multi-arch (`linux/amd64` + `linux/arm64`), so the same tag runs on x86 servers and ARM boards (Raspberry Pi, Apple silicon) alike.

This guide covers running the collector in production against your own InfluxDB and Grafana. If you just want to see the whole pipeline working with no hardware, start with the demo stack (`make demo-up`) — see [testing.md](testing.md). For all configuration options, see [configuration.md](configuration.md); for dashboards, [grafana-dashboards.md](grafana-dashboards.md).

## Prerequisites

### Network

- **Host networking is required.** Device discovery relies on UDP broadcast on port 9999, which only works when the container shares the host's network namespace (`--network host` / `network_mode: host`).
- The collector must sit on the **same L2 network** as your Kasa devices for auto-discovery. Devices on other subnets (or that don't answer broadcast) can be reached explicitly with `KASA_COLLECTOR_DEVICE_HOSTS`.

### InfluxDB

1. Run **InfluxDB 2.x**.
1. Create an organization and a bucket.
1. Generate an API token with write access to that bucket.
1. Note the URL, org, bucket, and token — these become the `KASA_COLLECTOR_INFLUXDB_*` variables.

The bundled stacks provision InfluxDB for you. To use your own 2.x server with the shipped dashboards, see [Using your own external InfluxDB 2.x](#using-your-own-external-influxdb-2x) below.

### TP-Link account (optional)

Newer Kasa devices require cloud authentication (KLAP, e.g. EP25 hardware 2.6+). For those, create a TP-Link Kasa account, link the devices to it, and supply `KASA_COLLECTOR_TPLINK_USERNAME` / `KASA_COLLECTOR_TPLINK_PASSWORD`. Older devices need no credentials. See [supported-devices.md](supported-devices.md).

### Configuration & secrets

All configuration is via environment variables. The annotated template is [`.env.example`](../.env.example). Real values live in **gitignored** `.env.prod` (production) and `.env.dev` (local); only `.env.example` and the bundled-stack defaults in `.env.demo` are committed.

```bash
cp .env.example .env.prod   # then edit with your real values
```

## Pulling the image

```bash
docker pull ghcr.io/luxardolabs/kasa-collector:latest
# or pin a release
docker pull ghcr.io/luxardolabs/kasa-collector:2026.8.0
```

`:latest` tracks the newest release; pin the version tag (`:2026.8.0`) for reproducible deploys.

## Collector-only deployment

The production shape is the collector on its own, pointed at your external InfluxDB and Grafana. The repo ships `compose.prod.yml` for exactly this. **Compose never builds** — the Makefile builds and pushes the image, and the stack pulls it. The Dockerfile bakes in a `HEALTHCHECK` (`python -m app.health.check`), so no compose-level health check is needed.

`compose.prod.yml` is intentionally minimal:

```yaml
name: kasa-collector

services:
  kasa-collector:
    container_name: kasa-collector
    image: ${KASA_IMAGE:-ghcr.io/luxardolabs/kasa-collector:latest}
    env_file:
      - .env.prod
    network_mode: host
    restart: always
    volumes:
      - /mnt/docker/kasa-collector/output:/app/output
```

Run it locally against `.env.prod` with the Makefile:

```bash
make prod-up      # docker compose pull && up -d  (compose.prod.yml, .env.prod)
make prod-logs
make prod-ps
make prod-down
```

### Rolling your own compose file

If you deploy the public image on your own host without the repo, a self-contained file works too:

```yaml
services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:latest
    container_name: kasa-collector
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env.prod
    volumes:
      - ./output:/app/output
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
        reservations:
          memory: 128M
          cpus: "0.1"
```

### Plain `docker run`

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  ghcr.io/luxardolabs/kasa-collector:latest
```

To persist raw readings as `.jsonl`, set `KASA_COLLECTOR_WRITE_TO_FILE=True` and bind-mount `/app/output`:

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  -e KASA_COLLECTOR_WRITE_TO_FILE=True \
  -v /path/to/output:/app/output \
  ghcr.io/luxardolabs/kasa-collector:latest
```

## Remote production deploy (Makefile)

The collector must run on a host with LAN access to the Kasa devices. The Makefile can deploy to a remote node over SSH. There is **no default node** — set `PROD_NODE` on every remote target.

```bash
# One-time: create the output data dir on the node (owned by appuser, uid 1000)
make prod-init   PROD_NODE=collector01.example.com

# Push compose.prod.yml + .env.prod to the node (the repo is the source of truth)
make prod-sync   PROD_NODE=collector01.example.com

# Pull :latest + recreate the collector on the node (run `make release` first)
make prod-deploy PROD_NODE=collector01.example.com

# Operate
make prod-status       PROD_NODE=collector01.example.com   # container status
make prod-logs-remote  PROD_NODE=collector01.example.com   # tail + follow logs
make prod-health       PROD_NODE=collector01.example.com   # run the in-container health check
make prod-rollback     PROD_NODE=collector01.example.com   # list image tags cached on the node
```

`PROD_USER` (default `root`) and `PROD_DIR` (default `/opt/kasa-collector`) can be overridden on the command line. A typical first deploy is `prod-init` → `prod-sync` → `prod-deploy`; subsequent releases are just `prod-deploy` (or `prod-sync` first if the config changed).

## Release flow

The build is Makefile-driven and the `VERSION` file at the repo root is the source of truth. Dependencies are managed with Poetry, resolved and installed inside Docker — no host Python or Poetry required.

```bash
make release          # multi-arch :VERSION + :latest -> the private registry (prod pulls :latest)
make release-public   # promote the released :VERSION + :latest (same digest) -> GHCR
```

`make release` builds the runtime image for both architectures and pushes `:VERSION` and `:latest` to the private registry that `prod-deploy` pulls from. `make release-public` re-tags that exact digest onto `ghcr.io/luxardolabs/kasa-collector` for the public OSS image — run `make release` first. To roll out a new version to a node: `make release` → `make prod-deploy PROD_NODE=<host>`.

## Health checks

The image ships a `HEALTHCHECK` that runs `python -m app.health.check`. It reports unhealthy when the process has stopped writing or no fresh data has landed within `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`. No web server or extra port is involved.

```bash
# Status and history
docker inspect kasa-collector --format='{{.State.Health.Status}}'
docker inspect kasa-collector --format='{{json .State.Health.Log}}' | jq

# Run it manually (inside the container)
docker exec kasa-collector python -m app.health.check
```

## Resource sizing

The collector is lightweight — a single async process polling energy meters (every 15s by default) and system info (every 60s). The limits in the compose example above are generous headroom for a few dozen devices:

- **Memory:** 256M limit / 128M reservation.
- **CPU:** 0.5 limit / 0.1 reservation.

Large fleets or very short poll intervals can raise these; low-power boards can lower them. Cap log growth with the `json-file` driver (`max-size` / `max-file`).

## Kubernetes

Host networking is required, so run one replica per node that can see the devices. Store the InfluxDB token and any TP-Link credentials in a `Secret`.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kasa-collector-config
data:
  KASA_COLLECTOR_INFLUXDB_URL: "http://influxdb.monitoring.svc.cluster.local:8086"
  KASA_COLLECTOR_INFLUXDB_ORG: "your-org"
  KASA_COLLECTOR_INFLUXDB_BUCKET: "kasa"
  KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY: "True"
---
apiVersion: v1
kind: Secret
metadata:
  name: kasa-collector-secret
type: Opaque
stringData:
  influxdb-token: "your-influxdb-token"
  tplink-username: "you@example.com"
  tplink-password: "your-password"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kasa-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kasa-collector
  template:
    metadata:
      labels:
        app: kasa-collector
    spec:
      hostNetwork: true # required for device discovery
      containers:
        - name: kasa-collector
          image: ghcr.io/luxardolabs/kasa-collector:latest
          envFrom:
            - configMapRef:
                name: kasa-collector-config
          env:
            - name: KASA_COLLECTOR_INFLUXDB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: kasa-collector-secret
                  key: influxdb-token
          resources:
            limits: { memory: "256Mi", cpu: "500m" }
            requests: { memory: "128Mi", cpu: "100m" }
          livenessProbe:
            exec:
              command: ["python", "-m", "app.health.check"]
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
```

## Using your own external InfluxDB 2.x

The shipped Grafana dashboards query with **InfluxQL**. On InfluxDB 2.x, InfluxQL is served through the v1-compatibility API, which needs a **DBRP mapping** (a v1 "database" + retention policy that resolves to your bucket). The bundled stack creates this automatically via [`ops/influxdb/init-dbrp.sh`](../ops/influxdb/init-dbrp.sh); on your own server, create it once:

```bash
# Find the bucket id
influx bucket list --org <org> --name <bucket>

# Map a v1 database named after the bucket -> the bucket
influx v1 dbrp create \
  --org <org> \
  --db <bucket> \
  --rp autogen --default \
  --bucket-id <id>
```

Then in Grafana, add an **InfluxDB** datasource in **InfluxQL** mode:

- **URL:** your InfluxDB 2.x address (e.g. `http://influxdb:8086`).
- **Database:** the bucket name (the v1 database you just mapped).
- **Auth:** add a custom HTTP header `Authorization: Token <your-token>` (InfluxDB 2.x's v1-compat API authenticates via a token header, not v1 user/password).

Point the collector at the same server with the `KASA_COLLECTOR_INFLUXDB_*` variables, then import the dashboards — see [grafana-dashboards.md](grafana-dashboards.md).

## Troubleshooting

**No devices discovered** — confirm host networking (`docker inspect kasa-collector | grep -i networkmode` should show `host`). For cross-subnet or non-broadcasting devices, list them explicitly: `KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100,kasa-strip.example.com`.

**`ZoneInfoNotFoundError` on device update** — the runtime image installs `tzdata` + `tzdata-legacy` so `python-kasa` can resolve legacy POSIX timezone names (e.g. `PST8PDT`, `CST6CDT`) from TP-Link's timezone index. If you build a custom image, keep both packages.

**Health check failing** — usually no recent data. Check the fetch intervals and `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`, and inspect `docker inspect kasa-collector | jq '.[0].State.Health.Log[-1].Output'`.

**Dashboards empty on your own Grafana** — almost always the missing v1 DBRP mapping or a non-InfluxQL datasource; see [Using your own external InfluxDB 2.x](#using-your-own-external-influxdb-2x) and [grafana-dashboards.md](grafana-dashboards.md).

For a debug run, start the collector in the foreground with verbose logging:

```bash
docker run -it --rm --network host --env-file .env.prod \
  -e KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG \
  ghcr.io/luxardolabs/kasa-collector:latest
```

## See also

- [configuration.md](configuration.md) — full environment-variable reference
- [grafana-dashboards.md](grafana-dashboards.md) — the shipped dashboards and how to import them
- [testing.md](testing.md) — unit tests, lint, and the hardware-free e2e/demo stacks
- [supported-devices.md](supported-devices.md) — device compatibility and authentication
