"""Configuration management for Kasa Collector.

This module handles all configuration settings for the Kasa Collector application,
loading values from environment variables with validation and type conversion.
It provides a centralized configuration class with all settings as class attributes.

The configuration includes settings for:
    - InfluxDB connection and batching
    - Device discovery and management
    - Data collection intervals
    - Authentication and timeouts
    - Logging levels
    - File output options
    - Health check parameters

All configuration values are loaded at module import time and validated. Invalid or
out-of-range optional values are clamped to their default with a warning (via
ConfigValidator) rather than crashing; genuinely required settings (InfluxDB
URL/token/org/bucket) are enforced at startup in app.main via REQUIRED_ENV_VARS.

Environment Variable Naming Convention:
    All environment variables follow the pattern: KASA_COLLECTOR_<SETTING_NAME>
    Example: KASA_COLLECTOR_INFLUXDB_URL, KASA_COLLECTOR_DATA_FETCH_INTERVAL
"""

import logging
import os

type ConfigValue = int | str | bool
type ConfigDict = dict[str, ConfigValue]


class ConfigValidator:
    """Validates and coerces configuration values with bounds checking.

    Fleet standard: parse and bounds-check each value, and on bad input WARN and
    fall back to the supplied default rather than crashing — a misconfigured
    optional knob shouldn't take the whole collector down. Genuinely required
    settings (InfluxDB URL/token/org/bucket) are enforced separately at startup in
    ``app.main`` via ``REQUIRED_ENV_VARS``.
    """

    VALID_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")

    @staticmethod
    def validate_int(
        value: str,
        min_val: int | None = None,
        max_val: int | None = None,
        default: int | None = None,
    ) -> int:
        try:
            num = int(value)
        except ValueError, TypeError:
            if default is not None:
                logging.warning(
                    "Value %r is not an integer, using default %s", value, default
                )
                return default
            raise ValueError(f"Invalid integer value: {value}") from None
        if (min_val is not None and num < min_val) or (
            max_val is not None and num > max_val
        ):
            if default is not None:
                logging.warning(
                    "Value %s out of range [%s, %s], using default %s",
                    num,
                    min_val,
                    max_val,
                    default,
                )
                return default
            raise ValueError(f"Value {num} out of range [{min_val}, {max_val}]")
        return num

    @staticmethod
    def validate_bool(value: str, default: bool | None = None) -> bool:
        low = value.lower()
        if low in ("true", "1", "yes", "on"):
            return True
        if low in ("false", "0", "no", "off"):
            return False
        if default is not None:
            logging.warning(
                "Invalid boolean value %r, using default %s", value, default
            )
            return default
        raise ValueError(f"Invalid boolean value: {value}")

    @staticmethod
    def validate_log_level(value: str, default: str = "INFO") -> str:
        upper = value.upper()
        if upper in ConfigValidator.VALID_LOG_LEVELS:
            return upper
        logging.warning("Invalid log level %r, using default %s", value, default)
        return default


def _get_bool_config(env_var: str, default: bool = False) -> bool:
    """Read a boolean env var through ConfigValidator (clamp-and-warn to default)."""
    return ConfigValidator.validate_bool(
        os.getenv(env_var, str(default).lower()), default
    )


def _get_int_config(env_var: str, default: int, min_value: int | None = None) -> int:
    """Read an integer env var through ConfigValidator (clamp-and-warn to default)."""
    return ConfigValidator.validate_int(
        os.getenv(env_var, str(default)), min_val=min_value, default=default
    )


def _get_log_level(env_var: str, default: str = "INFO") -> str:
    """Read a log-level env var through ConfigValidator (clamp-and-warn to default)."""
    return ConfigValidator.validate_log_level(os.getenv(env_var, default), default)


