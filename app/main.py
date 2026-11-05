"""Main orchestrator for the Kasa Collector application.

This module serves as the entry point and main coordinator for the Kasa Collector,
a Python-based data collection service for TP-Link Kasa smart plugs and power strips.
It manages device discovery, periodic data collection, and graceful shutdown.

The collector discovers devices on the network, collects energy consumption metrics,
stores data in InfluxDB, and provides the foundation for Grafana dashboard visualization.

Typical usage:
    python -m app.main

Key Features:
    - Automatic and manual device discovery
    - Periodic energy meter and system info collection
    - Graceful shutdown with proper resource cleanup
    - Comprehensive error handling and logging
    - Support for both smart plugs and power strips
"""

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import re
import signal
from collections.abc import Callable, Mapping
from typing import Any
from urllib.parse import unquote, urlsplit, urlunsplit

from app.collector.device_manager import DeviceManager
from app.collector.kasa_compat import verify_still_needed
from app.collector.poller import Poller
from app.core.config import REQUIRED_ENV_VARS, Config, describe_settings
from app.core.logging_config import configure_logging

logger = logging.getLogger("KasaCollector")

# Settings whose values are masked in the startup config dump.
_SENSITIVE = ("PASSWORD", "TOKEN", "USERNAME")


# A secret shorter than this is not scrubbed from log lines: replacing every occurrence of
# one or two characters would destroy the log while protecting almost nothing.
_MIN_SCRUBBED_LEN = 4


def _mask(value: str | None) -> str:
    """Redact a secret completely, keeping only whether it is set.

    No character and no length: the dump reaches `docker logs` and any log shipper, and
    four characters from each end of a 9-12 character password leave almost nothing to guess.
    Set or unset is read from the raw setting, so a password that is the word "None" is
    masked like any other.
    """
    if value is None:
        return "None"
    if value == "":
        return ""
    return "****"


def _strip_userinfo(url: str) -> str:
    """The URL with any `user:password@` replaced by `****@`."""
    parts = urlsplit(url)
    if "@" not in parts.netloc:
        return url
    return urlunsplit(parts._replace(netloc="****@" + parts.netloc.rsplit("@", 1)[1]))


_PERCENT_ESCAPE = re.compile(r"%[0-9a-fA-F]{2}")


def _escaped_forms(secret: str) -> list[str]:
    """``secret`` as repr() and JSON write it, as text and as UTF-8 bytes.

    repr picks its quote by what the whole string holds, so a secret beside a ``"`` has
    its own ``'`` written ``\\'``: each form is taken from ``secret`` followed by a ``"``
    as well as on its own. A non-ASCII secret inside bytes is written ``\\xNN``.
    """
    raw = secret.encode("utf-8", "surrogateescape")
    reprs = [
        repr(secret)[1:-1],
        repr(secret + '"')[1:-2],
        repr(raw)[2:-1],
        repr(raw + b'"')[2:-2],
    ]
    return reprs + [json.dumps(form)[1:-1] for form in [secret, *reprs]]


def _secret_values() -> list[str]:
    """Every configured secret as it could appear in a log line, longest first.

    The TP-Link password, username and InfluxDB token, a password inside the InfluxDB URL,
    and the password's MD5 hex in both cases (python-kasa's SSL transport logs its login
    request at DEBUG with the password as an unsalted MD5).
    """
    password = Config.KASA_COLLECTOR_TPLINK_PASSWORD
    found = [
        password,
        Config.KASA_COLLECTOR_TPLINK_USERNAME,
        Config.KASA_COLLECTOR_INFLUXDB_TOKEN,
        urlsplit(Config.KASA_COLLECTOR_INFLUXDB_URL or "").password,
    ]
    # The URL's password as written is percent-encoded; the client sends it decoded, and
    # yarl writes it back with its escapes in uppercase.
    url_password = found[-1]
    if url_password:
        found.append(unquote(url_password))
        found.append(_PERCENT_ESCAPE.sub(lambda m: m.group().upper(), url_password))
    if password:
        # Reproduces python-kasa's login hash so it can be scrubbed; it protects nothing.
        # surrogateescape: a setting read from undecodable environment bytes holds lone
        # surrogates, which a strict encode refuses, and logging must still start.
        raw = password.encode("utf-8", "surrogateescape")
        digest = hashlib.md5(raw, usedforsecurity=False).hexdigest()
        found += [digest, digest.upper()]
    # An exception message renders a value with repr() (a KeyError, a dict or tuple in
    # a message), and a logged payload may carry it JSON-escaped: both forms of a secret
    # holding a backslash or a quote differ from the literal. A traceback prefixes each
    # line of a multi-line value (an ExceptionGroup's `| `), so each line is kept too.
    present = [s for s in found if s]
    escaped = [form for s in present for form in _escaped_forms(s)]
    lines = [line for s in present for line in s.splitlines()]
    candidates = present + escaped + lines
    kept = {s for s in candidates if len(s.strip()) >= _MIN_SCRUBBED_LEN}
    return sorted(kept, key=len, reverse=True)


