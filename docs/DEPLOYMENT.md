# Kasa Collector Deployment Guide

This guide covers deployment scenarios for the Kasa Collector application.

Kasa Collector is maintained by **Luxardo Labs**. Images are published to GitHub Container
Registry as `ghcr.io/luxardolabs/kasa-collector`. Images are multi-arch
(amd64 + arm64).

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Build & Release Model](#build--release-model)
3. [Docker Deployment](#docker-deployment)
4. [Docker Compose Deployment](#docker-compose-deployment)
5. [Remote Production Deploy (Makefile)](#remote-production-deploy-makefile)
6. [Kubernetes Deployment](#kubernetes-deployment)
7. [Docker Swarm Deployment](#docker-swarm-deployment)
8. [Monitoring and Maintenance](#monitoring-and-maintenance)
9. [Troubleshooting](#troubleshooting)

## Prerequisites

### Network Requirements

- **Host Networking**: Required for device discovery (UDP broadcast)
- **Firewall**: Allow UDP port 9999 for Kasa device discovery
- **Same Network**: The collector must be on the same L2 network as the Kasa devices
  (for auto-discovery). Cross-subnet devices can be reached explicitly via
  `KASA_COLLECTOR_DEVICE_HOSTS`.

### InfluxDB Setup

1. Install **InfluxDB 2.x**
2. Create an organization and bucket
3. Generate an API token with write permissions
4. Note the URL, org, bucket, and token

### TP-Link Account (Optional)

For newer Kasa devices requiring cloud auth (KLAP, e.g. EP25 hardware 2.6+):

1. Create a TP-Link Kasa account
2. Ensure devices are linked to your account
3. Have username and password ready

### Configuration & Secrets

Configuration is supplied via environment variables (see [`.env.example`](../.env.example)
for the full annotated template). Real values live in **gitignored** `.env.dev` /
`.env.prod` files — only `.env.example` and the demo values in `.env.demo` are committed.
Copy the template and fill it in:

```bash
cp .env.example .env.prod   # edit with your real values
```

## Build & Release Model

The build is **Makefile-driven** and the `VERSION` file at the repo root is the source of
truth for the version. Dependencies are managed with **Poetry** (`pyproject.toml` +
`poetry.lock`), resolved and installed inside Docker — no host Python or Poetry needed.

The local run stacks (`up` / `dev-up` / `demo-up`) build the collector image **locally**
from current source — no registry or push needed. The `release*` targets build and push
multi-arch images that the prod stack and remote deploys pull.

```bash
make help              # list all targets

make build-local       # build the runtime image from current source as a local tag
make release           # multi-arch :VERSION + :latest → private registry
make release-public    # multi-arch :VERSION + :latest → GHCR (public OSS image)
```

Kasa Collector runs as one of four stacks, all of which build the image locally and can
be torn up/down:

| File | Stack | Purpose | Command | Env file |
|------|-------|---------|---------|----------|
| `compose.yml` | collector-only | Just the collector against YOUR external InfluxDB/Grafana | `make up` | `.env.dev` |
| `compose.prod.yml` | collector-only (prod) | Same, prod tuning; also remote deploy | `make prod-*` | `.env.prod` |
| `compose.dev.yml` | dev | Your REAL devices (host networking) + bundled InfluxDB + Grafana | `make dev-up` | `.env.demo` |
| `compose.demo.yml` | demo | FAKE emulated devices + bundled InfluxDB + Grafana (no hardware) | `make demo-up` | `.env.demo` |
| `compose.e2e.yml` | test | Hardware-free end-to-end test (fake devices + ephemeral InfluxDB) | `make test-e2e` | — |

## Docker Deployment

The image reads all configuration from environment variables. The simplest approach is to
point it at an env file, but discrete `-e` flags work too. The container's health check
(`python3 -m app.health.check`) is baked into the image via `HEALTHCHECK`.

### Quick Start (env file)

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  ghcr.io/luxardolabs/kasa-collector:latest
```

### Explicit environment variables

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  -e KASA_COLLECTOR_INFLUXDB_URL="http://influxdb.example.com:8086" \
  -e KASA_COLLECTOR_INFLUXDB_TOKEN="your-token" \
  -e KASA_COLLECTOR_INFLUXDB_ORG="your-org" \
  -e KASA_COLLECTOR_INFLUXDB_BUCKET="kasa" \
  ghcr.io/luxardolabs/kasa-collector:latest
```

### With Authentication (newer devices)

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  -e KASA_COLLECTOR_TPLINK_USERNAME="you@example.com" \
  -e KASA_COLLECTOR_TPLINK_PASSWORD="your-password" \
  ghcr.io/luxardolabs/kasa-collector:latest
```

### With File Output

The output directory is bind-mounted at `/app/output` inside the container:

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  -v /path/to/output:/app/output \
  --env-file .env.prod \
  -e KASA_COLLECTOR_WRITE_TO_FILE="True" \
  ghcr.io/luxardolabs/kasa-collector:latest
```

### Health Check Monitoring

```bash
# Check health status
docker inspect kasa-collector | jq '.[0].State.Health.Status'

# View health check log
docker inspect kasa-collector | jq '.[0].State.Health.Log'

# Run the health check manually
docker exec kasa-collector python3 -m app.health.check
```

## Docker Compose Deployment

The repo ships ready-to-use compose files driven by the Makefile. The recommended path is
to use them directly.

### Using the shipped stacks

```bash
# Dev — full LOCAL stack: your real devices + bundled InfluxDB + Grafana (builds locally)
make dev-up
make dev-logs
make dev-down          # dev-clean also drops the data volumes

# Collector-only — just the collector against YOUR external InfluxDB (edit .env.dev)
make up
make logs
make down

# Prod (pulls :latest, reads .env.prod) — run `make release` first
make prod-up
make prod-logs
make prod-down
```

`compose.prod.yml` is intentionally minimal — it pulls the image, uses host networking,
loads `.env.prod`, and bind-mounts the output directory. The Dockerfile ships a
`HEALTHCHECK`, so no compose-level health check is needed:

```yaml
name: kasa-collector

services:
  kasa-collector:
    container_name: kasa-collector
    image: ghcr.io/luxardolabs/kasa-collector:latest
    env_file:
      - .env.prod
    network_mode: host
    restart: always
    volumes:
      - /mnt/docker/kasa-collector/output:/app/output
```

### Rolling your own compose file

If deploying the public GHCR image on your own host:

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
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.1'
```

### All-in-one demo stack (no hardware)

To evaluate the full pipeline including InfluxDB 2.x and an auto-provisioned Grafana with
zero hardware, the demo stack drives the collector with **fake** emulated Kasa devices:

```bash
make demo-up     # fake devices + InfluxDB + Grafana; Grafana at http://localhost:3000 (admin/admin)
make demo-logs
make demo-down   # stop (keep data)   |   make demo-clean  (stop + drop volumes)
```

Ports 3000 (Grafana) and 8086 (InfluxDB) can be overridden via `GRAFANA_PORT` /
`INFLUX_PORT` in `.env.demo`. To run the same bundled InfluxDB + Grafana against your
**real** Kasa devices instead of fakes, use `make dev-up`.

## Remote Production Deploy (Makefile)

The collector runs on a host with LAN access to the Kasa devices. The Makefile can deploy
to a remote node over SSH. Set `PROD_NODE` explicitly (there is no default).

```bash
# One-time: create the output data dir on the node (owned by appuser, uid 1000)
make prod-init   PROD_NODE=collector01.example.com

# Push compose.prod.yml + .env.prod to the node (repo is the source of truth)
make prod-sync   PROD_NODE=collector01.example.com

# Pull :latest + recreate the collector on the node (run `make release` first)
make prod-deploy PROD_NODE=collector01.example.com

# Operate
make prod-status       PROD_NODE=collector01.example.com
make prod-logs-remote  PROD_NODE=collector01.example.com
make prod-health       PROD_NODE=collector01.example.com   # runs the in-container health check
make prod-rollback     PROD_NODE=collector01.example.com   # list cached image tags for rollback
```

`PROD_USER` (default `root`) and `PROD_DIR` (default `/opt/kasa-collector`) can be
overridden on the command line if needed.

## Kubernetes Deployment

### ConfigMap

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
  KASA_COLLECTOR_DATA_FETCH_INTERVAL: "15"
  KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL: "60"
```

### Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: kasa-collector-secret
type: Opaque
stringData:
  influxdb-token: "your-influxdb-token"
  tplink-username: "you@example.com"
  tplink-password: "your-password"
```

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kasa-collector
  labels:
    app: kasa-collector
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
      hostNetwork: true  # Required for device discovery
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
        - name: KASA_COLLECTOR_TPLINK_USERNAME
          valueFrom:
            secretKeyRef:
              name: kasa-collector-secret
              key: tplink-username
        - name: KASA_COLLECTOR_TPLINK_PASSWORD
          valueFrom:
            secretKeyRef:
              name: kasa-collector-secret
              key: tplink-password
        resources:
          limits:
            memory: "256Mi"
            cpu: "500m"
          requests:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          exec:
            command: ["python3", "-m", "app.health.check"]
          initialDelaySeconds: 30
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          exec:
            command: ["python3", "-m", "app.health.check"]
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
```

### Deploy to Kubernetes

```bash
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml

# Check status
kubectl get pods -l app=kasa-collector
kubectl logs -l app=kasa-collector -f
```

## Docker Swarm Deployment

### Stack Configuration

Create `kasa-collector-stack.yml`:

```yaml
name: kasa-collector

services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:latest
    networks:
      - host
    environment:
      KASA_COLLECTOR_INFLUXDB_URL: "http://influxdb.example.com:8086"
      KASA_COLLECTOR_INFLUXDB_TOKEN_FILE: "/run/secrets/influxdb_token"
      KASA_COLLECTOR_INFLUXDB_ORG: "your-org"
      KASA_COLLECTOR_INFLUXDB_BUCKET: "kasa"
      KASA_COLLECTOR_TPLINK_USERNAME_FILE: "/run/secrets/tplink_username"
      KASA_COLLECTOR_TPLINK_PASSWORD_FILE: "/run/secrets/tplink_password"
    secrets:
      - influxdb_token
      - tplink_username
      - tplink_password
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3
      update_config:
        parallelism: 1
        delay: 10s
        failure_action: rollback
        monitor: 30s

networks:
  host:
    external: true
    name: host

secrets:
  influxdb_token:
    external: true
  tplink_username:
    external: true
  tplink_password:
    external: true
```

### Deploy Stack

```bash
# Create secrets
echo "your-influxdb-token" | docker secret create influxdb_token -
echo "you@example.com"     | docker secret create tplink_username -
echo "your-password"       | docker secret create tplink_password -

# Deploy stack
docker stack deploy -c kasa-collector-stack.yml kasa

# Check status
docker stack services kasa
docker service logs kasa_kasa-collector -f
```

## Monitoring and Maintenance

### Container Metrics

```bash
docker stats kasa-collector           # CPU / memory
docker inspect kasa-collector         # full detail
docker logs kasa-collector --tail 100 -f
```

### Health Monitoring

```bash
# Health status
docker inspect kasa-collector --format='{{.State.Health.Status}}'

# Health check history
docker inspect kasa-collector --format='{{json .State.Health.Log}}' | jq

# Automated monitoring
while true; do
  STATUS=$(docker inspect kasa-collector --format='{{.State.Health.Status}}')
  if [ "$STATUS" != "healthy" ]; then
    echo "Container unhealthy: $STATUS"
    # Send alert or restart
  fi
  sleep 30
done
```

### Log Management

```yaml
services:
  kasa-collector:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

### Backup Considerations

If using file output:

```bash
# Backup .jsonl files (bind-mounted at /app/output)
tar -czf kasa-backup-$(date +%Y%m%d).tar.gz /path/to/output/
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker logs kasa-collector

# Common issues:
# - Missing required environment variables
# - InfluxDB connection failed
# - Invalid configuration values

# Debug run
docker run -it --rm \
  --network host \
  --env-file .env.prod \
  -e KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG \
  ghcr.io/luxardolabs/kasa-collector:latest
```

### No Devices Discovered

```bash
# Verify host networking
docker inspect kasa-collector | grep -i networkmode   # should show "host"

# For cross-subnet or non-discoverable devices, list them explicitly:
#   KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100,kasa-strip.example.com
```

### `ZoneInfoNotFoundError` on device update

The runtime image installs `tzdata` + `tzdata-legacy` so `python-kasa` can resolve legacy
POSIX timezone names (e.g. `PST8PDT`) used by TP-Link's timezone index. If you build a
custom image, make sure both packages are present.

### Health Check Failures

```bash
# View last health check output
docker inspect kasa-collector | jq '.[0].State.Health.Log[-1].Output'

# Run it manually
docker exec kasa-collector python3 -m app.health.check

# Common causes:
# - No recent data (check fetch intervals / KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE)
# - Process crashed
```

### Performance Issues

```bash
docker stats kasa-collector --no-stream
docker exec kasa-collector env | grep KASA_COLLECTOR

# Adjust intervals if needed (in .env.prod):
#   KASA_COLLECTOR_DATA_FETCH_INTERVAL=30
#   KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL=600
```

## See Also

- [README.md](README.md) — overview, configuration reference, and development workflow
- [TESTING.md](TESTING.md) — unit tests, lint, and the hardware-free e2e harness