class Config:
    """Central configuration class for Kasa Collector.

    All configuration settings are loaded from environment variables at module
    import time. Settings are exposed as class attributes for easy access
    throughout the application.

    Configuration is organized into logical groups:
        - File Output: Local file writing options
        - Retry/Timeout: Connection and operation timeouts
        - Discovery: Device discovery intervals and settings
        - Data Collection: Polling intervals for different data types
        - InfluxDB: Database connection and batching settings
        - Logging: Component-specific log levels
        - Authentication: TP-Link account credentials
        - Health Check: Container health monitoring settings

    All settings have sensible defaults but can be overridden via environment
    variables. Integer settings are validated for minimum values where appropriate.

    Example:
        # Access configuration values
        from config import Config

        url = Config.KASA_COLLECTOR_INFLUXDB_URL
        interval = Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL
    """

    # File output settings
    KASA_COLLECTOR_WRITE_TO_FILE: bool = _get_bool_config(
        "KASA_COLLECTOR_WRITE_TO_FILE", default=False
    )
    """Enable writing collected data to local JSON files."""

    KASA_COLLECTOR_OUTPUT_DIR: str = os.getenv("KASA_COLLECTOR_OUTPUT_DIR", "output")
    """Directory path for output JSON files when file writing is enabled."""

    # Retry and timeout settings
    KASA_COLLECTOR_FETCH_MAX_RETRIES: int = _get_int_config(
        "KASA_COLLECTOR_FETCH_MAX_RETRIES", default=5, min_value=1
    )
    """Maximum number of retry attempts for device data fetching."""

    KASA_COLLECTOR_FETCH_RETRY_DELAY: int = _get_int_config(
        "KASA_COLLECTOR_FETCH_RETRY_DELAY", default=1, min_value=1
    )
    """Initial delay in seconds between retry attempts (uses exponential backoff)."""

    # Discovery settings
    KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL: int = _get_int_config(
        "KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL", default=300, min_value=1
    )
    """Interval in seconds between automatic device discovery attempts."""

    KASA_COLLECTOR_DISCOVERY_TIMEOUT: int = _get_int_config(
        "KASA_COLLECTOR_DISCOVERY_TIMEOUT", default=5, min_value=1
    )
    """Timeout in seconds for device discovery operations."""

    KASA_COLLECTOR_DISCOVERY_PACKETS: int = _get_int_config(
        "KASA_COLLECTOR_DISCOVERY_PACKETS", default=3, min_value=1
    )
    """Number of discovery packets to send during each discovery attempt."""

    # Data collection intervals
    KASA_COLLECTOR_DATA_FETCH_INTERVAL: int = _get_int_config(
        "KASA_COLLECTOR_DATA_FETCH_INTERVAL", default=15, min_value=1
    )
    """Interval in seconds for collecting energy meter data from devices."""

    KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL: int = _get_int_config(
        "KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL", default=60, min_value=1
    )
    """Interval in seconds for collecting system information from devices."""

    # Device management
    KASA_COLLECTOR_KEEP_MISSING_DEVICES: bool = _get_bool_config(
        "KASA_COLLECTOR_KEEP_MISSING_DEVICES", default=True
    )
    """Keep devices in memory even if they become unreachable during discovery."""

    # InfluxDB settings
    KASA_COLLECTOR_INFLUXDB_URL: str | None = os.getenv("KASA_COLLECTOR_INFLUXDB_URL")
    """URL for the InfluxDB instance (required)."""

    KASA_COLLECTOR_INFLUXDB_TOKEN: str | None = os.getenv(
        "KASA_COLLECTOR_INFLUXDB_TOKEN"
    )
    """Authentication token for InfluxDB (required)."""

    KASA_COLLECTOR_INFLUXDB_ORG: str | None = os.getenv("KASA_COLLECTOR_INFLUXDB_ORG")
    """Organization name for InfluxDB (required)."""

    KASA_COLLECTOR_INFLUXDB_BUCKET: str | None = os.getenv(
        "KASA_COLLECTOR_INFLUXDB_BUCKET"
    )
    """Bucket name for storing time-series data in InfluxDB (required)."""

    # InfluxDB writes are batched per poll cycle by the asyncio-native client — each
    # cycle's points go out in a single awaited request — so there is no batch-size
    # or flush-interval setting to configure.

    # Logging configuration
    KASA_COLLECTOR_LOG_LEVEL_KASA_API: str = _get_log_level(
        "KASA_COLLECTOR_LOG_LEVEL_KASA_API", default="INFO"
    )
    """Log level for Kasa API operations (device communication)."""

    KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE: str = _get_log_level(
        "KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE", default="INFO"
    )
    """Log level for InfluxDB storage operations."""

    KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR: str = _get_log_level(
        "KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR", default="INFO"
    )
    """Log level for main Kasa Collector orchestrator."""

    KASA_COLLECTOR_STRUCTURED_LOGS: bool = _get_bool_config(
        "KASA_COLLECTOR_STRUCTURED_LOGS", default=False
    )
    """Emit logs as structured JSON (for log aggregation) instead of colored console."""

    # Device configuration
    KASA_COLLECTOR_DEVICE_HOSTS: str | None = os.getenv(
        "KASA_COLLECTOR_DEVICE_HOSTS", None
    )
    """Comma-separated list of device IP addresses for manual configuration."""

    # TP-Link authentication
    KASA_COLLECTOR_TPLINK_USERNAME: str | None = os.getenv(
        "KASA_COLLECTOR_TPLINK_USERNAME", None
    )
    """TP-Link account username for devices requiring cloud authentication."""

    KASA_COLLECTOR_TPLINK_PASSWORD: str | None = os.getenv(
        "KASA_COLLECTOR_TPLINK_PASSWORD", None
    )
    """TP-Link account password for devices requiring cloud authentication."""

    KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY: bool = _get_bool_config(
        "KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY", default=True
    )
    """Enable automatic device discovery on the local network."""

    # Authentication settings
    KASA_COLLECTOR_AUTH_MAX_RETRIES: int = _get_int_config(
        "KASA_COLLECTOR_AUTH_MAX_RETRIES", default=3, min_value=1
    )
    """Maximum retry attempts for device authentication."""

    KASA_COLLECTOR_AUTH_TIMEOUT: int = _get_int_config(
        "KASA_COLLECTOR_AUTH_TIMEOUT", default=10, min_value=1
    )
    """Timeout in seconds for device authentication attempts."""

    # Operational timeouts
    KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT: int = _get_int_config(
        "KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT", default=5, min_value=1
    )
    """Timeout in seconds for cleaning up device transport connections."""

    KASA_COLLECTOR_SHUTDOWN_TIMEOUT: int = _get_int_config(
        "KASA_COLLECTOR_SHUTDOWN_TIMEOUT", default=10, min_value=1
    )
    """Maximum time in seconds to wait for graceful shutdown."""

    KASA_COLLECTOR_DNS_CACHE_TTL: int = _get_int_config(
        "KASA_COLLECTOR_DNS_CACHE_TTL", default=300, min_value=0
    )
    """Time-to-live in seconds for DNS cache entries (0 disables caching)."""

    KASA_COLLECTOR_MAX_RETRY_DELAY: int = _get_int_config(
        "KASA_COLLECTOR_MAX_RETRY_DELAY", default=60, min_value=1
    )
    """Maximum delay in seconds between retry attempts (for exponential backoff)."""

    # Health check settings
    KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE: int = _get_int_config(
        "KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE", default=120, min_value=1
    )
    """Maximum age in seconds for last successful data collection before health check fails."""


