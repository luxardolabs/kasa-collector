"""Utility functions and helpers for the Kasa Collector application.

This module provides shared utilities used throughout the application,
including retry logic, device information helpers, and modern Python 3.13
patterns for improved error handling and type safety.

Key components:
    - async_retry: Decorator for automatic retry with exponential backoff
    - DeviceContext: Async context manager for device operations
    - Device information helpers for consistent naming and formatting
    - Type aliases for improved code clarity

The utilities emphasize reliability through proper error handling,
performance through async patterns, and maintainability through
clear abstractions.
"""

import asyncio
from collections.abc import Callable, Coroutine
from functools import wraps
from types import TracebackType
from typing import Any, ParamSpec, Self, TypeVar, cast

from kasa import Device

from app.collector.dns_cache import get_hostname_cached
from app.core.config import Config
from app.utils.logging import setup_logger

# Modern Python 3.13 type hints
P = ParamSpec("P")
T = TypeVar("T")

logger = setup_logger(__name__)


def get_device_name(device: Device) -> str:
    """Get a human-readable name for a device.

    Args:
        device: Kasa device object.

    Returns:
        Device alias if available, otherwise host/model/"Unknown Device".

    Tries multiple attributes in order of preference:
    1. alias - User-defined name
    2. host - IP address or hostname
    3. model - Device model number
    4. "Unknown Device" as final fallback

    Never raises exceptions - always returns a string.
    """
    try:
        if hasattr(device, "alias") and device.alias:
            return str(device.alias)
        elif hasattr(device, "host") and device.host:
            return str(device.host)
        elif hasattr(device, "model") and device.model:
            return str(device.model)
        else:
            return "Unknown Device"
    except Exception:
        return "Unknown Device"


def sanitize_tag(value: Any, maxlen: int = 128) -> str:
    """Make a device-supplied string safe to log and use as an InfluxDB tag.

    Devices control their own alias/nickname (user-settable, or arbitrary from a
    rogue device on the LAN). This strips non-printable characters — most importantly
    CR/LF, which would otherwise allow log-line forging — and caps the length to bound
    InfluxDB series cardinality from a misconfigured or hostile device.
    """
    if value is None:
        return "unknown"
    text = "".join(ch for ch in str(value) if ch.isprintable())
    if len(text) > maxlen:
        text = text[:maxlen]
    return text or "unknown"


