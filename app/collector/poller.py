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
import math
import time
from collections.abc import Awaitable, Callable, Mapping
from contextvars import ContextVar
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

from kasa import Device, Module
from kasa.emeterstatus import EmeterStatus
from kasa.iot import IotDevice, IotStrip
from kasa.smart import SmartDevice

from app.collector.dns_cache import get_hostname_cached
from app.collector.utils import (
    DeviceContext,
    async_retry,
    energy_status,
    get_device_name,
    has_outlet_energy,
)
from app.core.config import Config
from app.health import heartbeat
from app.storage.influxdb import InfluxDBStorage, device_id_of
from app.storage.sysinfo_fields import without_dropped

# The collector's component logger, so KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR governs it
# as it does the Poller instance's.
logger = logging.getLogger("KasaCollector")

# The emeter fields written, in the units the dashboards read. Legacy firmware (HS110
# hardware v1) reports A / V / W / kWh as floats under `current` / `voltage` / `power` /
# `total`; python-kasa's EmeterStatus converts those when one of these keys is read, so
# a reading is never stored as a truncated whole amp or kilowatt-hour.
_EMETER_FIELDS = {
    "current_ma": "current",
    "voltage_mv": "voltage",
    "power_mw": "power",
    "total_wh": "total",
}


class UnstorableReading(Exception):
    """A device answered, but its reading could not be read in full or turned into
    points (a strip outlet that did not answer, a malformed payload).

    A device fault, not a storage one: `_fetch_counted` counts it as `failed`, never as
    `write_failed`, and the device still counts as reachable. It is never retried.
    """


_INT64_MIN, _INT64_MAX = -(2**63), 2**63 - 1


class _FetchDeadline:
    """One device fetch's deadline: a budget for the read, then a fresh one for the
    writes, so neither can hold the cycle back for longer than its budget."""

    def __init__(self, budget: float) -> None:
        self.budget = budget
        self.timeout = asyncio.timeout(budget)
        self.reads_done = False


# The current device fetch's deadline, set by `Poller._fetch_counted`.
_FETCH_DEADLINE: ContextVar[_FetchDeadline | None] = ContextVar(
    "_FETCH_DEADLINE", default=None
)


def _reads_done() -> None:
    """Every reading is in hand: give the writes a budget of their own."""
    deadline = _FETCH_DEADLINE.get()
    if deadline is not None and not deadline.reads_done:
        deadline.reads_done = True
        loop = asyncio.get_running_loop()
        deadline.timeout.reschedule(loop.time() + deadline.budget)


def _storable(value: Any) -> bool:
    """False for a value no InfluxDB integer field can hold: a float NaN or infinity,
    or an integer outside int64 (InfluxDB rejects the device's whole batch for it).

    Anything that is not a number (None, a string) is not storable either: it would
    fail the integer conversion and cost the whole reading, not just its own field.

    Bounds are compared on a plain int, read through the base type so a subclass's own
    conversion cannot run: `x in range(...)` is constant-time only for an exact int, and
    walks the whole range for an int subclass.
    """
    if isinstance(value, bool):
        return True
    if isinstance(value, float):
        plain = float.__float__(value)
        return math.isfinite(plain) and _INT64_MIN <= int(plain) <= _INT64_MAX
    if isinstance(value, int):
        return _INT64_MIN <= int.__int__(value) <= _INT64_MAX
    return False


def _as_int(value: int | float) -> int:
    """A storable number as a plain int, read through its base type."""
    if isinstance(value, float):
        return int(float.__float__(value))
    return int.__int__(value)


# An IOT reply's status, not a measurement.
_STATUS_KEYS = frozenset({"err_code", "err_msg"})