# Env vars the collector cannot start without (enforced at startup in app.main).
REQUIRED_ENV_VARS = [
    "KASA_COLLECTOR_INFLUXDB_URL",
    "KASA_COLLECTOR_INFLUXDB_TOKEN",
    "KASA_COLLECTOR_INFLUXDB_ORG",
    "KASA_COLLECTOR_INFLUXDB_BUCKET",
]


def describe_settings() -> dict[str, str]:
    """Effective config keyed by env-var name — single source of truth for the startup log.

    ``app.main`` logs this at startup (masking PASSWORD/TOKEN/USERNAME), so there is no
    hand-kept list of settings to drift out of sync with the actual configuration.
    """
    return {
        "KASA_COLLECTOR_INFLUXDB_URL": str(Config.KASA_COLLECTOR_INFLUXDB_URL),
        "KASA_COLLECTOR_INFLUXDB_ORG": str(Config.KASA_COLLECTOR_INFLUXDB_ORG),
        "KASA_COLLECTOR_INFLUXDB_BUCKET": str(Config.KASA_COLLECTOR_INFLUXDB_BUCKET),
        "KASA_COLLECTOR_INFLUXDB_TOKEN": str(Config.KASA_COLLECTOR_INFLUXDB_TOKEN),
        "KASA_COLLECTOR_TPLINK_USERNAME": str(Config.KASA_COLLECTOR_TPLINK_USERNAME),
        "KASA_COLLECTOR_TPLINK_PASSWORD": str(Config.KASA_COLLECTOR_TPLINK_PASSWORD),
        "KASA_COLLECTOR_DEVICE_HOSTS": str(Config.KASA_COLLECTOR_DEVICE_HOSTS),
        "KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY": str(
            Config.KASA_COLLECTOR_ENABLE_AUTO_DISCOVERY
        ),
        "KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL": str(
            Config.KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL
        ),
        "KASA_COLLECTOR_DISCOVERY_TIMEOUT": str(
            Config.KASA_COLLECTOR_DISCOVERY_TIMEOUT
        ),
        "KASA_COLLECTOR_DISCOVERY_PACKETS": str(
            Config.KASA_COLLECTOR_DISCOVERY_PACKETS
        ),
        "KASA_COLLECTOR_DATA_FETCH_INTERVAL": str(
            Config.KASA_COLLECTOR_DATA_FETCH_INTERVAL
        ),
        "KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL": str(
            Config.KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL
        ),
        "KASA_COLLECTOR_KEEP_MISSING_DEVICES": str(
            Config.KASA_COLLECTOR_KEEP_MISSING_DEVICES
        ),
        "KASA_COLLECTOR_FETCH_MAX_RETRIES": str(
            Config.KASA_COLLECTOR_FETCH_MAX_RETRIES
        ),
        "KASA_COLLECTOR_FETCH_RETRY_DELAY": str(
            Config.KASA_COLLECTOR_FETCH_RETRY_DELAY
        ),
        "KASA_COLLECTOR_MAX_RETRY_DELAY": str(Config.KASA_COLLECTOR_MAX_RETRY_DELAY),
        "KASA_COLLECTOR_AUTH_MAX_RETRIES": str(Config.KASA_COLLECTOR_AUTH_MAX_RETRIES),
        "KASA_COLLECTOR_AUTH_TIMEOUT": str(Config.KASA_COLLECTOR_AUTH_TIMEOUT),
        "KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT": str(
            Config.KASA_COLLECTOR_TRANSPORT_CLEANUP_TIMEOUT
        ),
        "KASA_COLLECTOR_SHUTDOWN_TIMEOUT": str(Config.KASA_COLLECTOR_SHUTDOWN_TIMEOUT),
        "KASA_COLLECTOR_DNS_CACHE_TTL": str(Config.KASA_COLLECTOR_DNS_CACHE_TTL),
        "KASA_COLLECTOR_WRITE_TO_FILE": str(Config.KASA_COLLECTOR_WRITE_TO_FILE),
        "KASA_COLLECTOR_OUTPUT_DIR": Config.KASA_COLLECTOR_OUTPUT_DIR,
        "KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE": str(
            Config.KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE
        ),
        "KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR": Config.KASA_COLLECTOR_LOG_LEVEL_KASA_COLLECTOR,
        "KASA_COLLECTOR_LOG_LEVEL_KASA_API": Config.KASA_COLLECTOR_LOG_LEVEL_KASA_API,
        "KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE": (
            Config.KASA_COLLECTOR_LOG_LEVEL_INFLUXDB_STORAGE
        ),
        "KASA_COLLECTOR_STRUCTURED_LOGS": str(Config.KASA_COLLECTOR_STRUCTURED_LOGS),
    }
