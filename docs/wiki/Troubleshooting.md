# Troubleshooting

## Common Issues and Solutions

### Authentication Errors

#### "Server response doesn't match our challenge"
This error occurs when devices require TP-Link cloud credentials.

**Solution:**
Set the following environment variables:
```bash
KASA_COLLECTOR_TPLINK_USERNAME=your-email@example.com
KASA_COLLECTOR_TPLINK_PASSWORD=your-password
```

#### InfluxDB Authentication Failed
Clear error messages will guide you:
```
InfluxDB Authentication Failed
The provided InfluxDB credentials are invalid.

Please verify the following environment variables:
  - KASA_COLLECTOR_INFLUXDB_TOKEN
  - KASA_COLLECTOR_INFLUXDB_ORG
  - KASA_COLLECTOR_INFLUXDB_URL

Make sure your token has write access to the bucket.
```

### Connection Issues

#### "Connection reset by peer"
Device is discovered but refuses connections.

**Possible causes:**
1. Device needs a power cycle
2. Network congestion from too many simultaneous connections
3. Device firmware issue
4. Firewall blocking TCP port 9999

**Solutions:**
- Power cycle the affected device
- Check if device works in Kasa app
- Reduce discovery interval to spread out connections
- Verify no firewall rules blocking port 9999

#### "Device appears to be discovered but not connectable"
Device responds to UDP discovery but TCP connection fails.

**Common reasons:**
- Device on different VLAN
- Firewall rules between networks
- Device in bad state

**Solutions:**
- Ensure collector and devices are on same network/VLAN
- Check firewall rules allow TCP 9999
- Power cycle the device

### Discovery Issues

#### No devices discovered
If auto-discovery finds 0 devices:

1. **Verify network mode:**
   ```yaml
   network_mode: host  # Required for discovery
   ```

2. **Check discovery is enabled:**
   ```bash
   KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=true
   ```

3. **Ensure devices are on same network**

4. **Try manual device configuration:**
   ```bash
   KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100,192.168.1.101
   ```

### Performance Issues

#### High log volume
The collector shows device details on first run, then reduces logging.

**To reduce further:**
```bash
KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=WARNING
KASA_COLLECTOR_LOG_LEVEL_KASA_API=WARNING
```

#### Slow discovery
Discovery taking too long with many devices.

**Solutions:**
- Increase discovery timeout: `KASA_COLLECTOR_DISCOVERY_TIMEOUT=10`
- Reduce discovery packets: `KASA_COLLECTOR_DISCOVERY_PACKETS=1`

### Data Collection Issues

#### Missing data points
If data collection is intermittent:

1. **Check intervals make sense:**
   - Energy data: `KASA_COLLECTOR_DATA_FETCH_INTERVAL=15`
   - System info: `KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL=60`

2. **Enable debug logging:**
   ```bash
   KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR=DEBUG
   ```

3. **Check for warnings about slow fetches**

#### Child plug data not appearing
For power strips, ensure you're querying the correct measurement:
- Parent strip: `emeter` measurement
- Child plugs: `emeter` measurement with `plug_alias` tag
- Child state: `sysinfo_child` measurement

### Docker Health Check

#### Container shows unhealthy
The health check monitors data file freshness (no web server required as of v2025.7.0).

**Check:**
```bash
docker inspect kasa-collector | jq '.[0].State.Health'
```

**Adjust threshold if needed:**
```bash
KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE=180  # Default: 120 seconds
```

### Connection Cleanup Issues (Fixed in v2025.7.0)

If you're experiencing connection leaks or transport errors:

**Timeout configurations to adjust:**
```bash
KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT=10  # Default: 5 seconds
KASA_COLLECTOR_SHUTDOWN_TIMEOUT=15           # Default: 10 seconds
```

### DNS Performance (v2025.7.0+)

The collector now caches DNS lookups to improve performance.

**To adjust DNS caching:**
```bash
KASA_COLLECTOR_DNS_CACHE_TTL=600  # Default: 300 seconds (5 minutes)
KASA_COLLECTOR_DNS_CACHE_TTL=0    # Disable DNS caching
```

**If experiencing DNS issues:**
- Disable caching temporarily to test
- Check if device hostnames are changing frequently
- Verify DNS server response times

### Timezone Errors

#### "ZoneInfoNotFoundError" or a crash while updating a device
python-kasa resolves each device's timezone via `zoneinfo`, and TP-Link's
timezone index uses **legacy POSIX zone names** (for example `PST8PDT`,
`CST6CDT`, `EST5EDT`). If the runtime image is missing these legacy names, a
device update can raise `ZoneInfoNotFoundError` and crash the collection cycle.

**Solution:**
Current images ship both `tzdata` and `tzdata-legacy`, which provide the legacy
zone names, so this is fixed out of the box. If you see this error, make sure you
are running a current `luxardolabs/kasa-collector` image rather than an older or
custom build that strips `tzdata-legacy`.

### Error Messages

#### "malformed JSON, retrying"
Device returned invalid data. The collector will automatically retry.

**If persistent:**
- Device firmware may need update
- Try power cycling the device

### Debugging Tips

1. **Enable file output for debugging:**
   ```bash
   KASA_COLLECTOR_WRITE_TO_FILE=true
   KASA_COLLECTOR_OUTPUT_DIR=/path/to/debug
   ```

2. **Check device capabilities:**
   Look in debug `.jsonl` files for device details

3. **Monitor in real-time:**
   ```bash
   docker logs -f kasa-collector
   ```

4. **Test specific device:**
   ```bash
   KASA_COLLECTOR_DEVICE_HOSTS=192.168.1.100
   KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY=false
   ```

### Getting Help

If issues persist:

1. Check [GitHub Issues](https://github.com/luxardolabs/kasa-collector/issues)
2. Enable debug logging and collect logs
3. Note your device models and firmware versions
4. Open a new issue with:
   - Configuration (redact sensitive data)
   - Error messages
   - Device information
   - Network setup (VLANs, etc.)