# python-kasa logs handshakes and sessions at DEBUG as hex. A KLAP handshake1 line holds
# both seeds and the server hash (sha256 over them and a hash of the TP-Link username and
# password), enough to guess the password offline, and its HTTP client logs each request
# URL with the AES and SSL session token in the query. No configured secret appears in
# them literally, so in python-kasa's messages and tracebacks every run of 32 or more hex
# digits is scrubbed as well. The app's own loggers keep theirs: device ids are hex.
_LIBRARY_LOGGER = "kasa"
_HEX_RUN = re.compile(r"[0-9a-fA-F]{32,}")
# The session token's value, whatever its shape: in a request URL's query (`token=`, the
# AES and SSL transports) or path (`/stok=…/`, the camera path), and as a logged reply's
# `'token': '…'` (the SSL transport logs its login response).
_SESSION_TOKEN = re.compile(r"(?:\btoken|\bstok)=([^&/\s'\"<>;,)]+)")
_SESSION_TOKEN_FIELD = re.compile(
    r"""\\?['"](?:token|stok)\\?['"]\s*:\s*\\?['"]([^'"\\]+)"""
)
# The parts of a line the logging module renders from the record itself; the caller's
# `extra=` fields reach the redactor separately and carry no logger.
_RENDERED_FIELDS = ("message", "exception", "stack")


