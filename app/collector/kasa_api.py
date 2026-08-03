"""Kasa device API wrapper for communication with TP-Link smart devices.

This module provides a high-level interface for discovering, connecting to,
and communicating with TP-Link Kasa smart devices. It wraps the python-kasa
library and adds additional functionality specific to the Kasa Collector.

Key features:
    - Device discovery on local network and cross-subnet
    - Authentication handling with retry logic
    - Support for both IOT (legacy) and SMART (newer) protocols
    - Energy meter (emeter) data collection
    - System information retrieval
    - Proper connection lifecycle management
    - Async DNS resolution for hostnames

Supported device types:
    - Smart plugs (HS100, HS103, HS105, HS110, etc.)
    - Smart power strips (HS300, KP303, etc.)
    - Smart bulbs and dimmers
    - Newer SMART protocol devices (KP125M, etc.)

The module handles protocol differences between device families transparently,
providing a unified interface for the rest of the application.
"""

import asyncio
import socket
from typing import Any

from kasa import Credentials, Device, DeviceConfig, Discover

from app.core.config import Config
from app.utils.logging import setup_logger

logger = setup_logger("KasaAPI", Config.KASA_COLLECTOR_LOG_LEVEL_KASA_API)


class KasaAPI:
    """Static API wrapper for Kasa device operations.

    All methods are static to provide a stateless interface for device
    operations. This design allows multiple components to use the API
    without managing instance state.

    Attributes:
        _first_discovery_complete: Class variable to track if initial
                                  discovery has been performed for logging.
    """

    _first_discovery_complete = False  # Class variable to track first discovery

    @staticmethod
    async def discover_devices() -> dict[str, Device]:
        """Discover all Kasa devices on the local network.

        Returns:
            Dictionary mapping IP addresses to device objects.

        Uses broadcast discovery to find devices on the same subnet.
        Includes credentials in discovery packets for devices that require
        authentication. Discovery timeout and packet count are configurable.

        Note:
            First discovery logs at INFO level, subsequent at DEBUG.
            Device capabilities (like emeter) are not verified during
            discovery - that happens during authentication.
        """
        discovery_timeout = Config.KASA_COLLECTOR_DISCOVERY_TIMEOUT
        discovery_packets = Config.KASA_COLLECTOR_DISCOVERY_PACKETS

        # Include credentials in discovery for devices that need them
        username = Config.KASA_COLLECTOR_TPLINK_USERNAME
        password = Config.KASA_COLLECTOR_TPLINK_PASSWORD

        devices: dict[str, Device] = await Discover.discover(
            discovery_timeout=discovery_timeout,
            discovery_packets=discovery_packets,
            username=username,
            password=password,
        )
        logger.info("Discovered %s devices", len(devices))

        # Log each device discovered, but avoid mentioning emeter until authenticated
        for device in devices.values():
            device_info = await KasaAPI.get_device_info(device)
            # Add debugging info about device type and protocol
            device_type = getattr(device, "device_type", "unknown")
            device_family = getattr(device, "family", "unknown")
            protocol = device.__class__.__name__

            # Show details at INFO level for first discovery
            if not KasaAPI._first_discovery_complete:
                logger.info(
                    "Discovered: %s, IP: %s, DNS: %s, Type: %s, Family: %s, Protocol: %s",
                    device_info["alias"],
                    device_info["ip"],
                    device_info["dns_name"],
                    device_type,
                    device_family,
                    protocol,
                )
            else:
                logger.debug(
                    "Discovered: %s, IP: %s, DNS: %s, Type: %s, Family: %s, Protocol: %s",
                    device_info["alias"],
                    device_info["ip"],
                    device_info["dns_name"],
                    device_type,
                    device_family,
                    protocol,
                )

        # Mark first discovery as complete
        KasaAPI._first_discovery_complete = True
        return devices

    @staticmethod
    async def authenticate_discovered_device(
        device: Device, username: str | None = None, password: str | None = None
    ) -> bool:
        """Verify and authenticate a discovered device.

        Args:
            device: Device object from discovery.
            username: Optional TP-Link account username.
            password: Optional TP-Link account password.

        Returns:
            True if device is ready for use, False otherwise.

        Different device types require different handling:
        - IOT devices: Already authenticated during discovery
        - SMART devices: May use HTTP/HTTPS, limited support

        The method attempts to update the device to verify connectivity
        and readiness for data collection.
        """
        try:
            # Log device details for debugging
            device_type = getattr(device, "device_type", "unknown")
            device_family = getattr(device, "family", "unknown")
            protocol = device.__class__.__name__
            logger.debug(
                "Checking device %s - Type: %s, Family: %s, Protocol: %s",
                device.host,
                device_type,
                device_family,
                protocol,
            )

            # IOT devices (IotPlug, IotStrip) are already discovered with credentials
            # They don't need additional authentication
            if protocol in ["IotPlug", "IotStrip", "IotBulb", "IotDimmer"]:
                # Just update to ensure it's working
                await device.update()
                logger.debug("IOT device ready: %s (IP: %s)", device.alias, device.host)
                return True

            # SmartDevice needs special handling - it might need HTTP/HTTPS
            elif protocol == "SmartDevice":
                logger.warning(
                    "SmartDevice %s detected. This device type may use "
                    "HTTP/HTTPS protocol and might not be fully supported yet.",
                    device.host,
                )
                # Try to update anyway
                try:
                    await device.update()
                    return True
                except Exception as smart_error:
                    logger.debug("SmartDevice update failed: %s", smart_error)
                    return False

            # Unknown device type
            else:
                logger.warning("Unknown device protocol: %s", protocol)
                await device.update()
                return True

        except Exception as e:
            error_type = type(e).__name__
            logger.debug(
                "Failed to verify discovered device %s: %s: %s",
                device.host,
                error_type,
                e,
            )
            # Check if it's a connection error that we should handle differently
            if "Connect call failed" in str(e) or "Connection reset" in str(e):
                logger.warning(
                    "Device %s appears to be discovered but not "
                    "connectable. "
                    "It may be on a different VLAN or have firewall rules.",
                    device.host,
                )
            return False

    @staticmethod
    async def get_device(
        ip_or_hostname: str, username: str | None = None, password: str | None = None
    ) -> Device:
        """Connect to a Kasa device by IP address or hostname.

        Args:
            ip_or_hostname: IP address or hostname of the device.
            username: Optional TP-Link account username.
            password: Optional TP-Link account password.

        Returns:
            Connected device object ready for use.

        Raises:
            socket.gaierror: If hostname resolution fails.
            Exception: If connection fails after all retry attempts.

        Connection strategy:
        1. Resolve hostname to IP if needed
        2. Try discover_single for cross-subnet compatibility
        3. Fallback to direct Device.connect if discovery fails
        4. Try with credentials first, then without if that fails

        This multi-strategy approach maximizes compatibility across
        different device types and network configurations.
        """
        try:
            # Resolve hostname to IP if necessary using async DNS resolution
            loop = asyncio.get_running_loop()
            result = await loop.getaddrinfo(ip_or_hostname, None, family=socket.AF_INET)
            ip = str(result[0][4][0])  # Extract IP address (sockaddr[0]) from result
        except socket.gaierror:
            logger.exception("Failed to resolve hostname: %s", ip_or_hostname)
            raise

        device = None

        # First try discover_single for better cross-subnet compatibility
        # This properly detects device type and protocol
        try:
            logger.debug("Attempting discover_single for %s", ip)
            device = await Discover.discover_single(
                ip,
                credentials=Credentials(username=username, password=password)
                if username and password
                else None,
            )
            if device:
                await device.update()
                logger.debug(
                    "Connected to device via discovery: %s (IP: %s)",
                    device.alias if device.alias else device.model,
                    ip,
                )
                return device
        except Exception as discover_error:
            logger.debug("discover_single failed for %s: %s", ip, discover_error)
            # Fall through to try Device.connect

        try:
            # Fallback to direct connection if discovery fails
            if username and password:
                # Create config with credentials for authenticated devices
                credentials = Credentials(username=username, password=password)
                config = DeviceConfig(
                    host=ip,
                    credentials=credentials,
                    timeout=Config.KASA_COLLECTOR_AUTH_TIMEOUT,
                )
                try:
                    device = await Device.connect(config=config)
                    logger.debug(
                        "Connected to authenticated device: %s (IP: %s)",
                        device.alias if device.alias else device.model,
                        ip,
                    )
                except Exception as auth_error:
                    logger.warning("Failed to connect with credentials: %s", auth_error)
                    # Try without credentials as fallback
                    try:
                        device = await Device.connect(host=ip)
                        logger.debug(
                            "Connected to device without authentication: %s (IP: %s)",
                            device.alias if device.alias else device.model,
                            ip,
                        )
                    except Exception as fallback_error:
                        logger.exception(
                            "Failed to connect without credentials: %s", fallback_error
                        )
                        raise
            else:
                # Connect without credentials for devices without authentication
                device = await Device.connect(host=ip)
                logger.debug(
                    "Connected to device: %s (IP: %s)",
                    device.alias if device.alias else device.model,
                    ip,
                )

            # Ensure full initialization by calling update
            await device.update()

            # Check if the device has emeter capability
            if device.has_emeter:
                logger.debug("Device %s supports emeter functionality.", device.alias)
            else:
                logger.debug(
                    "Device %s does not support emeter functionality.", device.alias
                )

        except Exception as e:
            logger.exception("Failed to connect to device %s: %s", ip, e)
            raise

        return device

    @staticmethod
    async def fetch_emeter_data(device: Device) -> dict[str, Any]:
        """Fetch energy meter data from a device.

        Args:
            device: Connected device object.

        Returns:
            Dictionary of emeter realtime data, or empty dict if not supported.

        Updates the device state before fetching to ensure fresh data.
        Handles devices without emeter capability gracefully.
        """
        await device.update()
        if not device.has_emeter:
            logger.warning(
                "Device %s does not support emeter functionality.", device.model
            )
            return {}
        logger.debug("Fetched emeter data for device %s", device.model)
        emeter: dict[str, Any] = device.emeter_realtime
        return emeter

    @staticmethod
    async def fetch_sysinfo(device: Device) -> dict[str, Any]:
        """Fetch system information from a device.

        Args:
            device: Connected device object.

        Returns:
            Dictionary of system information, or empty dict if not supported.

        System info includes device model, firmware version, hardware info,
        and configuration. Updates device state before fetching.
        """
        await device.update()
        if not hasattr(device, "sys_info"):
            logger.warning(
                "Device %s does not support sysinfo functionality.", device.model
            )
            return {}
        logger.debug("Fetched sysinfo for device %s", device.model)
        sys_info: dict[str, Any] = device.sys_info
        return sys_info

    @staticmethod
    async def fetch_device_data(device: Device) -> dict[str, Any]:
        """Fetch all available data from a device.

        Args:
            device: Connected device object.

        Returns:
            Dictionary containing both emeter and sys_info data if available.

        Convenience method to fetch all device data in one call.
        More efficient than calling fetch_emeter_data and fetch_sysinfo
        separately as it only updates the device once.
        """
        await device.update()
        logger.debug("Fetched device data for %s", device.model)
        data: dict[str, Any] = {}
        if device.has_emeter:
            data["emeter"] = device.emeter_realtime
        if hasattr(device, "sys_info"):
            data["sys_info"] = device.sys_info
        return data

    @staticmethod
    async def _async_dns_lookup(ip: str) -> str | tuple[str, str]:
        """Perform async reverse DNS lookup for an IP address.

        Args:
            ip: IP address to look up.

        Returns:
            Hostname string or "unknown" if lookup fails.

        Uses the event loop's getaddrinfo for non-blocking DNS resolution.
        Failures are logged but don't raise exceptions.
        """
        loop = asyncio.get_event_loop()
        try:
            return await loop.getnameinfo((ip, 0), socket.NI_NAMEREQD)
        except Exception as e:
            logger.warning("DNS lookup failed for %s: %s", ip, e)
            return "unknown"

    @staticmethod
    async def get_device_info(device: Device) -> dict[str, Any]:
        """Extract device identification information.

        Args:
            device: Device object to get info from.

        Returns:
            Dictionary containing:
            - ip: Device IP address
            - alias: User-friendly name (falls back to model or "Unknown")
            - dns_name: Resolved hostname (or "unknown" if lookup fails)

        Handles missing attributes gracefully with appropriate fallbacks.
        DNS lookup failures don't prevent returning other information.
        """
        ip = device.host

        try:
            # Attempt DNS lookup
            dns_name = await KasaAPI._async_dns_lookup(ip)
        except Exception as e:
            logger.warning("DNS lookup failed for %s: %s", ip, e)
            dns_name = "unknown"

        try:
            # Use alias if available, otherwise fallback to model name or "unknown"
            alias = (
                device.alias
                if device.alias
                else (device.model if device.model else "Unknown")
            )
        except Exception as e:
            logger.warning("Failed to get alias for %s: %s", ip, e)
            alias = "unknown"

        return {"ip": ip, "alias": alias, "dns_name": dns_name}

    @staticmethod
    async def disconnect_device(device: Device | None) -> None:
        """Gracefully disconnect from a device.

        Args:
            device: Device object to disconnect from.

        Uses the official disconnect method to properly close connections
        and clean up resources. Errors during disconnection are logged
        but not raised to avoid masking original errors during shutdown.

        Safe to call with None or already disconnected devices.
        """
        if not device:
            return

        try:
            # Use the official disconnect method
            await device.disconnect()
            logger.debug(
                "Disconnected from device %s", getattr(device, "host", "unknown")
            )
        except Exception as e:
            # Log but don't re-raise to avoid masking original errors
            logger.debug(
                "Error disconnecting from %s: %s", getattr(device, "host", "unknown"), e
            )
