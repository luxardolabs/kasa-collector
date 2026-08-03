"""InfluxDB storage backend for Kasa device metrics.

This module handles all interactions with InfluxDB for storing time-series data
collected from Kasa smart devices. It processes both energy meter (emeter) data
and system information (sysinfo), formatting them appropriately for InfluxDB
storage with proper tagging and field values.

Key features:
    - Connection management with detailed error handling
    - Batch writing with configurable size and flush intervals
    - Data normalization for consistent storage across device models
    - Support for parent devices and child plugs (power strips)
    - Optional local file storage for data backup/debugging
    - Comprehensive error handling with user-friendly messages

Data is stored in two main measurements:
    - emeter: Energy consumption metrics (power, current, voltage, etc.)
    - sysinfo: Device information and status
    - sysinfo_child: Information for individual plugs on power strips
"""

import contextlib
import json
import logging
import os
from datetime import UTC, datetime
from typing import Any

import aiofiles
from influxdb_client.client.exceptions import InfluxDBError
from influxdb_client.client.influxdb_client_async import InfluxDBClientAsync
from influxdb_client.client.write.point import Point
from influxdb_client.client.write_api_async import WriteApiAsync

from app.collector.utils import sanitize_tag
from app.core.config import Config
from app.utils.logging import setup_logger

logger = setup_logger(
    "InfluxDBStorage", Config.KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE
)


