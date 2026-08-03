#!/bin/sh
# Runs once, after InfluxDB 2.x finishes its initial `setup` (dropped into
# /docker-entrypoint-initdb.d). The Grafana dashboards use InfluxQL, which on
# InfluxDB 2.x is served through the v1-compatibility API and requires a DBRP
# mapping (database + retention policy -> bucket). This creates it so a v1
# "database" named after the bucket resolves to the bucket.
#
# NOTE: during init the influx CLI is auto-configured (active config -> the temp
# setup server with the admin token), so we must NOT pass --host/--token here —
# the entrypoint's temp server is on an internal port, not 8086 yet.
set -e

ORG="${DOCKER_INFLUXDB_INIT_ORG}"
BUCKET="${DOCKER_INFLUXDB_INIT_BUCKET}"

BUCKET_ID=$(influx bucket list --org "$ORG" --name "$BUCKET" --hide-headers | awk '{print $1}')

influx v1 dbrp create \
  --org "$ORG" \
  --db "$BUCKET" \
  --rp autogen --default \
  --bucket-id "$BUCKET_ID"

echo "init-dbrp: mapped v1 database '$BUCKET' -> bucket '$BUCKET' (id $BUCKET_ID)"