def _scrubbed(text: str, secrets: list[str], hex_runs: bool) -> str:
    """`text` with every secret occurrence as `****`; with ``hex_runs`` (a python-kasa
    line), every long hex run and every session token value as well.

    All spans are found on the original text and merged where they overlap or touch, then
    each merged span is replaced once. Replacing one pattern at a time would let the first
    replacement break up the next match: a hex-only secret inside a handshake hex run would
    cut the run below the length that marks it, and two overlapping secrets would leave the
    second one's tail.
    """
    # A str subclass's own methods never run: the formatter must write plain text.
    text = str.__str__(text)
    spans: list[tuple[int, int]] = []
    for secret in secrets:
        start = text.find(secret)
        while start != -1:
            spans.append((start, start + len(secret)))
            start = text.find(secret, start + 1)
    if hex_runs:
        spans += [m.span() for m in _HEX_RUN.finditer(text)]
        spans += [m.span(1) for m in _SESSION_TOKEN.finditer(text)]
        spans += [m.span(1) for m in _SESSION_TOKEN_FIELD.finditer(text)]
    if not spans:
        return text
    spans.sort()
    merged = [list(spans[0])]
    for start, end in spans[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    pieces: list[str] = []
    position = 0
    for start, end in merged:
        pieces += [text[position:start], "****"]
        position = end
    pieces.append(text[position:])
    return "".join(pieces)


# Past this depth a field is written as its scrubbed text: a self-referencing or very
# deep structure would otherwise make the redactor raise, and the line be lost.
_MAX_FIELD_DEPTH = 20
# Past this many values walked in one field, the rest are written as a placeholder: a
# structure sharing its children (`[x] * 3`, twenty deep) is small in memory but would
# take hours to walk.
_MAX_FIELD_NODES = 10_000
_ELIDED = "<…>"


class _KeyMaker:
    """Text keys for one mapping: ``key``, or ``key#2``, ``key#3`` … when two keys scrub
    alike, so neither value is dropped. Each base remembers its last number, so many keys
    that scrub alike take linear time."""

    def __init__(self, secrets: list[str]) -> None:
        self.secrets = secrets
        self.taken: set[str] = set()
        self.last: dict[str, int] = {}

    def __call__(self, key: Any) -> str:
        base = _scrubbed(_plain_text(key), self.secrets, hex_runs=False)
        candidate, n = base, self.last.get(base, 1)
        if n > 1:
            candidate = f"{base}#{n}"
        while candidate in self.taken:
            n += 1
            candidate = f"{base}#{n}"
        self.last[base] = n
        self.taken.add(candidate)
        return candidate


def _scrubbed_value(
    value: Any,
    secrets: list[str],
    depth: int = 0,
    seen: frozenset[int] = frozenset(),
    budget: list[int] | None = None,
) -> Any:
    """A field's value with every secret scrubbed, at any depth.

    A field the caller passes (`extra=`, bound context) may be any object, and the
    formatter writes its str, repr or JSON after the redactor has run. So only plain
    numbers, booleans and None pass as they are; containers are walked (their keys made
    strings), bytes are decoded, and anything else is scrubbed as its text. A container
    that cannot be walked is written as its scrubbed text, and past
    ``_MAX_FIELD_NODES`` values the rest of the field as ``<…>``.
    """
    if budget is None:
        budget = [_MAX_FIELD_NODES]
    if budget[0] <= 0:
        return _ELIDED
    budget[0] -= 1
    # Exact types only: a subclass's str() is its own code, and may carry anything.
    if value is None or type(value) in (bool, int, float):
        return value
    if isinstance(value, str):
        return _scrubbed(value, secrets, hex_runs=False)
    if isinstance(value, bytes | bytearray):
        text = bytes(value).decode("utf-8", "surrogateescape")
        return _scrubbed(text, secrets, hex_runs=False)
    walkable = isinstance(value, Mapping | list | tuple | set | frozenset)
    if walkable and depth < _MAX_FIELD_DEPTH and id(value) not in seen:
        inner = seen | {id(value)}
        # swallowed-exceptions: a container whose own iteration or item access raises is
        # a field on a line being written, inside the redactor, which cannot log without
        # recursing; writing its scrubbed text instead is the handling.
        try:
            if isinstance(value, Mapping):
                key_for = _KeyMaker(secrets)
                return {
                    key_for(k): _scrubbed_value(v, secrets, depth + 1, inner, budget)
                    for k, v in value.items()
                }
            return [
                _scrubbed_value(item, secrets, depth + 1, inner, budget)
                for item in value
            ]
        except Exception:
            pass
    return _scrubbed(_plain_text(value), secrets, hex_runs=False)


def _plain_text(value: Any) -> str:
    """`value` as text for a log line; an object whose str and repr both raise is named
    by its type, so a field never costs the line."""
    # swallowed-exceptions: the text of a field on a line being written, inside the
    # redactor, which cannot log without recursing; falling back to repr is the handling.
    try:
        return str(value)
    except Exception:
        pass
    # swallowed-exceptions: as above; naming the type is the last fallback.
    try:
        return repr(value)
    except Exception:
        return f"<{type(value).__qualname__}>"


def _redactor(secrets: list[str]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    """A log redactor that replaces each secret with `****` in every field and key, at
    any depth, and every long hex run in a python-kasa line's message and traceback."""

    def scrub(part: dict[str, Any]) -> dict[str, Any]:
        logger_name = str(part.get("logger", ""))
        library = logger_name == _LIBRARY_LOGGER or logger_name.startswith(
            f"{_LIBRARY_LOGGER}."
        )
        out: dict[str, Any] = {}
        key_for = _KeyMaker(secrets)
        for key, value in part.items():
            if isinstance(value, str) and library and key in _RENDERED_FIELDS:
                value = _scrubbed(value, secrets, hex_runs=True)
            else:
                value = _scrubbed_value(value, secrets)
            out[key_for(key)] = value
        return out

    return scrub


class KasaCollector:
    """Main orchestrator class for the Kasa Collector application.

    This class coordinates all major components of the application including
    device management, data polling, and storage. It handles initialization,
    periodic task management, and graceful shutdown.

    Attributes:
        logger: Logger instance for this class.
        device_manager: Manages device discovery and tracking.
        tasks: Set of asyncio tasks for proper cleanup.
        poller: Handles periodic data collection from devices.
    """

    def __init__(self) -> None:
        """Initialize the Kasa Collector with all required components.

        Raises:
            SystemExit: If required configuration is missing or initialization fails.
        """
        self.logger = logging.getLogger(self.__class__.__name__)
        # Says at startup whether the local python-kasa discovery fix is still needed
        # (it announces when upstream has fixed it). See app/collector/kasa_compat.
        verify_still_needed()
        self.device_manager = DeviceManager(self.logger)
        self.tasks: set[asyncio.Task[None]] = set()  # Store task references
        self.check_required_configs()

        # Initialize poller after config check
        try:
            # The poller reports every device that answers back to the device manager,
            # so discovery cannot prune a host we are still collecting from.
            self.poller = Poller(
                self.logger,
                on_reachable=self.device_manager.mark_reachable,
                registry=self.device_manager,
            )
        except SystemExit:
            # Poller/InfluxDBStorage already logged detailed error messages
            raise
        except Exception as e:
            self.logger.exception("Failed to initialize components: %s", e)
            raise SystemExit(1) from None

    def check_required_configs(self) -> None:
        """Log the effective configuration and fail fast if a required var is missing.

        The startup config dump comes from ``config.describe_settings()`` (a single
        source of truth — no hand-kept list to drift), with PASSWORD/TOKEN/USERNAME
        values masked and any credentials in the InfluxDB URL removed.

        Raises:
            SystemExit: If any required configuration is missing.
        """
        version = os.getenv("KASA_COLLECTOR_VERSION", "unknown")
        build_timestamp = os.getenv("KASA_COLLECTOR_BUILD_TIMESTAMP", "unknown")

        self.logger.info("=" * 60)
        self.logger.info("Kasa Collector")
        self.logger.info("Version: %s", version)
        self.logger.info("Build Date: %s", build_timestamp)
        self.logger.info("=" * 60)

        self.logger.info("Configuration:")
        for var, value in describe_settings().items():
            if any(s in var for s in _SENSITIVE):
                shown = _mask(getattr(Config, var, None))
            elif var == "KASA_COLLECTOR_INFLUXDB_URL":
                shown = _strip_userinfo(value)
            else:
                shown = value
            self.logger.info("  %s: %s", var, shown)
        self.logger.info("=" * 60)

        missing = [v for v in REQUIRED_ENV_VARS if not os.environ.get(v)]
        if missing:
            self.logger.error("Missing required configurations: %s", ", ".join(missing))
            raise SystemExit(f"Cannot start. Missing configs: {', '.join(missing)}")

    async def start(self) -> None:
        """Start the Kasa Collector and all periodic tasks.

        This method:
        1. Initializes any manually configured devices
        2. Performs initial device discovery (if auto-discovery enabled)
        3. Starts periodic tasks for data collection and discovery

        All tasks are tracked for proper cleanup during shutdown.

        Raises:
            Exception: If initialization or task creation fails.
        """
        try:
            # Open the InfluxDB connection first so misconfiguration fails fast,
            # before any device polling starts.
            await self.poller.connect()

            # Acquire the device (source) clients: manual devices + initial discovery.
            await self.device_manager.connect()

            # Start the poller tasks for fetching emeter and sysinfo data
            emeter_task = asyncio.create_task(
                self.poller.periodic_emeter_fetch(self.device_manager.emeter_devices)
            )
            sysinfo_task = asyncio.create_task(
                self.poller.periodic_sysinfo_fetch(self.device_manager.emeter_devices)
            )
            discovery_task = asyncio.create_task(self.periodic_discover())

            # Store task references for proper cleanup
            self.tasks.add(emeter_task)
            self.tasks.add(sysinfo_task)
            self.tasks.add(discovery_task)

        except Exception as e:
            self.logger.exception("Failed to start KasaCollector: %s", e)
            raise

    async def periodic_discover(self) -> None:
        """Periodically discover new devices on the network.

        Runs device discovery at intervals defined by KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL.
        The first discovery is delayed by the interval to avoid immediate re-discovery
        after startup. Continues running until cancelled.

        Note:
            Respects existing manual devices and won't override them.
            Errors during discovery are logged but don't stop the periodic task.
        """
        # The FIRST re-discovery runs soon, not a full interval later. Discovery is a
        # lossy UDP broadcast, so a device can simply miss the startup round -- and at
        # startup there is nothing in the registry yet, so the miss-threshold cannot
        # protect it (there is no entry to keep). Waiting a whole interval would leave
        # that device uncollected for up to DEVICE_DISCOVERY_INTERVAL for no reason.
        # A short catch-up pass closes that window; the normal cadence resumes after.
        catch_up = min(
            Config.KASA_COLLECTOR_DISCOVERY_CATCH_UP_DELAY,
            Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL,
        )
        self.logger.debug(
            "Waiting %ss before the catch-up discovery pass (interval %ss).",
            catch_up,
            Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL,
        )
        await asyncio.sleep(catch_up)

        while True:
            try:
                self.logger.debug("Running periodic device discovery.")
                await self.device_manager.discover_devices()
            # swallowed-exceptions: the discovery task must outlive a failed cycle. This is a
            # `while True` background task; an unhandled raise ends discovery for the process
            # lifetime and the collector silently stops finding new devices. The finally-sleep
            # below then retries next interval. Traceback preserved via logger.exception.
            except Exception as e:
                self.logger.exception("Error during periodic device discovery: %s", e)
            finally:
                await asyncio.sleep(Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL)

    async def shutdown(self) -> None:
        """Perform graceful shutdown of all components.

        Shutdown sequence:
        1. Cancel all running tasks with timeout
        2. Close InfluxDB connections
        3. Disconnect from all Kasa devices

        Uses KASA_COLLECTOR_SHUTDOWN_TIMEOUT to limit task cancellation time.
        Ensures all resources are properly released.
        """
        self.logger.info("Starting graceful shutdown...")

        # Cancel all running tasks
        for task in self.tasks:
            if not task.done():
                task.cancel()

        # Wait for tasks to complete cancellation with timeout
        if self.tasks:
            try:
                await asyncio.wait_for(
                    asyncio.gather(*self.tasks, return_exceptions=True),
                    timeout=Config.KASA_COLLECTOR_SHUTDOWN_TIMEOUT,
                )
                self.logger.debug("Cancelled %s tasks", len(self.tasks))
            except TimeoutError:
                self.logger.warning(
                    "Task cancellation timed out after %ss",
                    Config.KASA_COLLECTOR_SHUTDOWN_TIMEOUT,
                )

        # Close any connections in poller and device_manager
        if hasattr(self.poller, "storage") and self.poller.storage:
            await self.poller.storage.close()
            self.logger.debug("Closed poller InfluxDB connection")

        # Stop the poller's reconnects first, so none registers a client after the
        # device clients are closed; then close them and clear the registries.
        if hasattr(self.poller, "close"):
            await self.poller.close()
        await self.device_manager.close()

        self.logger.info("Graceful shutdown completed")


async def main() -> None:
    """Main entry point for the Kasa Collector application.

    Initializes the collector, starts all services, and keeps the event loop
    running until interrupted. Handles shutdown signals gracefully.

    Raises:
        SystemExit: If initialization fails or on clean shutdown.
    """
    try:
        collector = KasaCollector()
    except SystemExit:
        # Configuration or initialization errors already logged
        raise  # Re-raise to preserve exit code
    except Exception as e:
        logger.exception("Failed to initialize Kasa Collector: %s", e)
        raise SystemExit(1) from None

    # Install signal handlers so `docker stop` / k8s termination (SIGTERM) and
    # Ctrl-C (SIGINT) both trigger a graceful shutdown. Without this, SIGTERM sent
    # to PID 1 is dropped and buffered InfluxDB writes never flush.
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        # add_signal_handler is unavailable on some platforms (e.g. Windows)
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop_event.set)

    try:
        await collector.start()
        # Block until a shutdown signal arrives.
        await stop_event.wait()
    except asyncio.CancelledError, KeyboardInterrupt:
        pass  # fall through to graceful shutdown
    finally:
        logger.info("Received shutdown signal. Shutting down gracefully...")
        await collector.shutdown()


def configure_app_logging() -> None:
    """Install the fleet's one logging setup (luxarch --emit logging) for this process.

    JSON lines on stdout, or a readable line with LOG_FORMAT=text. The per-component
    KASA_COLLECTOR_LOG_LEVEL_* settings are the code's defaults; LOG_MODULE_LEVELS overrides
    any logger at runtime, and LOG_LEVEL governs every logger they do not name.
    python-kasa stays at WARNING unless LOG_MODULE_LEVELS turns it up. Every line is
    scrubbed of the configured secrets, and every python-kasa transport line of its
    handshake hex, so a logger turned up to DEBUG (python-kasa's login requests and
    handshakes included) cannot write one.
    """
    configure_logging(
        redact=_redactor(_secret_values()),
        service="kasa-collector",
        version=os.getenv("KASA_COLLECTOR_VERSION", "unknown"),
        levels={
            "KasaCollector": Config.KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR,
            "KasaAPI": Config.KASA_COLLECTOR_LOG_LEVEL_KASA_API,
            "KasaCompat": Config.KASA_COLLECTOR_LOG_LEVEL_KASA_API,
            "InfluxDBStorage": Config.KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE,
            "kasa": "WARNING",
        },
    )


if __name__ == "__main__":
    configure_app_logging()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Received KeyboardInterrupt. Exiting gracefully.")
    except SystemExit as e:
        # Exit with the specified code without printing traceback
        exit(e.code if e.code is not None else 1)
    except Exception as e:
        logger.exception("Unexpected error: %s", e)
        exit(1)
