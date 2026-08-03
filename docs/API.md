# Kasa Collector API Documentation

This document describes the internal APIs and component interfaces of the Kasa Collector application.

The application is organized as an `app/` package. Key modules:

| Component | Module |
|-----------|--------|
| Main orchestrator | `app/main.py` |
| Configuration | `app/core/config.py` |
| Device manager | `app/collector/device_manager.py` |
| Kasa API wrapper | `app/collector/kasa_api.py` |
| Poller | `app/collector/poller.py` |
| DNS cache | `app/collector/dns_cache.py` |
| Shared utilities | `app/collector/utils.py` |
| InfluxDB storage | `app/storage/influxdb.py` |
| Health check | `app/health/check.py` |

Entrypoint: `python -m app.main`. Import example:

```python
from app.collector.kasa_api import KasaAPI
from app.core.config import Config
```

## Table of Contents

1. [Core Components](#core-components)
2. [Configuration API](#configuration-api)
3. [Device Manager API](#device-manager-api)
4. [Kasa API Wrapper](#kasa-api-wrapper)
5. [Poller API](#poller-api)
6. [Storage API](#storage-api)
7. [Utility Functions](#utility-functions)
8. [Health Check API](#health-check-api)

## Core Components

### KasaCollector

The main orchestrator class that manages all components (`app/main.py`).

```python
class KasaCollector:
    def __init__(self):
        """Initialize the collector with all components."""
        
    async def start(self) -> None:
        """Start all collector tasks and device discovery."""
        
    async def periodic_discover(self) -> None:
        """Periodically discover devices on the network."""
        
    async def shutdown(self) -> None:
        """Gracefully shutdown all tasks and close connections."""
```

#### Key Attributes
- `device_manager`: DeviceManager instance for device lifecycle
- `poller`: Poller instance for data collection
- `tasks`: Set of asyncio tasks for proper cleanup

## Configuration API

### Config Class

Static configuration class that reads from environment variables (`app/core/config.py`).

```python
class Config:
    # Required configurations
    KASA_COLLECTOR_INFLUXDB_URL: str
    KASA_COLLECTOR_INFLUXDB_TOKEN: str
    KASA_COLLECTOR_INFLUXDB_ORG: str
    KASA_COLLECTOR_INFLUXDB_BUCKET: str
    
    # Optional configurations with defaults
    KASA_COLLECTOR_DATA_FETCH_INTERVAL: int = 15
    KASA_COLLECTOR_SYSINFO_FETCH_INTERVAL: int = 60
    KASA_COLLECTOR_DEVICE_DISCOVERY_INTERVAL: int = 300
    # ... see app/core/config.py for full list


# Module-level helpers parse and validate environment variables:
def _get_int_config(env_var: str, default: int, min_value: int | None = None) -> int:
    """Safely parse integer configuration with optional minimum validation."""
```

## Device Manager API

### DeviceManager

Manages device discovery, authentication, and lifecycle (`app/collector/device_manager.py`).

```python
class DeviceManager:
    def __init__(self, logger: logging.Logger):
        """Initialize with empty device dictionaries."""
        
    async def initialize_manual_devices(self) -> None:
        """Initialize devices from KASA_COLLECTOR_DEVICE_HOSTS."""
        
    async def discover_devices(self) -> None:
        """Discover Kasa devices on the network."""
        
    async def remove_missing_devices(self, discovered_devices: dict) -> None:
        """Remove devices not found in discovery if configured."""
        
    async def get_device_list(self) -> dict[str, Device]:
        """Return all discovered and manual devices."""
        
    async def get_emeter_device_list(self) -> dict[str, Device]:
        """Return only devices with emeter capabilities."""

    async def disconnect_all_devices(self) -> None:
        """Disconnect from all tracked devices during shutdown."""
```

#### Device Dictionaries
- `devices`: All devices (manual + discovered)
- `emeter_devices`: Only devices with energy monitoring
- `polling_devices`: Devices actively being polled

## Kasa API Wrapper

### KasaAPI

Static wrapper around python-kasa library with enhanced error handling
(`app/collector/kasa_api.py`).

```python
class KasaAPI:
    @staticmethod
    async def discover_devices() -> dict[str, Device]:
        """Discover all Kasa devices on the network."""

    @staticmethod
    async def authenticate_discovered_device(
        device: Device,
        username: Optional[str] = None,
        password: Optional[str] = None,
    ) -> Device:
        """Authenticate a device returned by discovery (SMART family)."""

    @staticmethod
    async def get_device(
        ip_or_hostname: str, 
        username: Optional[str] = None,
        password: Optional[str] = None
    ) -> Device:
        """Get a device by IP/hostname with optional authentication."""
        
    @staticmethod
    async def fetch_emeter_data(device: Device) -> dict:
        """Fetch current energy monitoring data."""
        
    @staticmethod
    async def fetch_sysinfo(device: Device) -> dict:
        """Fetch device system information."""

    @staticmethod
    async def disconnect_device(device: Device) -> None:
        """Disconnect a device and release its transport resources."""
```

## Poller API

### Poller

Handles periodic data collection from devices (`app/collector/poller.py`).

```python
class Poller:
    def __init__(self, logger: logging.Logger):
        """Initialize with InfluxDB storage."""
        
    async def periodic_emeter_fetch(self, devices: dict[str, Device]) -> None:
        """Periodically fetch energy data at configured interval."""
        
    async def periodic_sysinfo_fetch(self, devices: dict[str, Device]) -> None:
        """Periodically fetch system info at configured interval."""
        
    @async_retry(operation_name="emeter data fetch")
    async def fetch_and_store_emeter_data(
        self, ip: str, device: Device
    ) -> None:
        """Fetch and store emeter data with retry logic."""
        
    @async_retry(operation_name="sysinfo fetch")  
    async def fetch_and_store_sysinfo(
        self, ip: str, device: Device
    ) -> None:
        """Fetch and store system info with retry logic."""
```

## Storage API

### InfluxDBStorage

Handles data persistence to InfluxDB (`app/storage/influxdb.py`).

```python
class InfluxDBStorage:
    def __init__(self):
        """Initialize InfluxDB client and validate connection."""

    async def write_data(
        self, measurement: str, data: dict, tags: dict | None = None
    ) -> None:
        """Build and queue a single measurement point."""

    async def process_emeter_data(self, device_data: dict[str, dict]) -> None:
        """Process and store energy monitoring data."""

    async def process_sysinfo_data(self, device_data: dict[str, dict]) -> None:
        """Process and store system information."""
        
    async def send_to_influxdb(self, points: list[Point]) -> None:
        """Batch write points to InfluxDB."""
        
    def close(self) -> None:
        """Close InfluxDB client connection."""
```

#### Data Format

Emeter data structure:
```python
{
    "voltage_mv": int,      # Voltage in millivolts
    "current_ma": int,      # Current in milliamps  
    "power_mw": int,        # Power in milliwatts
    "total_wh": int,        # Total energy in watt-hours
    "err_code": int         # Error code (0 = no error)
}
```

## Utility Functions

### DNS Cache

Defined in `app/collector/dns_cache.py`.

```python
class DNSCache:
    def __init__(self, ttl_seconds: Optional[int] = None):
        """Initialize with configurable TTL."""
        
    async def get_hostname(self, ip: str) -> str:
        """Get hostname with caching."""

async def get_hostname_cached(ip: str) -> str:
    """Global convenience function for DNS caching."""
```

### Retry Decorator

Defined in `app/collector/utils.py`, alongside `get_device_name`, `format_duration`,
`DeviceContext`, and `format_device_info`.

```python
@async_retry(
    max_retries=5,
    base_delay=1.0,
    exponential_backoff=True,
    operation_name="my operation"
)
async def my_function():
    """Function with automatic retry on failure."""
```

### Device Context Manager

```python
async with DeviceContext(device, ip, "operation name") as ctx:
    # Automatic error logging and device info tracking
    await device.update()
```

### Helper Functions

```python
def get_device_name(device: Device) -> str:
    """Get device name with fallback to host/model."""
    
def format_duration(seconds: float) -> str:
    """Format seconds into human-readable duration."""
```

## Health Check API

### Health Check Script

Standalone script for Docker health monitoring (`app/health/check.py`), invoked as
`python -m app.health.check`.

```python
def check_recent_data_files() -> tuple[bool, str]:
    """Check if recent data files exist (when file output enabled)."""
    
def check_process_alive() -> tuple[bool, str]:
    """Check if the main process is running."""
    
def main() -> None:
    """Main health check logic with exit codes."""
```

#### Exit Codes
- `0`: Healthy - Application running normally
- `1`: Unhealthy - Check failed

#### Configuration
- `KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE`: Maximum age for data files (default: 120s)
- `KASA_COLLECTOR_WRITE_TO_FILE`: Must be "True" for file-based health checks

## Error Handling

### Exception Types

The application handles these specific exception types:

1. **Network Errors**: `ConnectionError`, `TimeoutError`, `OSError`
2. **Data Errors**: `AttributeError`, `KeyError`, `ValueError`
3. **Async Errors**: `asyncio.CancelledError`, `asyncio.TimeoutError`
4. **Custom Errors**: `DeviceOperationError` (exception group)

### Retry Logic

All device operations use exponential backoff with:
- Base delay: 1 second (configurable)
- Maximum retries: 5 (configurable)
- Maximum delay: 60 seconds (configurable)
- Exponential factor: 2x

## Type Annotations

The codebase uses modern Python 3.14 type hints:

```python
# Type aliases
type DeviceMap = dict[str, Any]
type IPAddress = str
type DeviceName = str
type CacheEntry = tuple[str, float]

# Generic types
P = ParamSpec("P")
T = TypeVar("T")

# Coroutine types
Callable[P, Coroutine[Any, Any, T]]
```

## Async Patterns

### TaskGroup Usage

```python
async with asyncio.TaskGroup() as tg:
    for device in devices:
        tg.create_task(process_device(device))
# All tasks complete or exception raised
```

### Resource Cleanup

```python
try:
    # Operations
finally:
    await asyncio.wait_for(
        cleanup_resources(),
        timeout=Config.KASA_COLLECTOR_SHUTDOWN_TIMEOUT
    )
```

## Performance Considerations

1. **DNS Caching**: Reduces repeated lookups with 5-minute TTL
2. **Batch Writes**: InfluxDB writes are batched for efficiency
3. **Connection Pooling**: Reuses device connections where possible
4. **Concurrent Operations**: Uses TaskGroup for parallel device operations
5. **Timeout Protection**: All operations have configurable timeouts

---

*Last updated: 2026-07-11*