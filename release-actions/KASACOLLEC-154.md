# KASACOLLEC-154: Grafana signs in to the bundled InfluxDB as a read-only user

Breaking for anyone running a bundled stack (local, demo or dev) from an InfluxDB volume that was set up before this release.

The bundled Grafana no longer holds the InfluxDB operator token (`INFLUX_TOKEN`). It signs in as the v1 user `grafana`, which has read access to the one bucket. `ops/influxdb/init-dbrp.sh` creates that user only on InfluxDB's first start, so an existing volume does not have it. Until it is created, Grafana starts but its dashboards are empty. Collection is unaffected.

On each existing bundled stack, once:

1. Add `GRAFANA_INFLUX_PASSWORD=<a password of your own, 8 to 72 characters>` to its env file (`.env.local`, `.env.dev`). `.env.demo` ships one.

1. Restart the stack (`make local-up` / `make demo-up` / `make dev-up`), so both containers get the password.

1. Create the read-only user on that stack's InfluxDB (`kasa_local_influxdb` for local and demo, `kasa_influxdb` for dev). The password is read from the container's environment, never typed:

   ```sh
   docker exec <influx container> sh -c 'influx v1 auth create --org "$DOCKER_INFLUXDB_INIT_ORG" --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" --username grafana --password="$GRAFANA_INFLUX_PASSWORD" --read-bucket "$(influx bucket list --org "$DOCKER_INFLUXDB_INIT_ORG" --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" --name "$DOCKER_INFLUXDB_INIT_BUCKET" --hide-headers | cut -f1)"'
   ```

1. Open a dashboard and check that it shows data.