def _storable_reading(
    realtime: Mapping[str, Any], legacy_units: bool
) -> dict[str, int]:
    """`emeter_fields`, refusing a reading that holds no measurement to store.

    An empty reading, one whose every measurement was dropped, or an IOT error reply
    (``err_code`` other than 0) would write no measurement yet count as stored, and keep
    the health check green. Each is a bad reading instead.
    """
    err_code = dict.get(realtime, "err_code") if isinstance(realtime, dict) else None
    if (
        isinstance(err_code, int)
        and not isinstance(err_code, bool)
        and int.__int__(err_code) != 0
    ):
        raise ValueError(
            f"device answered the emeter read with error {int.__int__(err_code)}"
        )
    fields = emeter_fields(realtime, legacy_units=legacy_units)
    if all(key in _STATUS_KEYS for key in fields):
        raise ValueError(
            f"no storable measurement in emeter reading {dict(realtime)!r}"
        )
    return fields


def emeter_fields(realtime: Mapping[str, Any], legacy_units: bool) -> dict[str, int]:
    """A device's realtime emeter reading as integer fields.

    With `legacy_units` (an IOT device, whose firmware may report A / V / W / kWh), the
    legacy-unit keys are replaced by their converted milli-unit field; a null one is
    skipped and the rest still written. Without it every key is written as reported:
    a SMART device's `total` is today's kWh, never the lifetime `total_wh`. Any other key
    (such as `err_code`) is written as reported. A value InfluxDB cannot hold (NaN,
    infinity, an integer outside int64) drops only its own field.
    """
    if not legacy_units:
        return {
            key: _as_int(value) for key, value in realtime.items() if _storable(value)
        }
    status = EmeterStatus(realtime)
    legacy = set(_EMETER_FIELDS.values())
    out: dict[str, int] = {}
    for field in _EMETER_FIELDS:
        try:
            value = status[field]
        except KeyError, TypeError:  # absent, or a null legacy value to convert
            continue
        if value is not None and _storable(value):
            # Read through the base type, so a subclass's own __round__ never runs.
            out[field] = (
                round(float.__float__(value))
                if isinstance(value, float)
                else _as_int(value)
            )
    for key, value in status.items():
        if key not in _EMETER_FIELDS and key not in legacy and _storable(value):
            out[key] = _as_int(value)
    return out


# A SMART device's energy counters, as its Energy module reads them from
# get_energy_usage (Wh). Its realtime reading carries `total` (today's kWh, on energy
# monitoring v1) or `energy_wh` (v2); python-kasa reads no lifetime counter
# (`consumption_total` is always None), so these are the energy figures it has.
_SMART_ENERGY_FIELDS = {"today_energy": "today_wh", "month_energy": "month_wh"}


def _reported_position(outlet: Any) -> int | None:
    """The position a SMART outlet reports on its strip (one-based), or None."""
    position = (getattr(outlet, "sys_info", None) or {}).get("position")
    if isinstance(position, bool) or not isinstance(position, int):
        return None
    number = int.__int__(position)
    return number if number >= 1 else None


def _outlet_id(outlet: Any) -> str | None:
    """A SMART outlet's own device id, which no reordering of the children changes."""
    value = getattr(outlet, "device_id", None)
    return value if isinstance(value, str) and value else None


def _disabled_outlets(strip: Any) -> list[str]:
    """The outlets whose energy module python-kasa has disabled after repeated errors.

    python-kasa never re-enables a module on the client that disabled it.
    """
    disabled = []
    for index, outlet in enumerate(getattr(strip, "children", None) or (), start=1):
        modules = getattr(outlet, "modules", None)
        module = modules.get(Module.Energy) if isinstance(modules, Mapping) else None
        if module is not None and getattr(module, "disabled", False) is True:
            disabled.append(str(outlet.alias or index))
    return disabled


class ClientRegistry(Protocol):
    """Where the poller's devices are registered, and how one is connected afresh."""

    def is_current(self, key: str, device: Device) -> bool:
        """Whether ``device`` is still the client registered under ``key``."""
        ...

    async def connect_fresh(self, key: str) -> Device:
        """A new, updated client for the device registered under ``key``."""
        ...

    def swap_client(self, key: str, old: Device, new: Device) -> bool:
        """Register ``new`` in place of ``old``; False if ``old`` is no longer it."""
        ...