class InfluxDBStorage:
    """Manages storage of Kasa device data to InfluxDB.

    This class handles all InfluxDB operations including connection setup,
    data formatting, and writing metrics. It supports both single devices
    and power strips with multiple plugs.

    Attributes:
        logger: Logger instance for this class.
        client: asyncio-native InfluxDB client (opened in ``connect()``).
        write_api: Async write API; points are awaited inline, one batch per cycle.
        bucket: Target InfluxDB bucket name.
        org: Target InfluxDB organization.
        sysinfo_data: Cache of device system information for cross-referencing.
    """

    def __init__(self) -> None:
        """Validate configuration; defer the connection to ``connect()``.

        The asyncio-native client must be created inside a running event loop, so
        construction only checks that the required configuration is present. Call
        ``connect()`` once at startup to actually open the connection.

        Raises:
            ValueError: If required configuration is missing.
        """
        self.logger = logger

        # Validate required config values
        if not Config.KASA_COLLECTOR_INFLUXDB_URL:
            raise ValueError("KASA_COLLECTOR_INFLUXDB_URL is required")
        if not Config.KASA_COLLECTOR_INFLUXDB_TOKEN:
            raise ValueError("KASA_COLLECTOR_INFLUXDB_TOKEN is required")
        if not Config.KASA_COLLECTOR_INFLUXDB_ORG:
            raise ValueError("KASA_COLLECTOR_INFLUXDB_ORG is required")
        if not Config.KASA_COLLECTOR_INFLUXDB_BUCKET:
            raise ValueError("KASA_COLLECTOR_INFLUXDB_BUCKET is required")

        self.client: InfluxDBClientAsync | None = None
        self.write_api: WriteApiAsync | None = None
        # Validated non-None above; narrow to str for the client/write-API signatures.
        self.url: str = Config.KASA_COLLECTOR_INFLUXDB_URL
        self.token: str = Config.KASA_COLLECTOR_INFLUXDB_TOKEN
        self.bucket: str = Config.KASA_COLLECTOR_INFLUXDB_BUCKET
        self.org: str = Config.KASA_COLLECTOR_INFLUXDB_ORG
        # Cache of device sysinfo, keyed by IP, used to cross-reference during emeter processing.
        self.sysinfo_data: dict[str, Any] = {}

    async def connect(self) -> None:
        """Open the asyncio-native InfluxDB connection and verify reachability.

        Uses the aiohttp-based ``InfluxDBClientAsync`` so every write on the hot
        path is awaited on the event loop — no background threads, no Rx batching
        pipeline, nothing to flush on shutdown. Auth/bucket problems surface as
        actionable errors on the first write (see ``send_to_influxdb``); this
        preflight fails fast only on an unreachable or unhealthy server.

        Raises:
            SystemExit: If InfluxDB is unreachable or unhealthy.
        """
        self.client = InfluxDBClientAsync(
            url=self.url,
            token=self.token,
            org=self.org,
            enable_gzip=True,
        )

        try:
            healthy = await self.client.ping()
        except Exception:
            await self._close_client()
            sep = "=" * 60
            # One log event (with the traceback) rather than a 9-line error banner.
            self.logger.exception(
                "\n%s\nInfluxDB Connection Failed\n%s\n"
                "Could not reach InfluxDB at: %s\n"
                "Please verify:\n"
                "  - InfluxDB is running and the URL/port are correct\n"
                "  - No firewall is blocking the connection\n%s",
                sep,
                sep,
                self.url,
                sep,
            )
            raise SystemExit(1) from None

        if not healthy:
            await self._close_client()
            self.logger.error("InfluxDB health check failed at %s", self.url)
            raise SystemExit(1)

        self.write_api = self.client.write_api()
        try:
            server_version = await self.client.version()
            self.logger.info(
                "InfluxDB connection established successfully (server %s)",
                server_version,
            )
        except Exception:
            self.logger.info("InfluxDB connection established successfully")

    async def _close_client(self) -> None:
        """Close the async client if it was opened, ignoring teardown errors."""
        if self.client is not None:
            with contextlib.suppress(Exception):
                await self.client.close()
            self.client = None
            self.write_api = None

    async def write_data(
        self,
        measurement: str,
        data: dict[str, Any],
        tags: dict[str, Any] | None = None,
    ) -> None:
        """Write a single data point to InfluxDB.

        Args:
            measurement: InfluxDB measurement name.
            data: Dictionary of field key-value pairs.
            tags: Optional dictionary of tag key-value pairs.

        Note:
            This is a legacy method. Prefer using process_emeter_data
            or process_sysinfo_data for new code.
        """
        if self.write_api is None:
            return
        point = Point(measurement).time(datetime.now(UTC))
        for k, v in data.items():
            point = point.field(k, v)
        if tags:
            for k, v in tags.items():
                point = point.tag(k, v)

        await self.write_api.write(bucket=self.bucket, org=self.org, record=point)
        self.logger.debug(
            "Wrote data to InfluxDB: %s, Tags: %s, Data: %s", measurement, tags, data
        )

    async def process_emeter_data(self, device_data: dict[str, dict[str, Any]]) -> None:
        """Process energy meter data and write to InfluxDB.

        Args:
            device_data: Dictionary mapping IP addresses to device data
                        containing emeter readings.

        Handles both single devices and power strips with multiple plugs.
        Each emeter metric becomes a separate point with appropriate tags:
        - ip: Device IP address
        - dns_name: Resolved hostname
        - device_alias: User-friendly device name
        - equipment_type: Device type (plug, strip, etc.)
        - device_id: Unique device identifier
        - plug_alias: Name of individual plug (for strips)
        - plug_id: Numeric plug identifier (1, 2, 3...)
        """
        try:
            points = []
            for ip, data in device_data.items():
                emeter_data = data.get("emeter", {})
                alias = sanitize_tag(data.get("alias", "unknown"))
                dns_name = data.get("dns_name", "unknown")
                equipment_type = data.get("equipment_type", "device")

                # Fetch the sysinfo for this device
                sysinfo = self.sysinfo_data.get(ip, {}).get("sysinfo", {})
                device_id = sysinfo.get("deviceId", None)  # Get device_id from sysinfo
                children = sysinfo.get("children", [])

                # Log for sysinfo lookup
                self.logger.debug("Lookup sysinfo for %s: %s", ip, sysinfo)

                # Determine if it's a plug on a power strip
                plug_alias = data.get(
                    "plug_alias", alias
                )  # Default plug alias to device alias
                plug_id = None

                if children:
                    # This is a power strip with child plugs
                    plug_info = self._get_plug_info_from_sysinfo_by_alias(
                        sysinfo, plug_alias
                    )
                    if plug_info:
                        plug_id = plug_info.get(
                            "plug_id", f"{len(children)}"
                        )  # Use numeric plug_id (1, 2, 3, ...)
                        plug_alias = plug_info.get("alias", plug_alias)
                    self.logger.debug(
                        "Found plug_alias=%s, plug_id=%s for ip=%s",
                        plug_alias,
                        plug_id,
                        ip,
                    )

                # Log Device Alias and IDs for debugging
                self.logger.debug("Device Alias: %s, Device ID: %s", alias, device_id)

                for metric, value in emeter_data.items():
                    point = (
                        Point("emeter")
                        .tag("ip", ip)
                        .tag("dns_name", dns_name)
                        .tag("device_alias", alias)
                        .tag("equipment_type", equipment_type)
                    )

                    # Add device_id for all devices if available
                    if device_id:
                        point = point.tag("device_id", device_id)

                    # Add plug-specific tags if this is a plug
                    if plug_id:
                        point = point.tag("plug_alias", sanitize_tag(plug_alias)).tag(
                            "plug_id", plug_id
                        )

                    point = point.field(metric, value)
                    point = point.time(datetime.now(UTC))
                    points.append(point)

            await self.send_to_influxdb(points)
            await self._append_to_file(device_data)

        except Exception as e:
            self.logger.exception("Error processing emeter data for InfluxDB: %s", e)

    def _get_plug_info_from_sysinfo_by_alias(
        self, sysinfo: dict[str, Any], plug_alias: str
    ) -> dict[str, Any] | None:
        """Find plug information by alias in power strip sysinfo.

        Args:
            sysinfo: System information dictionary containing children.
            plug_alias: Alias of the plug to find.

        Returns:
            Dictionary with plug information including assigned numeric
            plug_id, or None if not found.

        Note:
            Assigns sequential plug_ids (1, 2, 3...) based on position
            in the children array.
        """
        children: list[dict[str, Any]] = sysinfo.get("children", [])
        for index, child in enumerate(children):
            if child.get("alias") == plug_alias:
                # Assign plug_id as the index + 1 (1-based index)
                child["plug_id"] = f"{index + 1}"
                return child
        return None

    async def process_sysinfo_data(
        self, device_data: dict[str, dict[str, Any]]
    ) -> None:
        """Process system information data and write to InfluxDB.

        Args:
            device_data: Dictionary mapping IP addresses to device data
                        containing system information.

        Processes both parent devices and child plugs (for power strips).
        Parent device info goes to 'sysinfo' measurement, while child
        plug info goes to 'sysinfo_child' measurement.

        Also caches sysinfo data for use during emeter processing to
        properly associate metrics with device/plug identities.
        """
        try:
            # Store the sysinfo data for later use in emeter processing
            self.sysinfo_data.update(device_data)

            # Log for adding sysinfo data (json.dumps is expensive — only build it at DEBUG)
            if self.logger.isEnabledFor(logging.DEBUG):
                self.logger.debug(
                    "Updated sysinfo data: %s", json.dumps(self.sysinfo_data, indent=4)
                )

            points = []
            for ip, data in device_data.items():
                normalized_sysinfo = self.normalize_sysinfo(data.get("sysinfo", {}))
                device_id = normalized_sysinfo.get("device_id", "unknown")
                alias = sanitize_tag(
                    data.get("device_alias") or data.get("alias") or ip
                )
                self.logger.debug(
                    "Processing sysinfo for IP: %s, Alias: %s, Hostname: %s",
                    ip,
                    alias,
                    data.get("dns_name"),
                )

                # Create a sysinfo point for the parent device
                point = (
                    Point("sysinfo")
                    .tag("ip", ip)
                    .tag("dns_name", data.get("dns_name"))
                    .tag("device_alias", alias)
                    .tag("device_id", device_id)
                )

                for key, value in normalized_sysinfo.items():
                    point = point.field(key, self._format_value(value))

                point = point.time(datetime.now(UTC))
                points.append(point)

                # Process child devices (plugs) and assign sequential plug_id values
                children = normalized_sysinfo.get("children", [])
                for index, child in enumerate(children, start=1):
                    plug_alias = child.get("alias", f"Plug {index}")

                    # Generate sequential plug_id based on the index (1, 2, 3, etc.)
                    plug_id = str(index)

                    child_point = (
                        Point("sysinfo_child")
                        .tag("ip", ip)
                        .tag("dns_name", data.get("dns_name"))
                        .tag("device_alias", alias)
                        .tag("device_id", device_id)
                        .tag("plug_id", plug_id)  # Sequential plug_id (1, 2, 3, etc.)
                        .tag("plug_alias", sanitize_tag(plug_alias))
                    )

                    for key, value in child.items():
                        if key != "id":  # Exclude the original 'id' field
                            child_point = child_point.field(
                                key, self._format_value(value)
                            )

                    child_point = child_point.time(datetime.now(UTC))
                    points.append(child_point)

                self.logger.debug("Full sysinfo data: %s", normalized_sysinfo)

            self.logger.debug("Collected points for InfluxDB: %s", points)
            await self.send_to_influxdb(points)
            await self._append_to_file(device_data)

        except Exception as e:
            self.logger.exception("Error processing sysinfo data for InfluxDB: %s", e)

    def normalize_sysinfo(self, sysinfo: dict[str, Any]) -> dict[str, Any]:
        """Normalize system info for consistent storage across device models.

        Args:
            sysinfo: Raw system information dictionary from device.

        Returns:
            Normalized dictionary with standardized field names.

        Currently handles specific normalizations for:
        - KP125M: Maps fw_ver to sw_ver, device_on to relay_state
        - Other models: Passed through unchanged

        This ensures consistent field names in InfluxDB regardless of
        device model variations.
        """
        normalized = {}
        device_model = sysinfo.get("model", "")

        # Only apply specific transformations for KP125M devices
        if device_model == "KP125M":
            for key, value in sysinfo.items():
                if key == "fw_ver":
                    normalized["sw_ver"] = value
                    self.logger.debug(
                        "Normalized 'fw_ver' to 'sw_ver' with value: %s", value
                    )
                elif key == "device_on":
                    # Normalize 'device_on' to 'relay_state' for KP125M
                    normalized["relay_state"] = 1 if value else 0
                    self.logger.debug(
                        "Normalized 'device_on' to 'relay_state' for KP125M: %s", value
                    )
                else:
                    normalized[key] = value
        else:
            # If not KP125M, retain the sysinfo as-is
            normalized = sysinfo

        return normalized

    async def write_collector_metrics(
        self,
        cycle: str,
        devices: int,
        succeeded: int,
        failed: int,
        duration: float,
    ) -> None:
        """Write the collector's own per-cycle health metrics.

        Emits one point to the ``collector_stats`` measurement so the collector's
        own behaviour — how many devices it polled, how many succeeded/failed, and
        how long the cycle took — is observable in Grafana alongside the device data.

        Args:
            cycle: Which loop produced this ("emeter" or "sysinfo").
            devices: Number of devices attempted this cycle.
            succeeded: Devices polled successfully.
            failed: Devices that failed after retries.
            duration: Wall-clock seconds the cycle took.
        """
        point = (
            Point("collector_stats")
            .tag("cycle", cycle)
            .field("devices", int(devices))
            .field("succeeded", int(succeeded))
            .field("failed", int(failed))
            .field("duration_seconds", float(duration))
            .time(datetime.now(UTC))
        )
        await self.send_to_influxdb([point])

    async def send_to_influxdb(self, points: list[Point]) -> None:
        """Write a batch of points to InfluxDB in a single awaited request.

        Args:
            points: List of Point objects to write.

        The whole list is handed to the async write API as one batched write.
        Errors are logged — with actionable guidance for auth/bucket problems —
        but don't stop the collector; the next cycle simply retries.
        """
        if not points or self.write_api is None:
            return
        try:
            if self.logger.isEnabledFor(logging.DEBUG):
                for point in points:
                    self.logger.debug(
                        "Sending to InfluxDB: %s", point.to_line_protocol()
                    )
            await self.write_api.write(bucket=self.bucket, org=self.org, record=points)
        except InfluxDBError as e:
            self._log_write_error(e)
        except Exception as e:
            self.logger.exception("Error sending data to InfluxDB: %s", e)

    def _log_write_error(self, error: InfluxDBError) -> None:
        """Log an InfluxDB write failure with actionable guidance."""
        status = getattr(getattr(error, "response", None), "status", None)
        if status == 401:
            self.logger.error(
                "InfluxDB rejected the write (401 Unauthorized) — check that "
                "KASA_COLLECTOR_INFLUXDB_TOKEN has write access to bucket "
                "'%s' in org '%s'.",
                self.bucket,
                self.org,
            )
        elif status == 404:
            self.logger.error(
                "InfluxDB write failed (404 Not Found) — bucket '%s' or org '%s' does not exist.",
                self.bucket,
                self.org,
            )
        else:
            self.logger.error("InfluxDB write failed: %s", error)

    async def _append_to_file(self, data: dict[str, dict[str, Any]]) -> None:
        """Append device data to JSON files for debugging/backup.

        Args:
            data: Device data dictionary to write.

        Only writes if KASA_COLLECTOR_WRITE_TO_FILE is enabled.
        Creates separate files for each device and data type:
        - emeter_<device_name>.jsonl: Energy data
        - sysinfo_<device_name>.jsonl: System information

        Files are appended to, not overwritten, creating a historical log.
        """
        try:
            output_dir = Config.KASA_COLLECTOR_OUTPUT_DIR
            os.makedirs(output_dir, exist_ok=True)

            for ip, device_data in data.items():
                alias = (
                    device_data.get("alias") or device_data.get("device_alias") or ip
                )
                dns_name = device_data.get("dns_name", "")
                identifier = alias or dns_name or ip
                sanitized_identifier = "".join(
                    c if c.isalnum() or c in "-_." else "_" for c in identifier
                )
                file_type = "emeter" if "emeter" in device_data else "sysinfo"
                filename = os.path.join(
                    output_dir, f"{file_type}_{sanitized_identifier}.jsonl"
                )

                # Newline-delimited JSON (.jsonl): one compact object per line, appended.
                async with aiofiles.open(filename, "a") as f:
                    await f.write(json.dumps({ip: device_data}) + "\n")
                    self.logger.debug(
                        "Appended %s data to JSONL file: %s", file_type, filename
                    )

        except Exception as e:
            self.logger.exception("Error writing data to file: %s", e)

    def _format_value(self, value: Any) -> Any:
        """Format values for InfluxDB field compatibility.

        Args:
            value: Value to format.

        Returns:
            Formatted value suitable for InfluxDB fields.

        Handles:
        - Primitives: Passed through unchanged
        - Lists: Converted to comma-separated strings
        - Other: Converted to strings
        """
        if isinstance(value, (int, float, str, bool)):
            return value
        elif isinstance(value, list):
            return ",".join(map(str, value))
        return str(value)

    async def close(self) -> None:
        """Close the InfluxDB connection.

        Should be called during application shutdown. With the async client there
        is no background write buffer to flush — every cycle's points are awaited
        inline — so this just releases the aiohttp session.
        """
        await self._close_client()