def async_retry(
    max_retries: int = Config.KASA_COLLECTOR_FETCH_MAX_RETRIES,
    base_delay: float = Config.KASA_COLLECTOR_FETCH_RETRY_DELAY,
    exponential_backoff: bool = True,
    operation_name: str = "operation",
) -> Callable[
    [Callable[P, Coroutine[Any, Any, T]]], Callable[P, Coroutine[Any, Any, T]]
]:
    """Decorator for async functions with automatic retry logic.

    Args:
        max_retries: Maximum number of retry attempts (from config).
        base_delay: Initial delay between retries in seconds.
        exponential_backoff: If True, delay doubles with each retry.
        operation_name: Descriptive name for logging purposes.

    Returns:
        Decorator function that adds retry logic to async functions.

    Only transient network errors (ConnectionError, TimeoutError, OSError) are
    retried with exponential backoff. All other exceptions — data/logic errors
    (AttributeError, KeyError, ValueError, …) that are almost always bugs or bad
    payloads — propagate immediately instead of burning the whole retry budget
    every poll cycle.

    Delays are capped at KASA_COLLECTOR_MAX_RETRY_DELAY to prevent
    excessive wait times. Device information is extracted from function
    arguments when available for enhanced logging.

    Example:
        @async_retry(operation_name="device update")
        async def update_device(self, ip, device):
            await device.update()
    """

    def decorator(
        func: Callable[P, Coroutine[Any, Any, T]],
    ) -> Callable[P, Coroutine[Any, Any, T]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> T:
            retries = 0

            # Extract device info for better logging if available
            device_info = ""
            if len(args) >= 3:  # Assuming (self, ip, device) pattern
                try:
                    ip = str(args[1])
                    device = cast(Device, args[2])
                    device_name = get_device_name(device)
                    hostname = await get_hostname_cached(ip)
                    device_info = f" for {device_name} (IP: {ip}, Hostname: {hostname})"
                except Exception:
                    device_info = (
                        f" for device at {args[1] if len(args) > 1 else 'unknown'}"
                    )

            while retries < max_retries:
                try:
                    return await func(*args, **kwargs)

                # Only transient network errors are retried. Everything else
                # (data/logic bugs, unexpected exceptions) propagates immediately.
                except (ConnectionError, TimeoutError, OSError) as e:
                    retries += 1
                    if retries >= max_retries:
                        logger.warning(
                            "Max retries (%s) reached for %s%s: %s",
                            max_retries,
                            operation_name,
                            device_info,
                            e,
                        )
                        raise
                    delay = base_delay * (2**retries if exponential_backoff else 1)
                    # Cap delay at maximum configured value to prevent excessive waits
                    delay = min(delay, Config.KASA_COLLECTOR_MAX_RETRY_DELAY)
                    logger.warning(
                        "Network error during %s%s: %s — retrying in %.2fs (attempt %s/%s)",
                        operation_name,
                        device_info,
                        e,
                        delay,
                        retries,
                        max_retries,
                    )
                    await asyncio.sleep(delay)

            # This should never be reached, but satisfies type checkers
            raise RuntimeError(
                f"Unexpected end of retry loop in {operation_name}{device_info}"
            )

        return wrapper

    return decorator


class DeviceContext:
    """Async context manager for device operations.

    Provides structured error handling and logging for device operations,
    ensuring consistent logging of operation start/completion/failure.

    Attributes:
        device: The Kasa device object.
        ip: Device IP address.
        operation: Description of the operation being performed.
        device_name: Human-readable device name.
        hostname: Resolved hostname (set during __aenter__).

    Example:
        async with DeviceContext(device, ip, "data fetch") as ctx:
            data = await device.get_data()
            # Automatic logging of success/failure
    """

    def __init__(self, device: Device, ip: str, operation: str):
        """Initialize device context.

        Args:
            device: Kasa device object.
            ip: Device IP address.
            operation: Description of operation for logging.
        """
        self.device = device
        self.ip = ip
        self.operation = operation
        self.device_name = get_device_name(device)
        self.hostname: str | None = None

    async def __aenter__(self) -> Self:
        """Enter async context and prepare device info.

        Returns:
            Self for use in 'as' clause.

        Resolves hostname and logs operation start.
        """
        self.hostname = await get_hostname_cached(self.ip)
        logger.debug(
            "Starting %s for %s (IP: %s)", self.operation, self.device_name, self.ip
        )
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> bool:
        """Exit async context with appropriate logging.

        Args:
            exc_type: Exception type if error occurred.
            exc_val: Exception value if error occurred.
            exc_tb: Exception traceback if error occurred.

        Returns:
            False to propagate exceptions.

        Logs success or failure based on exception presence.
        """
        if exc_type is asyncio.CancelledError:
            # Clean shutdown cancels in-flight operations — not an error.
            logger.debug(
                "%s for %s (IP: %s) cancelled",
                self.operation,
                self.device_name,
                self.ip,
            )
        elif exc_type is not None:
            logger.error(
                "Error during %s for %s (IP: %s): %s",
                self.operation,
                self.device_name,
                self.ip,
                exc_val,
            )
        else:
            logger.debug(
                "Successfully completed %s for %s (IP: %s)",
                self.operation,
                self.device_name,
                self.ip,
            )
        return False  # Don't suppress exceptions


def format_duration(seconds: float) -> str:
    """Format duration in seconds to human-readable string.

    Args:
        seconds: Duration in seconds.

    Returns:
        Formatted string like "2.50 seconds", "3 minutes, 45.2 seconds",
        or "1 hours, 30 minutes, 15.5 seconds".

    Automatically selects appropriate units based on duration length.
    """
    if seconds < 60:
        return f"{seconds:.2f} seconds"

    minutes, secs = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)} minutes, {secs:.1f} seconds"

    hours, mins = divmod(minutes, 60)
    return f"{int(hours)} hours, {int(mins)} minutes, {secs:.1f} seconds"


def format_device_info(device: Device, ip: str, hostname: str | None = None) -> str:
    """Format device information for logging.

    Args:
        device: Kasa device object.
        ip: Device IP address.
        hostname: Optional resolved hostname.

    Returns:
        Formatted string like "Living Room Plug (IP: 192.168.1.100, Hostname: plug.local)"
        or "Living Room Plug (IP: 192.168.1.100)" if hostname not provided.

    Uses modern f-string formatting for performance.
    """
    device_name = get_device_name(device)
    if hostname:
        return f"{device_name} (IP: {ip}, Hostname: {hostname})"
    return f"{device_name} (IP: {ip})"


# Type aliases for improved code clarity (Python 3.12+ syntax)
type DeviceMap = dict[str, Any]  # Mapping of IP addresses to device objects
type IPAddress = str  # String representation of IP address
type DeviceName = str  # Human-readable device name
