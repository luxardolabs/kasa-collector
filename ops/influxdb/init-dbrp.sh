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

# Grafana's read-only sign-in: a v1 user with READ on this bucket only. Grafana never gets
# the admin token, because its datasource proxy lets every Grafana user act with the
# datasource's credentials. A failure here never ends the init: the image keeps
# /etc/influxdb2 from a failed setup, so a non-zero exit would leave the volume unable to
# start at all; without the user, only the dashboards are empty. `--password=` keeps a
# password starting with `-` from being read as a flag.
if [ -z "${GRAFANA_INFLUX_PASSWORD:-}" ]; then
  echo "init-dbrp: GRAFANA_INFLUX_PASSWORD unset; Grafana's datasource will not sign in"
elif influx v1 auth create \
  --org "$ORG" \
  --username grafana \
  --password="$GRAFANA_INFLUX_PASSWORD" \
  --read-bucket "$BUCKET_ID"; then
  echo "init-dbrp: created read-only v1 user 'grafana' for bucket '$BUCKET'"
else
  echo "init-dbrp: ERROR: could not create read-only user 'grafana' (influx's reason above; GRAFANA_INFLUX_PASSWORD must be 8 to 72 characters)" >&2
fi
