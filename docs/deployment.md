# Deployment

Kasa Collector is maintained by **Luxardo Labs** and published to the GitHub Container Registry as [`ghcr.io/luxardolabs/kasa-collector`](https://github.com/luxardolabs/kasa-collector/pkgs/container/kasa-collector). Images are multi-arch (`linux/amd64` + `linux/arm64`), so the same tag runs on x86 servers and ARM boards (Raspberry Pi, Apple silicon) alike.

This guide covers running the collector in production against your own InfluxDB and Grafana. If you just want to see the whole pipeline working with no hardware, start with the demo stack (`make demo-up`) — see [testing.md](testing.md). For all configuration options, see [configuration.md](configuration.md); for dashboards, [grafana-dashboards.md](grafana-dashboards.md).

## Prerequisites

### Network

- **Host networking is required.** Device discovery relies on UDP broadcast on ports 9999 (IOT devices) and 20002 and 20004 (SMART/KLAP devices), which reaches your LAN only when the container shares the host's network namespace (`--network host` / `network_mode: host`).
- The collector must sit on the **same L2 network** as your Kasa devices for auto-discovery. Devices on other subnets (or that don't answer broadcast) can be reached explicitly with `KASA_COLLECTOR_DEVICE_HOSTS`.

### InfluxDB

1. Run **InfluxDB 2.x**.
1. Create an organization and a bucket.
1. Generate an API token with write access to that bucket.
1. Note the URL, org, bucket, and token — these become the `KASA_COLLECTOR_INFLUXDB_*` variables.

The bundled stacks provision InfluxDB for you. To use your own 2.x server with the shipped dashboards, see [Using your own external InfluxDB 2.x](#using-your-own-external-influxdb-2x) below.

### TP-Link account (optional)

Newer Kasa devices require cloud authentication (KLAP, e.g. EP25 hardware 2.6+). For those, create a TP-Link Kasa account, link the devices to it, and supply `KASA_COLLECTOR_TPLINK_USERNAME` / `KASA_COLLECTOR_TPLINK_PASSWORD`. Older devices need no credentials. With auto-discovery on, the credentials go to every SMART/KLAP device that answers discovery unless you set `KASA_COLLECTOR_TRUST_DISCOVERED_DEVICES=False` and list your devices in `KASA_COLLECTOR_DEVICE_HOSTS` (see [configuration.md](configuration.md#authentication-tp-link)). See [supported-devices.md](supported-devices.md).

### Configuration & secrets

All configuration is via environment variables. The annotated template is [`.env.example`](../.env.example). Real values live in **gitignored** `.env.prod` (production), `.env.local` (`make local-up` on your machine) and `.env.dev` (the maintainers' dev host); only `.env.example`, `.env.dev.local.example` and the bundled-stack defaults in `.env.demo` are committed.

```bash
cp .env.example .env.prod   # then edit with your real values, and set ENV_FILE=.env.prod
```

## Pulling the image

```bash
docker pull ghcr.io/luxardolabs/kasa-collector:2026.11.1
```

Pin a version tag for anything you deploy: a deployable does not roll, so you always know which bits you run and can roll back to them. `:latest` is for a quick try-out: it moves to each new release when that release is published.

## Collector-only deployment

The production shape is the collector on its own, pointed at your external InfluxDB and Grafana. That is the `collector` profile of the single `compose.yml`; `make up` / `make prod-up` name it themselves, so they start the collector alone whatever `.env.prod`'s `COMPOSE_PROFILES` says. Running compose by hand, set `COMPOSE_PROFILES=collector` in `.env.prod`: every service is behind a profile, so an unset value starts nothing, and `bundled` is the maintainers' dev-host pair, which needs that host's network. **Compose never builds** — the Makefile builds and pushes the image, and the stack pulls it by a pinned tag. The Dockerfile bakes in a `HEALTHCHECK` (`python3 -m app.health.check`), and `compose.yml` repeats it with the same timings.

There is ONE compose file for every stack and every environment: the **stack** is a compose profile and the **environment** is the `.env.<env>`.

An abridged excerpt of the collector service (the file also sets its OOM ranking and an optional second env file):

```yaml
services:
  kasa-collector:
    # The stack this service belongs to. Selected by COMPOSE_PROFILES in .env.<env>.
    profiles: [collector]
    container_name: kasa-collector
    logging: *logging # json-file, 5 x 10 MB
    # Pinned, never :latest — a deployable does not roll.
    image: ${REGISTRY:?}/luxardolabs/kasa-collector:${TAG:?}
    env_file:
      - ${ENV_FILE:?}
    network_mode: host
    restart: always
    healthcheck:
      test: ["CMD", "python3", "-m", "app.health.check"]
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    volumes:
      # A named volume by default; a host path in OUTPUT_DIR must be writable by uid 1000.
      - ${OUTPUT_DIR:-kasa_collector_output}:/app/output
```

`.env.prod` supplies the image coordinates alongside the collector's own settings:

```sh
REGISTRY=ghcr.io             # or your private registry
TAG=2026.11.1                # the released version — pinned, never :latest
ENV_FILE=.env.prod
COMPOSE_PROFILES=collector   # the collector alone; required, an unset value starts nothing
# OUTPUT_DIR=/srv/kasa-collector/output   # optional host path for the roster and .jsonl files
```

By default the collector's output directory, which holds `known_devices.json` (the roster of every device it has collected from, probed directly on each discovery round) and any `.jsonl` files, is the named volume `kasa_collector_output`. To keep it on the host, create the directory owned by the container's user before the first start, then set `OUTPUT_DIR` to it: a directory Docker creates for you is owned by root, and the collector (uid 1000) cannot write to it.

```bash
sudo install -d -o 1000 -g 1000 /srv/kasa-collector/output
```

Run it locally against `.env.prod` with the Makefile:

```bash
make prod-up      # docker compose pull && up -d  (compose.yml, .env.prod)
make prod-logs
make prod-ps
make prod-down
```

### Rolling your own compose file

If you deploy the public image on your own host without the repo, a self-contained file works too:

```yaml
services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:2026.11.1
    container_name: kasa-collector
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env.prod
    volumes:
      - kasa_collector_output:/app/output # the device roster and any .jsonl files
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
        reservations:
          memory: 128M
          cpus: "0.1"

volumes:
  kasa_collector_output:
```

### Plain `docker run`

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  -v kasa_collector_output:/app/output \
  --log-opt max-size=10m --log-opt max-file=5 \
  ghcr.io/luxardolabs/kasa-collector:2026.11.1
```

The volume keeps `known_devices.json`, the roster of devices the collector has found, across container recreates. To also persist raw readings as `.jsonl`, set `KASA_COLLECTOR_WRITE_TO_FILE=True`; a host directory in place of the volume must be owned by uid 1000:

```bash
docker run -d \
  --name kasa-collector \
  --network host \
  --restart unless-stopped \
  --env-file .env.prod \
  -e KASA_COLLECTOR_WRITE_TO_FILE=True \
  -v /path/to/output:/app/output \
  ghcr.io/luxardolabs/kasa-collector:2026.11.1
```

## Remote production deploy (Makefile)

The collector must run on a host with LAN access to the Kasa devices. The Makefile can deploy to a remote node over SSH. There is **no default node** — set `PROD_NODE` on every remote target.

```bash
# One-time: create $(PROD_DIR)/output on the node, owned by uid 1000.
# Set OUTPUT_DIR=/opt/kasa-collector/output in .env.prod so the collector mounts it.
make prod-init   PROD_NODE=collector01.example.com

# Push compose.yml + .env.prod to the node (the repo is the source of truth)
make prod-sync   PROD_NODE=collector01.example.com

# Pull the TAG pinned in .env.prod + recreate the collector on the node (run `make release` first)
make prod-deploy PROD_NODE=collector01.example.com

# Operate
make prod-status       PROD_NODE=collector01.example.com   # container status
make prod-logs-remote  PROD_NODE=collector01.example.com   # tail + follow logs
make prod-health       PROD_NODE=collector01.example.com   # run the in-container health check
make prod-rollback     PROD_NODE=collector01.example.com REGISTRY=ghcr.io   # cached tags of <REGISTRY>/luxardolabs/kasa-collector
```

`PROD_USER` (default `root`) and `PROD_DIR` (default `/opt/kasa-collector`) can be overridden on the command line. `prod-rollback` reads the Makefile's `REGISTRY` (from `Makefile.local` or the command line), not the one in `.env.prod`, so pass the registry your node pulls from. A typical first deploy is `prod-init` → `prod-sync` → `prod-deploy`; subsequent releases are just `prod-deploy` (or `prod-sync` first if the config changed).

## Release flow

The build is Makefile-driven and the `VERSION` file at the repo root is the source of truth. Dependencies are managed with Poetry, resolved and installed inside Docker — no host Python or Poetry required.

```bash
V=$(cat VERSION); git tag -a v$V -m v$V && git push origin v$V   # release refuses an untagged HEAD
make release          # multi-arch :VERSION -> the private registry
make release-public   # rescan the released :VERSION, copy that digest -> GHCR, then the GitHub Release
```

The publish targets are luxarch's emitted image block (`luxarch --emit image-block`, enforced by `repo.image_block_wired`), never a hand-written flow. `make release` refuses a dirty working tree (and a failed `git status`), an already-released `VERSION`, a `v<VERSION>` tag at another commit or missing from HEAD, and a missing release-notes file or `gh` login, all before anything is pushed. It then builds the runtime (`production` stage) for every platform in `PLATFORMS` once, pushes it as `:candidate-<commit>`, a tag nothing pins, pulls and scans each platform BY DIGEST (`luxaudit --image-archive`; any fixable HIGH/CRITICAL stops the release), and only then creates the immutable `:VERSION` from that scanned digest with `docker buildx imagetools create`. With `PUBLIC_REGISTRY` set (this repo sets `ghcr.io`), the GitHub Release for `v$(VERSION)` follows the public copy: `make release-public` publishes it from `app/release_notes/$(VERSION).md` after copying the image (`make gh-release` re-runs just that step; it is idempotent). **A git tag is not a Release** — `repo.github_release_wired` enforces it. `.env.prod` pins `TAG=<VERSION>`; nothing pins a moving tag.

`make release-public` copies the RELEASED `:VERSION` to `ghcr.io/luxardolabs/kasa-collector` by digest after rescanning every platform (a CVE published since the release stops it), so the public image is bit-identical to the one released, moves the public `:latest` to it, and then publishes the GitHub Release. It refuses a version GHCR already holds; `make release-public PUBLIC_RESUME=1` finishes a copy that stopped part-way. Every commit's dev build is `make dev-deploy`: `:sha-<commit>` (published once, never rebuilt) plus the `:dev` alias, then `dev-pin` and `smoke`.

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

Large fleets or very short poll intervals can raise these; low-power boards can lower them. The compose stacks already cap each container's log at 5 × 10 MB (`LOG_MAX_SIZE` / `LOG_MAX_FILE`, see [configuration.md](configuration.md#logging)); for a plain `docker run`, pass `--log-opt max-size=10m --log-opt max-file=5` as the example above does.

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
          image: ghcr.io/luxardolabs/kasa-collector:2026.11.1 # pin a release
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
            limits: { memory: "256Mi", cpu: "500m" }
            requests: { memory: "128Mi", cpu: "100m" }
          volumeMounts:
            - name: output # the device roster, kept across pod restarts
              mountPath: /app/output
          livenessProbe:
            exec:
              command: ["python", "-m", "app.health.check"]
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
      volumes:
        - name: output
          hostPath:
            # Create it on the node first, owned by the collector's uid 1000:
            #   sudo install -d -o 1000 -g 1000 /var/lib/kasa-collector/output
            path: /var/lib/kasa-collector/output
            type: Directory
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
- **Auth:** a read-only sign-in, never your write or operator token. Grafana's datasource proxy lends the datasource's credentials to every Grafana user, so a token that can write lets any of them write to or delete the bucket. Create a v1 user with read access to the one bucket (`influx v1 auth create --org <org> --username grafana --password <password> --read-bucket <bucket-id>`) and set it as the datasource's **User** and **Password**. This is what the bundled stacks do (`ops/influxdb/init-dbrp.sh`).

Point the collector at the same server with the `KASA_COLLECTOR_INFLUXDB_*` variables, then import the dashboards — see [grafana-dashboards.md](grafana-dashboards.md).

## Troubleshooting

**No devices discovered** — confirm host networking (`docker inspect kasa-collector | grep -i networkmode` should show `host`). For cross-subnet or non-broadcasting devices, list them explicitly: `KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100,kasa-strip.example.com`.

**`ZoneInfoNotFoundError` on device update** — the runtime image installs `tzdata` + `tzdata-legacy` so `python-kasa` can resolve legacy POSIX timezone names (e.g. `PST8PDT`, `CST6CDT`) from TP-Link's timezone index. If you build a custom image, keep both packages.

**Health check failing** — usually no recent data. Check the fetch intervals and `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`, and inspect `docker inspect kasa-collector | jq '.[0].State.Health.Log[-1].Output'`.

**Dashboards empty on your own Grafana** — almost always the missing v1 DBRP mapping or a non-InfluxQL datasource; see [Using your own external InfluxDB 2.x](#using-your-own-external-influxdb-2x) and [grafana-dashboards.md](grafana-dashboards.md).

For a debug run, start the collector in the foreground with verbose, readable logging (`LOG_FORMAT=text` instead of JSON lines):

```bash
docker run -it --rm --network host --env-file .env.prod \
  -e KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG -e LOG_FORMAT=text \
  ghcr.io/luxardolabs/kasa-collector:2026.11.1
```

## See also

- [configuration.md](configuration.md) — full environment-variable reference
- [grafana-dashboards.md](grafana-dashboards.md) — the shipped dashboards and how to import them
- [testing.md](testing.md) — unit tests, lint, and the hardware-free e2e/demo stacks
- [supported-devices.md](supported-devices.md) — device compatibility and authentication
