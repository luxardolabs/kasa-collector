"""Periodic data collection from Kasa devices.

This module implements the polling logic for collecting data from Kasa smart
devices at regular intervals. It manages two separate polling cycles:
- Energy meter (emeter) data: High-frequency collection (default 15s)
- System information (sysinfo): Low-frequency collection (default 60s)

Key features:
    - Concurrent data collection using TaskGroup for efficiency
    - Automatic retry with exponential backoff for failed operations
    - Performance monitoring and warnings for slow collection cycles
    - Support for both single devices and smart power strips
    - Proper error handling and graceful degradation
    - Integration with InfluxDB storage backend

The poller ensures data collection doesn't exceed configured intervals and
logs warnings when collection takes too long, helping identify performance
issues or problematic devices.
"""

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime, timedelta

from kasa import Device
from kasa.iot import IotStrip

from app.collector.dns_cache import get_hostname_cached
from app.collector.utils import DeviceContext, async_retry
from app.core.config import Config
from app.storage.influxdb import InfluxDBStorage


class Poller:
    """Manages periodic data collection from Kasa devices.

    This class implements the core polling logic, managing separate
    collection cycles for different data types. It handles concurrent
    operations, error recovery, and performance monitoring.

    Attributes:
        logger: Logger instance for this class.
        storage: InfluxDB storage backend for persisting data.
        on_reachable: Optional callback invoked with a device key when it answers.
    """

    # Class-level default so an instance built without __init__ still has it.
    on_reachable: Callable[[str], None] | None = None

    def __init__(
        self,
        logger: logging.Logger,
        on_reachable: Callable[[str], None] | None = None,
    ):
        """Initialize the Poller with storage backend.

        Args:
            logger: Logger instance for logging operations.
            on_reachable: Called with a device's registry key each time that device
                answers a poll. The DeviceManager uses it to avoid pruning a device it
                is still collecting from (KASACOLLEC-70). Optional so the poller stays
                usable standalone.

        Raises:
            SystemExit: If storage backend initialization fails.
        """
        self.logger = logger
        self.on_reachable = on_reachable
        try:
            self.storage = InfluxDBStorage()
        except SystemExit:
            # InfluxDBStorage already logged detailed error messages
            raise
        except Exception as e:
            self.logger.exception("Failed to initialize storage backend: %s", e)
            raise SystemExit(1) from None

    async def connect(self) -> None:
        """Open the storage backend's async connection (called once at startup)."""
        await self.storage.connect()

    async def _fetch_counted(
        self,
        fetch: Callable[[str, Device], Awaitable[bool | None]],
        ip: str,
        device: Device,
        outcome: dict[str, int],
        label: str,
    ) -> None:
        """Run one device fetch, recording the outcome without aborting siblings.

        Per-device failures (after ``async_retry`` is exhausted) are swallowed and
        counted, so a single unreachable device can't cancel the rest of the cycle's
        TaskGroup. The counts feed the per-cycle collector metrics.

        Three outcomes, deliberately distinct (KASACOLLEC-63): the device answered and
        its data was stored (``ok``); the device could not be polled (``failed``); or the
        device answered fine but the write to InfluxDB failed (``write_failed``). The
        third used to be counted as ``ok``, so an InfluxDB outage produced a cycle
        reporting every device as succeeded while nothing landed.
        """
        try:
            stored = await fetch(ip, device)
            # The device ANSWERED. Record that before splitting on whether the write
            # landed: `write_failed` is an InfluxDB problem, not a device problem, and
            # a device that is talking to us must not be pruned as missing.
            if self.on_reachable is not None:
                self.on_reachable(ip)
            if stored is False:
                outcome["write_failed"] += 1
                self.logger.warning(
                    "%s polled %s but the InfluxDB write failed", label, ip
                )
            else:
                outcome["ok"] += 1
        except Exception as e:
            # Deliberately NOT reachable: the fetch raised after retries, so we have no
            # evidence the device is there and must not manufacture any.
            outcome["failed"] += 1
            self.logger.warning("%s failed for %s after retries: %s", label, ip, e)

    async def periodic_emeter_fetch(self, devices: dict[str, Device]) -> None:
        """Continuously collect energy meter data from all devices.

        Args:
            devices: Dictionary mapping IP addresses to device objects.

        Runs indefinitely at intervals defined by KASA_COLLECTOR_DATA_FETCH_INTERVAL.
        Uses TaskGroup for concurrent collection from multiple devices.

        Performance monitoring:
        - Warns if collection takes >80% of interval time
        - Errors if collection exceeds the interval
        - Adjusts sleep time to maintain consistent intervals

        Note:
            This method runs until cancelled. It's designed to be started
            as an asyncio task that runs for the lifetime of the application.
        """
        while True:
            start_time = datetime.now(UTC)
            device_count = len(devices)
            outcome = {"ok": 0, "failed": 0, "write_failed": 0}
            self.logger.debug(
                "Starting emeter data fetch for %s devices.", device_count
            )

            try:
                async with asyncio.TaskGroup() as tg:
                    for ip, device in devices.items():
                        tg.create_task(
                            self._fetch_counted(
                                self.fetch_and_store_emeter_data,
                                ip,
                                device,
                                outcome,
                                "emeter fetch",
                            )
                        )
            except* Exception as eg:
                # Per-device errors are handled/counted in _fetch_counted; this is a
                # safety net for unexpected propagation so one cycle can't kill the loop.
                # CancelledError is a BaseException — it bypasses this and stops the task.
                self.logger.exception(
                    "Unexpected error during emeter fetch: %s",
                    "; ".join(str(err) for err in eg.exceptions),
                )

            end_time = datetime.now(UTC)
            elapsed = (end_time - start_time).total_seconds()

            await self.storage.write_collector_metrics(
                cycle="emeter",
                devices=device_count,
                succeeded=outcome["ok"],
                failed=outcome["failed"],
                write_failed=outcome["write_failed"],
                duration=elapsed,
            )

            # Log a summary of the fetch cycle
            if (
                elapsed > Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL * 0.8
            ):  # Log if taking >80% of interval
                self.logger.warning(
                    "Emeter data fetch completed for %s devices "
                    "in %.2f seconds (approaching interval limit).",
                    device_count,
                    elapsed,
                )
            else:
                self.logger.debug(
                    "Emeter data fetch completed for %s devices in %.2f seconds.",
                    device_count,
                    elapsed,
                )

            if elapsed > Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL:
                self.logger.warning(
                    "Emeter fetch took longer (%.2f seconds) than "
                    "the configured interval of %s seconds.",
                    elapsed,
                    Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL,
                )

            # Calculate the next fetch time and log it
            # Aware UTC, then .astimezone() to the container's zone for DISPLAY — a bare
            # .strftime() on an aware UTC value renders UTC verbatim, it does not convert.
            next_fetch_time = (
                (
                    datetime.now(UTC)
                    + timedelta(
                        seconds=max(
                            0, Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL - elapsed
                        )
                    )
                )
                .astimezone()
                .strftime("%Y-%m-%d %H:%M:%S")
            )
            self.logger.debug("Next emeter data fetch will run at %s.", next_fetch_time)

            # Sleep for the remaining time (if any) before the next cycle
            await asyncio.sleep(
                max(0, Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL - elapsed)
            )

    async def periodic_sysinfo_fetch(self, devices: dict[str, Device]) -> None:
        """Continuously collect system information from all devices.

        Args:
            devices: Dictionary mapping IP addresses to device objects.

        Runs indefinitely at intervals defined by KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL.
        System info includes device model, firmware version, and configuration.

        Performance characteristics:
        - Generally faster than emeter collection
        - Less frequent updates (default 60s vs 15s)
        - Same concurrent collection and monitoring as emeter

        Note:
            This method runs until cancelled. It's designed to be started
            as an asyncio task that runs for the lifetime of the application.
        """
        while True:
            start_time = datetime.now(UTC)
            device_count = len(devices)
            outcome = {"ok": 0, "failed": 0, "write_failed": 0}
            self.logger.debug(
                "Starting system info fetch for %s devices.", device_count
            )

            try:
                async with asyncio.TaskGroup() as tg:
                    for ip, device in devices.items():
                        tg.create_task(
                            self._fetch_counted(
                                self.fetch_and_store_sysinfo,
                                ip,
                                device,
                                outcome,
                                "sysinfo fetch",
                            )
                        )
            except* Exception as eg:
                # Per-device errors are handled/counted in _fetch_counted; this is a
                # safety net for unexpected propagation so one cycle can't kill the loop.
                # CancelledError is a BaseException — it bypasses this and stops the task.
                self.logger.exception(
                    "Unexpected error during sysinfo fetch: %s",
                    "; ".join(str(err) for err in eg.exceptions),
                )

            end_time = datetime.now(UTC)
            elapsed = (end_time - start_time).total_seconds()

            await self.storage.write_collector_metrics(
                cycle="sysinfo",
                devices=device_count,
                succeeded=outcome["ok"],
                failed=outcome["failed"],
                write_failed=outcome["write_failed"],
                duration=elapsed,
            )

            # Log a summary of the fetch cycle
            if (
                elapsed > Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL * 0.8
            ):  # Log if taking >80% of interval
                self.logger.warning(
                    "System info fetch completed for %s devices "
                    "in %.2f seconds (approaching interval limit).",
                    device_count,
                    elapsed,
                )
            else:
                self.logger.debug(
                    "System info fetch completed for %s devices in %.2f seconds.",
                    device_count,
                    elapsed,
                )

            if elapsed > Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL:
                self.logger.warning(
                    "System info fetch took longer (%.2f seconds) than "
                    "the configured interval of %s seconds.",
                    elapsed,
                    Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL,
                )

            # Calculate the next fetch time and log it
            # Aware UTC, then .astimezone() to the container's zone for DISPLAY — a bare
            # .strftime() on an aware UTC value renders UTC verbatim, it does not convert.
            next_fetch_time = (
                (
                    datetime.now(UTC)
                    + timedelta(
                        seconds=max(
                            0, Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL - elapsed
                        )
                    )
                )
                .astimezone()
                .strftime("%Y-%m-%d %H:%M:%S")
            )
            self.logger.debug("Next system info fetch will run at %s.", next_fetch_time)

            # Sleep for the remaining time (if any) before the next cycle
            await asyncio.sleep(
                max(0, Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL - elapsed)
            )

    @async_retry(operation_name="emeter data fetch")
    async def fetch_and_store_emeter_data(self, ip: str, device: Device) -> bool:
        """Fetch and store energy data for a single device.

        Args:
            ip: IP address of the device.
            device: Device object to collect from.

        Decorated with async_retry for automatic retry on failure.
        Handles both single devices and smart strips with child plugs.

        Uses DeviceContext for proper connection management and ensures
        device state is updated before reading emeter data.
        """
        async with DeviceContext(device, ip, "emeter fetch"):
            await device.update()
            if isinstance(device, IotStrip):
                return await self.process_smart_strip_data(ip, device)
            if device.has_emeter:
                return await self.process_device_data(ip, device)
            # No emeter on this device: nothing to store, so nothing failed to store.
            return True

    async def process_smart_strip_data(self, ip: str, smart_strip: IotStrip) -> bool:
        """Process energy data for power strip and all child plugs.

        Args:
            ip: IP address of the power strip.
            smart_strip: IotStrip device object.

        Collects data from:
        1. Parent strip device (aggregate data)
        2. Each individual plug on the strip

        Each plug is stored as a separate data point with appropriate
        tagging to identify it as part of the parent strip. This allows
        for both aggregate and per-plug analysis in Grafana.
        """
        try:
            smart_strip_emeter_data = {
                key: int(value) for key, value in smart_strip.emeter_realtime.items()
            }
            smart_strip_data = {
                "emeter": smart_strip_emeter_data,
                "alias": smart_strip.alias,
                "dns_name": await get_hostname_cached(ip),
                "ip": ip,
                "equipment_type": "device",
            }
            self.logger.debug(
                "Storing smart strip data for %s (IP: %s).", smart_strip.alias, ip
            )
            stored = await self.storage.process_emeter_data({ip: smart_strip_data})

            for child in smart_strip.children:
                await child.update()
                plug_alias = f"{child.alias}"
                child_emeter_data = {
                    key: int(value) for key, value in child.emeter_realtime.items()
                }
                child_data = {
                    "emeter": child_emeter_data,
                    "alias": smart_strip.alias,
                    "plug_alias": plug_alias,
                    "dns_name": await get_hostname_cached(ip),
                    "ip": ip,
                    "equipment_type": "plug",
                }
                self.logger.debug(
                    "Storing child plug data for %s (IP: %s).", plug_alias, ip
                )
                # A strip counts as stored only if the parent AND every child landed --
                # a partially-written strip is not a success.
                stored = (
                    await self.storage.process_emeter_data({ip: child_data}) and stored
                )
            return stored
        # swallowed-exceptions: per-device boundary. A strip with one malformed child payload
        # must not abort the cycle for the other devices; the outcome is counted into the
        # cycle's collector_stats point and the traceback survives via logger.exception.
        except Exception as e:
            self.logger.exception("Error processing smart strip data for %s: %s", ip, e)
            return False

    async def process_device_data(self, ip: str, device: Device) -> bool:
        """Process energy data for a single smart plug.

        Args:
            ip: IP address of the device.
            device: Device object with emeter capability.

        Converts floating point readings to integers for consistency
        and stores with device identification tags. Handles missing
        data gracefully with specific error types for debugging.
        """
        try:
            emeter_data = {
                key: int(value) for key, value in device.emeter_realtime.items()
            }
            device_alias = device.alias if device.alias else device.host
            device_data = {
                "emeter": emeter_data,
                "alias": device_alias,
                "dns_name": await get_hostname_cached(ip),
                "ip": ip,
                "equipment_type": "device",
            }
            self.logger.debug("Storing emeter data for %s (IP: %s).", device_alias, ip)
            return await self.storage.process_emeter_data({ip: device_data})
        except (AttributeError, KeyError, ValueError, TypeError) as e:
            self.logger.exception(
                "Data processing error for emeter data at %s: %s", ip, e
            )
            return False
        # swallowed-exceptions: the broad tail behind an already-narrowed handler above
        # (AttributeError/KeyError/ValueError/TypeError cover the known device-payload shapes).
        # It stays broad because device firmware returns arbitrary JSON and one device must not
        # end the poll cycle -- but it is deliberately a SEPARATE branch so an unexpected type
        # is visible as such in the logs rather than blending into the expected ones.
        except Exception as e:
            self.logger.exception(
                "Unexpected error processing emeter data for %s: %s", ip, e
            )
            return False

    @async_retry(operation_name="sysinfo fetch")
    async def fetch_and_store_sysinfo(self, ip: str, device: Device) -> bool:
        """Fetch and store system information for a single device.

        Args:
            ip: IP address of the device.
            device: Device object to collect from.

        Decorated with async_retry for automatic retry on failure.
        Uses DeviceContext for enhanced error handling and connection
        management. System info is stored with full device context
        including hostname and alias.
        """
        async with DeviceContext(device, ip, "sysinfo fetch") as ctx:
            await device.update()
            self.logger.debug("Fetched sysinfo for device %s: %s", ip, device.sys_info)
            sysinfo_data = {
                "sysinfo": device.sys_info,
                "device_alias": ctx.device_name,
                "dns_name": ctx.hostname,
                "ip": ip,
                "equipment_type": "device",
            }
            self.logger.debug(
                "Storing sysinfo data for %s (IP: %s)", ctx.device_name, ip
            )
            return await self.storage.process_sysinfo_data({ip: sysinfo_data})
