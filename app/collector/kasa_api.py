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
import logging
import socket
from typing import Any

from kasa import Credentials, Device, DeviceConfig, DeviceEncryptionType, Discover

from app.collector.kasa_compat import reclass_strip_if_needed
from app.collector.utils import energy_status
from app.core.config import Config

logger = logging.getLogger("KasaAPI")

# Seconds a hostname lookup may take before the connection attempt gives up.
RESOLVE_TIMEOUT = 5.0


class InsecureLoginRefused(Exception):
    """The device would receive the TP-Link password in a recoverable form.

    An AES device logs in with the password as ``base64(password)`` unless it speaks
    login version 2, and the device chooses both the login version (in its discovery
    reply) and the session key. A responder that is not listed in
    KASA_COLLECTOR_DEVICE_HOSTS is therefore never handed credentials over that login.
    """

    def __init__(self, host: str) -> None:
        super().__init__(f"{host} advertises an AES login that sends the password")
        self.host = host


def _sends_recoverable_password(device: Device) -> bool:
    """Whether logging in to ``device`` would send the password itself, base64-encoded."""
    connection = device.config.connection_type
    return (
        connection.encryption_type is DeviceEncryptionType.Aes
        and connection.login_version != 2
    )


async def _close_quietly(device: Device) -> None:
    """Close a device's transport, swallowing any error.

    A discovered device whose probe failed still holds an open aiohttp session; left
    to garbage collection the event loop logs ``Unclosed client session`` / ``Unclosed
    connector``. Closing it here is cleanup on an object we are about
    to drop, so a failure to close is itself nothing to act on.
    """
    try:
        await device.disconnect()
    # swallowed-exceptions: HANDLED -- this is best-effort cleanup of an object being
    # discarded; the only consequence of a failure is the very log line we are avoiding.
    except Exception as close_error:
        logger.debug(
            "Error closing %s during cleanup: %s",
            getattr(device, "host", "?"),
            close_error,
        )


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

        # No credentials here: this is the broadcast ENUMERATION. Passing the TP-Link
        # username and password to Discover.discover makes python-kasa run a credentialed
        # handshake with every device that answers the broadcast, which hands the account's
        # credentials to any responder, a rogue LAN device included. The credentialed
        # handshake is done per device, only for ones the operator listed or trusts, by
        # DeviceManager._authenticate_device_with_retry. IOT
        # devices need no credentials and come back fully usable from enumeration alone.
        devices: dict[str, Device] = await Discover.discover(
            discovery_timeout=discovery_timeout,
            discovery_packets=discovery_packets,
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
    ) -> Device | None:
        """Verify and authenticate a discovered device.

        Args:
            device: Device object from discovery.
            username: Optional TP-Link account username.
            password: Optional TP-Link account password.

        Returns:
            The device ready for use, or None if it is not. Store the RETURNED object:
            a multi-outlet IOT device that discovery built as IotPlug comes back rebuilt
            as IotStrip (python-kasa#1748 -- discovery still classes by family), which
            is the only way its per-outlet emeter is collected.

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
                return await reclass_strip_if_needed(device)

            # A SmartDevice (HTTP/HTTPS, KLAP) reports no state without credentials, and
            # the discovery object carries none. Probe it as-is: a listed
            # or trusted one is then reconnected WITH credentials by the caller, so the
            # probe failing here is routine, not an error -- keep it at debug.
            elif protocol == "SmartDevice":
                logger.debug(
                    "SmartDevice %s detected; probing without credentials.", device.host
                )
                try:
                    await device.update()
                    return device
                # swallowed-exceptions: HANDLED -- this is a capability PROBE, not an
                # operation. The None return IS the handling: it means "this device does
                # not speak the protocol we just tried", which the caller branches on. An
                # exception here is the expected negative result, not a failure to report.
                except Exception as smart_error:
                    logger.debug("SmartDevice update failed: %s", smart_error)
                    await _close_quietly(device)
                    return None

            # Unknown device type
            else:
                logger.warning("Unknown device protocol: %s", protocol)
                await device.update()
                return device

        except Exception as e:
            error_type = type(e).__name__
            # A connection error gets the actionable network hint; anything else is
            # reported with its type, so a device that never verifies is visible.
            if "Connect call failed" in str(e) or "Connection reset" in str(e):
                logger.warning(
                    "Device %s appears to be discovered but not "
                    "connectable (%s: %s). "
                    "It may be on a different VLAN or have firewall rules.",
                    device.host,
                    error_type,
                    e,
                )
            else:
                logger.info(
                    "Failed to verify discovered device %s: %s: %s",
                    device.host,
                    error_type,
                    e,
                )
            await _close_quietly(device)
            return None

    @staticmethod
    async def get_device(
        ip_or_hostname: str,
        username: str | None = None,
        password: str | None = None,
        *,
        require_hashed_login: bool = False,
    ) -> Device:
        """Connect to a Kasa device by IP address or hostname.

        Args:
            ip_or_hostname: IP address or hostname of the device.
            username: Optional TP-Link account username.
            password: Optional TP-Link account password.
            require_hashed_login: Refuse to send the credentials to a device whose
                discovery reply asks for an AES login other than version 2, which sends
                the password base64-encoded under a key the device chooses. Set for a
                device the operator did not list.

        Returns:
            Connected device object ready for use.

        Raises:
            socket.gaierror: If hostname resolution fails.
            InsecureLoginRefused: If ``require_hashed_login`` is set and the device asks
                for a login that sends the password.
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
            # Bounded: a resolver that never answers must not hold the caller's pass.
            loop = asyncio.get_running_loop()
            async with asyncio.timeout(RESOLVE_TIMEOUT):
                result = await loop.getaddrinfo(
                    ip_or_hostname, None, family=socket.AF_INET
                )
            ip = str(result[0][4][0])  # Extract IP address (sockaddr[0]) from result
        except socket.gaierror, TimeoutError:
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
                if (
                    require_hashed_login
                    and username
                    and password
                    and _sends_recoverable_password(device)
                ):
                    await _close_quietly(device)
                    raise InsecureLoginRefused(ip)
                await device.update()
                logger.debug(
                    "Connected to device via discovery: %s (IP: %s)",
                    device.alias if device.alias else device.model,
                    ip,
                )
                # discover_single classes an IOT device by family, as broadcast
                # discovery does: a KLAP strip arrives as an IotPlug here too.
                return await reclass_strip_if_needed(device)
        except InsecureLoginRefused:
            raise
        except asyncio.CancelledError:
            # Cancelled after discovery built a client: close it, then stop.
            if device is not None:
                await _close_quietly(device)
            raise
        # swallowed-exceptions: HANDLED by a real fallback -- discovery is strategy 1 of 3
        # (see this method's docstring); failure falls through to Device.connect below, which
        # is the path that serves cross-subnet and manually-configured hosts. If every
        # strategy fails, THAT raises. Not a dropped error: a tried-and-rejected branch.
        except Exception as discover_error:
            logger.debug("discover_single failed for %s: %s", ip, discover_error)
            # The device discovery returned may already hold an open HTTP session (its
            # update() got as far as the handshake). Close it before the fallback replaces
            # it, or the event loop logs "Unclosed client session" when it is collected.
            if device is not None:
                await _close_quietly(device)
                device = None
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

            # A KLAP-only strip found by DISCOVERY arrives from python-kasa as a plain
            # IotPlug with no children (python-kasa#1748; Device.connect is fixed as of
            # 0.11). sys_info is populated by the update above, so this is where the
            # multi-outlet case is detected and corrected, whatever the entry point.
            device = await reclass_strip_if_needed(device)

            # Check if the device has emeter capability
            if device.has_emeter:
                logger.debug("Device %s supports emeter functionality.", device.alias)
            else:
                logger.debug(
                    "Device %s does not support emeter functionality.", device.alias
                )

        except asyncio.CancelledError:
            # A client already built (its update still in flight) is closed, not left.
            if device is not None:
                await _close_quietly(device)
            raise
        except Exception as e:
            logger.exception("Failed to connect to device %s: %s", ip, e)
            # A client that connected but failed its update or re-class holds an open
            # session: close it before the error goes to the caller.
            if device is not None:
                await _close_quietly(device)
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
        emeter: dict[str, Any] = energy_status(device)
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
            data["emeter"] = energy_status(device)
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
        # swallowed-exceptions: HANDLED -- reverse DNS is a decorative label and the method's
        # docstring states the contract ("Failures are logged but don't raise"). A LAN host
        # with no PTR record is the normal case, not an error worth propagating.
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
        # swallowed-exceptions: teardown on the shutdown path, and re-raising here would
        # actively cause harm -- disconnect_device is called from cleanup that often runs while
        # an ORIGINAL exception is propagating, so raising would replace the real cause with a
        # teardown artifact. Deliberately broad for the same reason as _close_client.
        except Exception as e:
            # Log but don't re-raise to avoid masking original errors
            logger.debug(
                "Error disconnecting from %s: %s", getattr(device, "host", "unknown"), e
            )
