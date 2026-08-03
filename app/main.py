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
import logging
import os
import signal

from app.collector.device_manager import DeviceManager
from app.collector.poller import Poller
from app.core.config import REQUIRED_ENV_VARS, Config, describe_settings
from app.utils.logging import setup_logger

# Configure the orchestrator logger via the fleet logging util (structured or colored).
logger = setup_logger("KasaCollector", Config.KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR)

# Settings whose values are masked in the startup config dump.
_SENSITIVE = ("PASSWORD", "TOKEN", "USERNAME")


def _mask(value: str) -> str:
    """Partially mask a secret; fully redact values too short to partially mask."""
    if not value or value == "None":
        return value
    if len(value) <= 8:
        return "*" * len(value)
    return value[:4] + "****" + value[-4:]


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
        self.device_manager = DeviceManager(self.logger)
        self.tasks: set[asyncio.Task[None]] = set()  # Store task references
        self.check_required_configs()

        # Initialize poller after config check
        try:
            self.poller = Poller(self.logger)
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
        values masked.

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
            shown = _mask(value) if any(s in var for s in _SENSITIVE) else value
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
        self.logger.debug(
            "Waiting %ss before first periodic discovery.",
            Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL,
        )

        # Wait for the discovery interval to pass before starting periodic discovery
        await asyncio.sleep(Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL)

        while True:
            try:
                self.logger.debug("Running periodic device discovery.")
                await self.device_manager.discover_devices()
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

        # Close the device (source) clients — disconnect all and clear registries.
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


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Received KeyboardInterrupt. Exiting gracefully.")
    except SystemExit as e:
        # Exit with the specified code without printing traceback
        exit(e.code if e.code is not None else 1)
    except Exception as e:
        logger.exception("Unexpected error: %s", e)
        exit(1)
