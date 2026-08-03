"""Device discovery and management for Kasa smart devices.

This module handles the discovery, authentication, and lifecycle management of
TP-Link Kasa smart devices. It supports both automatic network discovery and
manual device configuration, manages device connections, and tracks device
capabilities (particularly energy monitoring).

Key responsibilities:
    - Automatic device discovery via broadcast
    - Manual device registration from configuration
    - Device authentication with retry logic
    - Tracking devices with energy monitoring capabilities
    - Managing device connections and graceful disconnection
    - Handling devices on different subnets

The module maintains three device registries:
    - devices: All discovered and manual devices
    - emeter_devices: Devices with energy monitoring capabilities
    - polling_devices: Devices that need periodic data collection
"""

import asyncio
import logging
from datetime import datetime, timedelta

from kasa import Device

from app.collector.dns_cache import get_hostname_cached
from app.collector.kasa_api import KasaAPI
from app.collector.utils import get_device_name
from app.core.config import Config


class DeviceManager:
    """Manages Kasa device discovery, authentication, and lifecycle.

    This class serves as the central registry for all Kasa devices, handling
    both automatic discovery and manual device configuration. It maintains
    separate registries for different device capabilities and manages the
    authentication process with retry logic.

    Attributes:
        logger: Logger instance for this class.
        devices: Dictionary of all devices (IP -> device object).
        emeter_devices: Dictionary of devices with energy monitoring.
        polling_devices: Dictionary of devices that need polling.
        first_discovery_complete: Flag to track initial discovery.
        device_hosts: List of manually configured device IPs.
        tplink_username: Optional TP-Link account username.
        tplink_password: Optional TP-Link account password.
        max_retries: Maximum authentication retry attempts.
        timeout_seconds: Timeout for authentication operations.
    """

    def __init__(self, logger: logging.Logger):
        """Initialize the DeviceManager.

        Args:
            logger: Logger instance for logging device operations.
        """
        self.logger = logger
        self.devices: dict[str, Device] = {}  # All devices (manual and discovered)
        self.emeter_devices: dict[
            str, Device
        ] = {}  # Only devices with emeter functionality
        self.polling_devices: dict[
            str, Device
        ] = {}  # Devices needing polling (can be expanded)
        self.first_discovery_complete = False  # Track if we've done initial discovery

        # Initialize manual devices if provided
        self.device_hosts: list[str] = []
        if Config.KASA_COLLECTOR_DEVICE_HOSTS:
            self.device_hosts = [
                ip.strip() for ip in Config.KASA_COLLECTOR_DEVICE_HOSTS.split(",")
            ]

        # Initialize credentials if provided
        self.tplink_username = Config.KASA_COLLECTOR_TPLINK_USERNAME
        self.tplink_password = Config.KASA_COLLECTOR_TPLINK_PASSWORD

        # Configurable retry and timeout settings for device authentication
        self.max_retries = Config.KASA_COLLECTOR_AUTH_MAX_RETRIES
        self.timeout_seconds = Config.KASA_COLLECTOR_AUTH_TIMEOUT

    async def connect(self) -> None:
        """Acquire the long-lived device (source) clients.

        Initializes manual devices and runs the initial discovery once at startup;
        the resulting device clients are reused across poll cycles and released via
        ``close()`` on shutdown. Periodic re-discovery runs as a separate task.
        """
        await self.initialize_manual_devices()
        if Config.KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY:
            self.logger.debug("Starting initial device discovery...")
            await self.discover_devices()

    async def close(self) -> None:
        """Release all device clients on shutdown (disconnect + clear registries)."""
        await self.disconnect_all_devices()

    async def initialize_manual_devices(self) -> None:
        """Initialize manually configured devices from environment config.

        Processes devices specified in KASA_COLLECTOR_DEVICE_HOSTS environment
        variable. Manual devices are useful for:
        - Devices on different subnets that can't be discovered
        - Specific devices you want to ensure are always monitored
        - Devices with static IPs that should always be included

        Uses parallel processing for faster initialization when multiple
        devices are configured. Errors for individual devices don't prevent
        others from being added.
        """
        if not self.device_hosts:
            return

        async def add_manual_device(ip: str) -> None:
            """Add a single manual device by IP address.

            Args:
                ip: IP address or hostname of the device to add.
            """
            try:
                device = await KasaAPI.get_device(
                    ip, self.tplink_username, self.tplink_password
                )
                self.devices[ip] = device
                # Check and store devices based on emeter capabilities
                self._check_and_add_emeter_device(ip, device)
                device_name = get_device_name(device)
                hostname = await get_hostname_cached(ip)
                # Always show manually added devices at INFO level
                self.logger.info(
                    "Manually added device: %s (IP: %s, Host: %s)",
                    device_name,
                    ip,
                    hostname,
                )
            except Exception as e:
                self.logger.exception("Failed to add manual device %s: %s", ip, e)

        # Process all manual devices in parallel
        async with asyncio.TaskGroup() as tg:
            for ip in self.device_hosts:
                tg.create_task(add_manual_device(ip))

    async def discover_devices(self) -> None:
        """Discover Kasa devices on the local network.

        Performs network discovery using broadcast packets to find all Kasa
        devices on the same subnet. Discovered devices are authenticated in
        parallel for efficiency. Already known devices are skipped.

        Discovery behavior:
        - Skipped if KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY is False
        - First discovery logs at INFO level, subsequent at DEBUG
        - Respects existing manual devices (won't override)
        - Authenticates new devices in parallel using TaskGroup
        - Tracks discovery time and schedules next discovery

        Note:
            Discovery only finds devices on the same subnet. For devices
            on different subnets, use manual configuration.
        """
        if not Config.KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY:
            self.logger.debug("Auto-discovery is disabled. Skipping device discovery.")
            return

        # Log at INFO level for first discovery, DEBUG for subsequent
        if not self.first_discovery_complete:
            self.logger.info("Starting initial device discovery...")
        else:
            self.logger.debug("Starting device discovery...")

        # Track the start time for measuring how long the discovery takes
        start_time = datetime.now()

        # Discover devices
        discovered_devices = await KasaAPI.discover_devices()
        num_discovered = len(discovered_devices)
        if num_discovered > 0:
            self.logger.info("Discovered %s devices.", num_discovered)
        else:
            self.logger.warning("No devices discovered on the network.")

        # Prune devices that have dropped off the network (no-op unless
        # KASA_COLLECTOR_KEEP_MISSING_DEVICES is False; never prunes manual hosts).
        await self.remove_missing_devices(discovered_devices)

        # List to hold async tasks for parallel execution
        auth_tasks = []

        for ip, device in discovered_devices.items():
            if ip not in self.devices:  # Only authenticate new devices
                auth_tasks.append(self._authenticate_device_with_retry(ip, device))
                device_name = get_device_name(device)
                dns_name = await get_hostname_cached(ip)
                self.logger.debug(
                    "Device discovered: %s, IP: %s, DNS: %s", device_name, ip, dns_name
                )

        # Run all authentication tasks concurrently
        if auth_tasks:
            try:
                async with asyncio.TaskGroup() as tg:
                    for task_coro in auth_tasks:
                        tg.create_task(task_coro)
            except* Exception as eg:
                self.logger.exception(
                    "Error(s) during device authentication: %s",
                    "; ".join(str(exc) for exc in eg.exceptions),
                )

        # Track the time taken for discovery and authentication
        end_time = datetime.now()
        elapsed_time = (end_time - start_time).total_seconds()

        # Show completion at INFO level for first discovery
        if not self.first_discovery_complete:
            self.logger.info(
                "Initial device discovery completed in %.2f seconds.", elapsed_time
            )
            self.logger.info(
                "Found %s devices with energy monitoring capabilities.",
                len(self.emeter_devices),
            )
        else:
            self.logger.debug(
                "Device discovery completed in %.2f seconds.", elapsed_time
            )

        # Calculate the time of the next discovery based on the interval and log it
        next_discovery_interval = Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL
        next_discovery_time = (
            datetime.now() + timedelta(seconds=next_discovery_interval)
        ).strftime("%Y-%m-%d %H:%M:%S")
        self.logger.debug("Next device discovery will run at %s.", next_discovery_time)

        # Mark first discovery as complete
        self.first_discovery_complete = True

    async def _authenticate_device_with_retry(
        self, ip: str, discovered_device: Device | None
    ) -> None:
        """Authenticate a device with retry logic and multiple fallback strategies.

        Args:
            ip: IP address of the device to authenticate.
            discovered_device: Device object from discovery (may be None).

        Authentication strategy:
        1. Try using the discovered device object directly
        2. If that fails, create new connection with credentials
        3. If credentials fail, try without authentication
        4. Handle specific device types (SmartDevice vs legacy)

        The method implements exponential backoff and handles various
        error conditions including:
        - Connection timeouts
        - Authentication failures
        - Network connectivity issues
        - Device-specific protocol requirements
        """
        # First try to use the discovered device directly
        if discovered_device:
            success = await KasaAPI.authenticate_discovered_device(
                discovered_device, self.tplink_username, self.tplink_password
            )
            if success:
                self.devices[ip] = discovered_device
                self._check_and_add_emeter_device(ip, discovered_device)
                device_name = get_device_name(discovered_device)
                hostname = await get_hostname_cached(ip)
                # Show details on first run at INFO level
                if not self.first_discovery_complete:
                    self.logger.info(
                        "Authenticated device: %s (IP: %s, Host: %s)",
                        device_name,
                        ip,
                        hostname,
                    )
                else:
                    self.logger.debug(
                        "Authenticated device: %s (IP: %s, Host: %s)",
                        device_name,
                        ip,
                        hostname,
                    )
                return
            else:
                # If it's a SmartDevice that failed, don't try legacy connection
                if discovered_device.__class__.__name__ == "SmartDevice":
                    self.logger.warning(
                        "SmartDevice at %s couldn't be connected. "
                        "This device may require newer protocol support.",
                        ip,
                    )
                    return

        # Fallback to creating new connection if discovered device fails
        for attempt in range(1, self.max_retries + 1):
            try:
                # Add timeout for authentication process
                authenticated_device = await asyncio.wait_for(
                    KasaAPI.get_device(ip, self.tplink_username, self.tplink_password),
                    timeout=self.timeout_seconds,
                )

                # If authentication is successful, store the device
                self.devices[ip] = authenticated_device
                self._check_and_add_emeter_device(ip, authenticated_device)
                device_name = get_device_name(authenticated_device)
                hostname = await get_hostname_cached(ip)
                # Show details on first run at INFO level
                if not self.first_discovery_complete:
                    self.logger.info(
                        "Authenticated device: %s (IP: %s, Host: %s)",
                        device_name,
                        ip,
                        hostname,
                    )
                else:
                    self.logger.debug(
                        "Authenticated device: %s (IP: %s, Host: %s)",
                        device_name,
                        ip,
                        hostname,
                    )
                return  # Exit if authentication succeeds

            except TimeoutError:
                self.logger.warning(
                    "Timeout authenticating %s. Retry %s/%s",
                    ip,
                    attempt,
                    self.max_retries,
                )
            except Exception as e:
                # Check if it's a credentials error specifically
                error_msg = str(e)
                if (
                    "credentials" in error_msg.lower()
                    or "authentication" in error_msg.lower()
                    or "challenge" in error_msg.lower()
                ):
                    self.logger.warning(
                        "Device %s requires authentication. Attempting without credentials...",
                        ip,
                    )
                    # Don't retry for credential errors
                    break
                elif "connection reset" in error_msg.lower():
                    self.logger.warning(
                        "Device %s reset connection. It may be offline or unreachable. Retry %s/%s",
                        ip,
                        attempt,
                        self.max_retries,
                    )
                else:
                    self.logger.warning(
                        "Failed to auth %s: %s. Retry %s/%s",
                        ip,
                        e,
                        attempt,
                        self.max_retries,
                    )

        # After max retries or credential failure, try without authentication
        try:
            # Try to connect without credentials as some devices may not require them
            unauthenticated_device = await KasaAPI.get_device(ip)
            self.devices[ip] = unauthenticated_device
            self._check_and_add_emeter_device(ip, unauthenticated_device)
            device_name = get_device_name(unauthenticated_device)
            hostname = await get_hostname_cached(ip)
            # Show details on first run at INFO level
            if not self.first_discovery_complete:
                self.logger.info(
                    "Connected without auth: %s (IP: %s, Host: %s)",
                    device_name,
                    ip,
                    hostname,
                )
            else:
                self.logger.debug(
                    "Connected without auth: %s (IP: %s, Host: %s)",
                    device_name,
                    ip,
                    hostname,
                )
        except Exception as e:
            error_msg = str(e)
            if "connection reset" in error_msg.lower():
                self.logger.exception(
                    "Device %s is unreachable (connection reset). "
                    "It may be offline, blocked by firewall, or have networking issues.",
                    ip,
                )
            elif "challenge" in error_msg.lower():
                self.logger.exception(
                    "Device %s requires TP-Link cloud credentials. "
                    "Please set KASA_COLLECTOR_TPLINK_USERNAME and "
                    "KASA_COLLECTOR_TPLINK_PASSWORD.",
                    ip,
                )
            else:
                self.logger.exception("Failed to connect to device %s: %s", ip, e)

    async def remove_missing_devices(
        self, discovered_devices: dict[str, Device]
    ) -> None:
        """Remove devices that are no longer discovered on the network.

        Args:
            discovered_devices: Dictionary of currently discovered devices.

        Only removes devices if KASA_COLLECTOR_KEEP_MISSING_DEVICES is False.
        This allows handling of temporarily offline devices vs permanently
        removed devices based on configuration preference.
        """
        if Config.KASA_COLLECTOR_KEEP_MISSING_DEVICES:
            return
        for ip in list(self.devices.keys()):
            # Never prune manually-configured devices: they won't appear in a
            # broadcast discovery result (e.g. cross-subnet), so their absence
            # there doesn't mean they're gone.
            if ip in self.device_hosts:
                continue
            if ip not in discovered_devices:
                missing_device = self.devices.pop(ip)
                device_name = get_device_name(missing_device)
                self.emeter_devices.pop(
                    ip, None
                )  # Remove from emeter devices if applicable
                self.polling_devices.pop(
                    ip, None
                )  # Remove from polling devices if applicable
                hostname = await get_hostname_cached(ip)
                self.logger.warning(
                    "Device removed (no longer discovered): %s (IP: %s, Host: %s)",
                    device_name,
                    ip,
                    hostname,
                )

    def _check_and_add_emeter_device(self, ip: str, device: Device) -> None:
        """Check device capabilities and add to appropriate registries.

        Args:
            ip: IP address of the device.
            device: Device object to check.

        Examines the device for energy monitoring (emeter) capabilities
        and adds it to the appropriate registries. Devices with emeter
        are added to both emeter_devices and polling_devices registries.
        """
        if hasattr(device, "has_emeter") and device.has_emeter:
            self.emeter_devices[ip] = device
            self.polling_devices[ip] = (
                device  # Initially, only emeter devices get polled
            )

            # Log device emeter functionality as DEBUG
            device_name = get_device_name(device)
            self.logger.debug(
                "Device %s (IP: %s) supports emeter functionality.", device_name, ip
            )
        else:
            device_name = get_device_name(device)
            self.logger.debug("Device %s (IP: %s) no emeter support.", device_name, ip)

    async def disconnect_all_devices(self) -> None:
        """Disconnect from all devices during shutdown.

        Performs graceful disconnection from all managed devices,
        closing transport connections and clearing all registries.
        Uses concurrent disconnection for efficiency.

        This method should be called during application shutdown to
        ensure all resources are properly released.
        """
        self.logger.info("Disconnecting from %s devices...", len(self.devices))
        disconnect_tasks = []

        for ip, device in self.devices.items():
            try:
                disconnect_tasks.append(KasaAPI.disconnect_device(device))
            except Exception as e:
                self.logger.debug("Error preparing disconnect for %s: %s", ip, e)

        if disconnect_tasks:
            # Disconnect all devices concurrently
            await asyncio.gather(*disconnect_tasks, return_exceptions=True)

        self.devices.clear()
        self.emeter_devices.clear()
        self.polling_devices.clear()
        self.logger.info("All devices disconnected")