# A strip whose outlet python-kasa disabled is reconnected at most this often, the gap
# doubling on each attempt up to the cap.
_RECONNECT_FIRST_GAP = 60.0
_RECONNECT_MAX_GAP = 3600.0


def _device_label(device: Any) -> str:
    """The device's repr for a log line, or its type and id when the repr itself fails.

    python-kasa's repr reads properties that can raise after a failed update, and a log
    argument whose formatting raises costs the whole line.
    """
    # swallowed-exceptions: this labels a line that already reports the failure, and
    # falling back to the type and id is the handling.
    try:
        return repr(device)
    except Exception:
        return object.__repr__(device)


def smart_energy_fields(device: Any) -> dict[str, int]:
    """Today's and this month's energy in Wh for a SMART device, where it reports them.

    An extra beside the realtime reading: anything unreadable here yields nothing, and
    never costs the reading itself. A counter is a whole, non-negative number of Wh.
    """
    try:
        modules = getattr(device, "modules", None)
        module = modules.get(Module.Energy) if isinstance(modules, Mapping) else None
        reported = getattr(module, "energy", None)
        if not isinstance(reported, Mapping):
            return {}
        # Read and converted while still guarded: a mapping whose reads raise, or a
        # number type whose conversion raises, fails here and costs only these extras.
        numbers: dict[str, int | float] = {}
        for key, field in _SMART_ENERGY_FIELDS.items():
            value = reported.get(key)
            if isinstance(value, bool) or not isinstance(value, int | float):
                continue
            numbers[field] = float(value) if isinstance(value, float) else int(value)
    except Exception:
        logger.warning(
            "Could not read the energy counters of %s; writing the realtime reading "
            "without them",
            _device_label(device),
            exc_info=True,
        )
        return {}
    # Plain int and float from here on: their comparisons cannot raise.
    return {
        field: round(number)
        for field, number in numbers.items()
        if _storable(number) and number >= 0
    }


async def _close(device: Any) -> None:
    """Close a client the registry no longer holds."""
    # swallowed-exceptions: closing a discarded client; a failure leaves nothing to
    # recover, and the reconnect it ends has already succeeded.
    try:
        await device.disconnect()
    except Exception as e:
        logger.debug("Closing a replaced client failed: %s", e)


