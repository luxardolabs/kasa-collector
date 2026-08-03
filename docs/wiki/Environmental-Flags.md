# Environmental Flags

Kasa Collector can be configured with the following environment variables.

> **Note**: Version 2025.7.0 added several new operational timeout configurations for improved reliability and resource management. These are marked with "(Added in v2025.7.0)" below.

## Required Variables

### InfluxDB Configuration

- **`KASA_COLLECTOR_INFLUXDB_URL`**: InfluxDB instance URL

  - Example: `http://influxdb.example.com:8086`
  - Required for data storage

- **`KASA_COLLECTOR_INFLUXDB_TOKEN`**: InfluxDB token for authentication

  - Example: `your-influxdb-token`
  - Must have write permissions to the bucket

- **`KASA_COLLECTOR_INFLUXDB_ORG`**: Organization name for InfluxDB

  - Example: `MyOrg`
  - Must match your InfluxDB organization

- **`KASA_COLLECTOR_INFLUXDB_BUCKET`**: InfluxDB bucket name for data storage

  - Example: `kasa`
  - Bucket must exist or token must have permissions to create it

## Optional Variables

### Device Discovery

- **`KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY`**: Enable automatic device discovery

  - Default: `true`
  - Values: `true/false`, `yes/no`, `1/0`, `on/off`
  - When disabled, only manual devices are monitored

- **`KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL`**: Device discovery frequency (seconds)

  - Default: `300` (5 minutes)
  - How often to scan for new devices

- **`KASA_COLLECTOR_DISCOVERY_TIMEOUT`**: Device discovery timeout (seconds)

  - Default: `5`
  - Maximum time to wait for device responses

- **`KASA_COLLECTOR_DISCOVERY_PACKETS`**: Number of discovery packets

  - Default: `3`
  - More packets increase discovery reliability

- **`KASA_COLLECTOR_KEEP_MISSING_DEVICES`**: Keep devices that stop responding

  - Default: `true`
  - When false, removes devices that don't respond to discovery

### Data Collection

- **`KASA_COLLECTOR_DATA_FETCH_INTERVAL`**: Device energy data polling interval (seconds)

  - Default: `15`
  - How often to collect power/energy data

- **`KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL`**: System information fetch interval (seconds)

  - Default: `60`
  - How often to collect device status and info

- **`KASA_COLLECTOR_FETCH_MAX_RETRIES`**: Maximum device data fetch retries

  - Default: `5`
  - Number of retry attempts for failed data collection

- **`KASA_COLLECTOR_FETCH_RETRY_DELAY`**: Delay between fetch retries (seconds)

  - Default: `1`
  - Initial delay (uses exponential backoff)

- **`KASA_COLLECTOR_MAX_RETRY_DELAY`**: Maximum retry delay (seconds)

  - Default: `60`
  - Caps exponential backoff to prevent excessive delays

### Authentication

- **`KASA_COLLECTOR_TPLINK_USERNAME`**: TP-Link account username

  - Default: None
  - Required for newer devices (KP125M, etc.)

- **`KASA_COLLECTOR_TPLINK_PASSWORD`**: TP-Link account password

  - Default: None
  - Required for newer devices

- **`KASA_COLLECTOR_AUTH_MAX_RETRIES`**: Maximum authentication retries

  - Default: `3`
  - Attempts before giving up on a device

- **`KASA_COLLECTOR_AUTH_TIMEOUT`**: Authentication timeout (seconds)

  - Default: `10`
  - Maximum time for device authentication

### Manual Device Configuration

- **`KASA_COLLECTOR_DEVICE_HOSTS`**: Manual device IP addresses
  - Default: None
  - Example: `"192.168.1.100,192.168.1.101,kasa-plug.local"`
  - Comma-separated list of IPs or hostnames

### File Output

- **`KASA_COLLECTOR_WRITE_TO_FILE`**: Write polled device data to newline-delimited JSON (`.jsonl`) files

  - Default: `false`
  - Values: `true/false`, `yes/no`, `1/0`, `on/off`
  - Useful for debugging

- **`KASA_COLLECTOR_OUTPUT_DIR`**: Directory for output files

  - Default: `output`
  - Where `.jsonl` files are saved (if enabled)

### Logging

- **`KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR`**: Main application log level

  - Default: `INFO`
  - Values: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`

- **`KASA_COLLECTOR_LOG_LEVEL_KASA_API`**: Device API log level

  - Default: `INFO`
  - Set to `DEBUG` for detailed device communication logs

- **`KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE`**: Storage log level

  - Default: `INFO`
  - Set to `DEBUG` for detailed InfluxDB operations

### Operational Timeouts (Added in v2025.7.0)

- **`KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT`**: Transport cleanup timeout (seconds)

  - Default: `5`
  - Maximum time to clean up network connections
  - Prevents connection leaks during device disconnection

- **`KASA_COLLECTOR_SHUTDOWN_TIMEOUT`**: Graceful shutdown timeout (seconds)

  - Default: `10`
  - Maximum time to wait for tasks to complete during shutdown
  - Ensures clean container stop without hanging

- **`KASA_COLLECTOR_DNS_CACHE_TTL`**: DNS cache time-to-live (seconds)

  - Default: `300` (5 minutes)
  - How long to cache hostname lookups
  - Set to `0` to disable caching
  - Reduces DNS queries for better performance

### Health Check

- **`KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`**: Maximum data file age (seconds)
  - Default: `120`
  - Files older than this are considered stale
  - Used by Docker health check

### Timezone

- **`TZ`**: Container timezone
  - Default: `UTC`
  - Example: `America/Chicago`
  - Affects log timestamps

## Example Configuration

### Docker Compose

```yaml
services:
  kasa-collector:
    image: ghcr.io/luxardolabs/kasa-collector:latest
    environment:
      # Required
      KASA_COLLECTOR_INFLUXDB_URL: http://influxdb:8086
      KASA_COLLECTOR_INFLUXDB_TOKEN: your-token-here
      KASA_COLLECTOR_INFLUXDB_ORG: MyOrg
      KASA_COLLECTOR_INFLUXDB_BUCKET: kasa
      
      # Optional - Discovery
      KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY: "true"
      KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL: "300"
      
      # Optional - Data Collection
      KASA_COLLECTOR_DATA_FETCH_INTERVAL: "15"
      KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL: "60"
      
      # Optional - Authentication (for newer devices)
      KASA_COLLECTOR_TPLINK_USERNAME: "user@example.com"
      KASA_COLLECTOR_TPLINK_PASSWORD: "password"
      
      # Optional - Logging
      KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR: "INFO"
      
      # Optional - Timezone
      TZ: "America/Chicago"
    network_mode: host
    restart: unless-stopped
```

### Environment File (.env)

```bash
# Required
KASA_COLLECTOR_INFLUXDB_URL=http://influxdb:8086
KASA_COLLECTOR_INFLUXDB_TOKEN=your-token-here
KASA_COLLECTOR_INFLUXDB_ORG=MyOrg
KASA_COLLECTOR_INFLUXDB_BUCKET=kasa

# Optional
KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=true
KASA_COLLECTOR_DATA_FETCH_INTERVAL=15
KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=INFO
```

## Notes

- Boolean values accept multiple formats for convenience
- All intervals are in seconds
- Log levels must be valid Python logging levels
- Manual device IPs override auto-discovery for those specific devices
- File output is primarily for debugging and development