class _ClientState:
    """The poller's bookkeeping of clients in flight, replaced, and reconnecting."""

    def __init__(self) -> None:
        self.in_flight: dict[int, int] = {}
        self.retiring: dict[int, Any] = {}
        self.positions: dict[str, dict[str, int]] = {}
        self.next_reconnect: dict[str, tuple[float, float]] = {}
        self.tasks: dict[str, asyncio.Task[None]] = {}

    def hold(self, device: Any) -> None:
        self.in_flight[id(device)] = self.in_flight.get(id(device), 0) + 1

    def release(self, device: Any) -> Any:
        """Let go of ``device``; it, once retired and held by no fetch, else None."""
        left = self.in_flight.get(id(device), 1) - 1
        if left > 0:
            self.in_flight[id(device)] = left
            return None
        self.in_flight.pop(id(device), None)
        return self.retiring.pop(id(device), None)

    def retire(self, device: Any) -> Any:
        """Mark ``device`` replaced; it, if no fetch holds it now, else None."""
        if self.in_flight.get(id(device)):
            self.retiring[id(device)] = device
            return None
        return device

    def reconnecting(self, key: str) -> bool:
        task = self.tasks.get(key)
        return task is not None and not task.done()

    def may_reconnect(self, key: str) -> bool:
        """Whether a reconnect of ``key`` is due, and if so, push the next one back."""
        now = time.monotonic()
        not_before, gap = self.next_reconnect.get(key, (0.0, _RECONNECT_FIRST_GAP))
        if now < not_before:
            return False
        self.next_reconnect[key] = (now + gap, min(gap * 2, _RECONNECT_MAX_GAP))
        return True

    def start_reconnect(self, key: str, work: Awaitable[None]) -> None:
        self.tasks[key] = asyncio.ensure_future(work)


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

    # Class-level defaults so an instance built without __init__ still has them.
    on_reachable: Callable[[str], None] | None = None
    registry: ClientRegistry | None = None

    def __init__(
        self,
        logger: logging.Logger,
        on_reachable: Callable[[str], None] | None = None,
        registry: ClientRegistry | None = None,
    ):
        """Initialize the Poller with storage backend.

        Args:
            logger: Logger instance for logging operations.
            on_reachable: Called with a device's registry key each time that device
                answers a poll. The DeviceManager uses it to avoid pruning a device it
                is still collecting from. Optional so the poller stays
                usable standalone.
            registry: The device registry. With it, a fetch of a client that has
                since been replaced is skipped, and a SMART strip whose outlet
                python-kasa disabled is reconnected in place: polled on its old client
                until a new one has connected, then swapped, the old one closed once
                no fetch holds it.

        Raises:
            SystemExit: If storage backend initialization fails.
        """
        self.logger = logger
        self.on_reachable = on_reachable
        self.registry = registry
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

    async def close(self) -> None:
        """Stop every reconnect still running; called on shutdown before the registry
        closes its clients, so none registers a client after they are closed."""
        tasks = list(self._clients().tasks.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def _clients(self) -> _ClientState:
        """This poller's client bookkeeping, made on first use."""
        state: _ClientState | None = getattr(self, "_client_state", None)
        if state is None:
            state = _ClientState()
            self._client_state = state
        return state

    async def _fetch_counted(
        self,
        fetch: Callable[[str, Device], Awaitable[bool | None]],
        ip: str,
        device: Device,
        outcome: dict[str, int],
        label: str,
        interval: float,
    ) -> None:
        """``_fetch_held`` on a client still registered, holding it while it runs.

        A client replaced since the cycle began is skipped: its successor is polled
        from the next cycle. A replaced client is closed only once no fetch holds it.
        """
        if self.registry is not None and not self.registry.is_current(ip, device):
            return
        clients = self._clients()
        clients.hold(device)
        try:
            await self._fetch_held(fetch, ip, device, outcome, label, interval)
        finally:
            retired = clients.release(device)
            if retired is not None:
                await _close(retired)

    async def _fetch_held(
        self,
        fetch: Callable[[str, Device], Awaitable[bool | None]],
        ip: str,
        device: Device,
        outcome: dict[str, int],
        label: str,
        interval: float,
    ) -> None:
        """Run one device fetch, recording the outcome without aborting siblings.

        Reading the device, its retries included, has 80% of the cycle's ``interval``:
        the cycle waits for every device, so one host that never answers would
        otherwise hold every healthy device's next sample back by its whole retry
        backoff. A read that runs out of time is ``failed``. Once every reading is in
        hand (``_reads_done``), the writes get a budget of their own: a slow InfluxDB
        never cuts off a read that already finished, and a write that runs out of time
        (a dead InfluxDB, a hung file mount) is ``write_failed`` on a device that
        answered.

        Per-device failures (after ``async_retry`` is exhausted) are swallowed and
        counted, so a single unreachable device can't cancel the rest of the cycle's
        TaskGroup. The counts feed the per-cycle collector metrics.

        Three outcomes, deliberately distinct: the device answered and its data was
        stored (``ok``); the device could not be polled (``failed``); or the device
        answered fine but the write to InfluxDB failed (``write_failed``), so an InfluxDB
        outage never reads as every device succeeding. A device that answered
        with a reading that cannot be stored (``UnstorableReading``) is ``failed`` and
        still reachable: the fault is the device's, not InfluxDB's.
        """
        phase = _FetchDeadline(interval * 0.8)
        deadline = phase.timeout
        try:
            async with deadline:
                token = _FETCH_DEADLINE.set(phase)
                try:
                    stored = await fetch(ip, device)
                finally:
                    _FETCH_DEADLINE.reset(token)
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
        except UnstorableReading as e:
            # The device ANSWERED, with a reading that cannot be stored: a device fault.
            if self.on_reachable is not None:
                self.on_reachable(ip)
            outcome["failed"] += 1
            self.logger.warning(
                "%s polled %s but its reading could not be collected: %s", label, ip, e
            )
        except TimeoutError as e:
            if phase.reads_done and deadline.expired():
                # The device answered in full; its write ran out of time.
                if self.on_reachable is not None:
                    self.on_reachable(ip)
                outcome["write_failed"] += 1
                self.logger.warning(
                    "%s polled %s but its write did not finish within %.0f seconds",
                    label,
                    ip,
                    interval * 0.8,
                )
                return
            # NOT reachable: it did not answer within the cycle's time, or python-kasa
            # timed it out itself (its TimeoutError is one), reported as its own error.
            outcome["failed"] += 1
            if deadline.expired():
                self.logger.warning(
                    "%s for %s did not finish within %.0f seconds",
                    label,
                    ip,
                    interval * 0.8,
                )
            else:
                self.logger.warning("%s failed for %s after retries: %s", label, ip, e)
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
                                Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL,
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
            # The container HEALTHCHECK's only signal: this run stored data this cycle.
            if outcome["ok"] > 0:
                heartbeat.beat()

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
                                Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL,
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
            if isinstance(device, IotStrip) or has_outlet_energy(device):
                return await self.process_smart_strip_data(ip, device)
            if device.has_emeter:
                return await self.process_device_data(ip, device)
            # Only emeter devices are polled here, so this one answered without the
            # emeter it had: nothing was stored, and the cycle must not count it so.
            raise UnstorableReading(f"{ip} no longer reports an emeter")

    async def process_smart_strip_data(self, ip: str, smart_strip: Device) -> bool:
        """Process energy data for power strip and all child plugs.

        Args:
            ip: IP address of the power strip.
            smart_strip: An IOT strip (HS300), or a SMART strip whose outlets measure
                their own energy (P316M). An IOT outlet is read with its own update(),
                in the IOT strip's units; a SMART strip's update() already read every
                outlet, and its total is written only when the strip measures one.

        Collects data from:
        1. Parent strip device (aggregate data)
        2. Each individual plug on the strip

        Each plug is stored as a separate data point with appropriate
        tagging to identify it as part of the parent strip. This allows
        for both aggregate and per-plug analysis in Grafana.
        """
        # Every outlet is read and every reading converted BEFORE anything is written,
        # and nothing here is retried: a re-run would write the strip's points again.
        # An IOT strip is read in full or not at all: an outlet that does not answer,
        # or a malformed payload, is a device fault (UnstorableReading: counted once,
        # the strip still reachable) and leaves no partly-written strip behind. A SMART
        # strip read every outlet in one update(), and python-kasa keeps one outlet's
        # energy error on that outlet (for its retry backoff, or for good once it gives
        # up on the module): that outlet is left out, and the rest are written.
        try:
            dns_name = await get_hostname_cached(ip)
            # The strip's id and each outlet's position are read off the strip as
            # polled: an outlet's alias is user-set and may repeat, and the sysinfo
            # cache may not hold this strip yet.
            device_id = device_id_of(smart_strip.sys_info)
            iot = not isinstance(smart_strip, SmartDevice)
            strip_name = get_device_name(smart_strip)
            totals = []
            if iot or smart_strip.has_emeter:
                totals.append(
                    {
                        "emeter": self._reading(smart_strip, iot),
                        "alias": strip_name,
                        "device_id": device_id,
                        "dns_name": dns_name,
                        "ip": ip,
                        "equipment_type": "device",
                    }
                )
            outlets = []
            positions = {} if iot else self._outlet_positions(ip, smart_strip.children)
            for index, child in enumerate(smart_strip.children, start=1):
                reading: dict[str, int] | None
                if iot:
                    await child.update()
                    reading = self._reading(child, iot)
                    plug_id = index
                else:
                    if not child.has_emeter:
                        continue
                    reading = self._outlet_reading(ip, child)
                    if reading is None:
                        continue
                    if id(child) not in positions:
                        continue
                    plug_id = positions[id(child)]
                outlets.append(
                    {
                        "emeter": reading,
                        "alias": strip_name,
                        "plug_alias": child.alias or f"Plug {plug_id}",
                        "plug_id": str(plug_id),
                        "device_id": device_id,
                        "dns_name": dns_name,
                        "ip": ip,
                        "equipment_type": "plug",
                    }
                )
            if not iot and _disabled_outlets(smart_strip):
                self._request_reconnect(ip, smart_strip)
            if not iot and not totals and not outlets:
                raise ValueError(f"no outlet of {ip} gave a storable reading")
        except Exception as e:
            self.logger.exception("Error reading smart strip data for %s: %s", ip, e)
            raise UnstorableReading(str(e)) from e

        self.logger.debug(
            "Storing smart strip data for %s (IP: %s).", smart_strip.alias, ip
        )
        _reads_done()
        # One batch: the strip lands whole or not at all, in one write.
        return await self.storage.process_emeter_entries(
            [(ip, point) for point in totals + outlets]
        )

    def _outlet_positions(self, ip: str, outlets: Any) -> dict[int, int]:
        """Each SMART outlet's plug_id this poll, by ``id()`` of the outlet object.

        An outlet's reported position (one-based, as every SMART strip numbers its
        outlets) is its plug_id. An outlet reporting none, or one another outlet
        already holds, keeps the position it last had, by its own device id (so
        another strip taking the address never inherits it); failing that, its index
        if no other outlet reports or holds that number. An outlet that cannot be
        placed is left out of this poll rather than written into another outlet's
        series. A strip that reports no positions at all is numbered by index.
        """
        measuring = [o for o in outlets if getattr(o, "has_emeter", False)]
        reported = {id(o): _reported_position(o) for o in measuring}
        valid = [p for p in reported.values() if p is not None]
        known = self._clients().positions.setdefault(ip, {})
        if not valid and not known:
            return {id(o): n for n, o in enumerate(outlets, start=1) if o in measuring}
        claimed = set(valid)
        placed: dict[int, int] = {}
        used: set[int] = set()
        for index, outlet in enumerate(outlets, start=1):
            if outlet not in measuring:
                continue
            outlet_id = _outlet_id(outlet)
            candidates = [
                reported[id(outlet)],
                known.get(outlet_id) if outlet_id else None,
                index if index not in claimed else None,
            ]
            position = next((c for c in candidates if c and c not in used), None)
            if position is None:
                self.logger.warning(
                    "Outlet %r of %s has no position of its own this poll; leaving it out",
                    outlet.alias or index,
                    ip,
                )
                continue
            placed[id(outlet)] = position
            used.add(position)
            if outlet_id:
                known[outlet_id] = position
        return placed

    def _request_reconnect(self, ip: str, strip: Device) -> None:
        """Reconnect ``strip`` in the background, at most once per back-off gap."""
        disabled = _disabled_outlets(strip)
        if self.registry is None:
            self.logger.warning(
                "%s: python-kasa stopped reading energy for outlet(s) %s; restart the "
                "collector to read them again",
                ip,
                ", ".join(disabled),
            )
            return
        clients = self._clients()
        if clients.reconnecting(ip) or not clients.may_reconnect(ip):
            return
        self.logger.warning(
            "%s: python-kasa stopped reading energy for outlet(s) %s after repeated "
            "errors; connecting the strip afresh, still polling it meanwhile",
            ip,
            ", ".join(disabled),
        )
        clients.start_reconnect(ip, self._reconnect(ip, strip))

    async def _reconnect(self, ip: str, old: Device) -> None:
        """Connect ``ip`` afresh, then swap the new client in for ``old``."""
        registry = self.registry
        if registry is None:
            return
        # swallowed-exceptions: a reconnect that fails leaves the strip on its old
        # client, still polled; it is logged and tried again after the back-off gap.
        try:
            new = await registry.connect_fresh(ip)
        except Exception as e:
            self.logger.warning("Reconnecting %s failed: %s", ip, e)
            return
        except asyncio.CancelledError:
            raise  # shutdown: nothing was connected yet to close
        try:
            swapped = registry.swap_client(ip, old, new)
        except BaseException:
            await _close(new)
            raise
        if not swapped:
            await _close(new)  # the old client was replaced or removed meanwhile
            return
        self.logger.info("Reconnected %s on a new client", ip)
        retired = self._clients().retire(old)
        if retired is not None:
            await _close(retired)

    def _outlet_reading(self, ip: str, outlet: Any) -> dict[str, int] | None:
        """A SMART outlet's reading, or None when that outlet's energy read failed."""
        # swallowed-exceptions: one outlet's energy error is that outlet's, logged here;
        # the strip's other outlets are still written.
        try:
            return self._reading(outlet, False)
        except Exception as e:
            self.logger.warning(
                "Outlet %r of %s gave no reading this cycle: %s",
                outlet.alias or "?",
                ip,
                e,
            )
            return None

    @staticmethod
    def _reading(device: Any, iot: bool) -> dict[str, int]:
        """One device's or outlet's storable emeter reading, SMART energy counters
        included."""
        reading = _storable_reading(energy_status(device), iot)
        if not iot:
            reading.update(smart_energy_fields(device))
        return reading

    async def process_device_data(self, ip: str, device: Device) -> bool:
        """Process energy data for a single smart plug.

        Args:
            ip: IP address of the device.
            device: Device object with emeter capability.

        Writes the reading as integer milli-unit fields (`emeter_fields`) with
        device identification tags. Handles missing
        data gracefully with specific error types for debugging.
        """
        try:
            is_iot = isinstance(device, IotDevice)
            emeter_data = _storable_reading(energy_status(device), is_iot)
            if not is_iot:
                emeter_data.update(smart_energy_fields(device))
            device_alias = device.alias if device.alias else device.host
            device_data = {
                "emeter": emeter_data,
                "alias": device_alias,
                # Read off the device as polled: the sysinfo cache may not hold it yet.
                "device_id": device_id_of(getattr(device, "sys_info", None) or {}),
                "dns_name": await get_hostname_cached(ip),
                "ip": ip,
                "equipment_type": "device",
            }
            self.logger.debug("Storing emeter data for %s (IP: %s).", device_alias, ip)
            _reads_done()
            return await self.storage.process_emeter_data({ip: device_data})
        except (AttributeError, KeyError, ValueError, TypeError, OverflowError) as e:
            self.logger.exception(
                "Data processing error for emeter data at %s: %s", ip, e
            )
            raise UnstorableReading(str(e)) from e
        # The broad tail behind the narrowed handler above (which covers the known
        # device-payload shapes). It stays broad because device firmware returns arbitrary
        # JSON, but it is a SEPARATE branch so an unexpected type is visible as such in the
        # logs. Either way it is the reading's fault, so it is raised as UnstorableReading.
        except Exception as e:
            self.logger.exception(
                "Unexpected error processing emeter data for %s: %s", ip, e
            )
            raise UnstorableReading(str(e)) from e

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
            self.logger.debug(
                "Fetched sysinfo for device %s: %s",
                ip,
                without_dropped(device.sys_info),
            )
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
            _reads_done()
            return await self.storage.process_sysinfo_data({ip: sysinfo_data})
