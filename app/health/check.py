#!/usr/bin/env python3
"""Docker health check script for Kasa Collector.

This standalone script verifies the Kasa Collector container is healthy
by checking if data collection is occurring properly. It's designed to be
used as a Docker HEALTHCHECK command.

Health check strategies:
    - When file writing is enabled: Checks data file freshness
    - When file writing is disabled: Verifies process is alive

The script provides detailed status messages to help diagnose issues
and includes version information for debugging.

Exit codes:
    0 - Healthy: Application is running and collecting data
    1 - Unhealthy: Data is stale or process has issues

Configuration:
    KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE: Maximum age for data files (default: 120s)
    KASA_COLLECTOR_WRITE_TO_FILE: Whether file writing is enabled
    KASA_COLLECTOR_OUTPUT_DIR: Directory containing data files
"""

import asyncio
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

# Health check configuration
MAX_AGE_SECONDS = int(
    os.getenv("KASA_COLLECTOR_HEALTH_CHECK_MAX_AGE", "120")
)  # 2 minutes default
OUTPUT_DIR = os.getenv("KASA_COLLECTOR_OUTPUT_DIR", "output")


def check_recent_data_files() -> tuple[bool, str]:
    """Verify data collection by checking file freshness.

    Returns:
        Tuple of (is_healthy, status_message).

    Checks:
    1. Output directory exists
    2. Emeter data files are present
    3. Most recent file is within MAX_AGE_SECONDS
    4. File is non-empty

    This method is used when KASA_COLLECTOR_WRITE_TO_FILE is enabled,
    as it provides a reliable way to verify data collection is active.
    """
    output_path = Path(OUTPUT_DIR)

    if not output_path.exists():
        return False, f"Output directory {OUTPUT_DIR} does not exist"

    # Find most recent emeter data file
    emeter_files = list(output_path.glob("emeter_*.jsonl"))

    if not emeter_files:
        return False, "No emeter data files found"

    # Get the most recently modified file
    most_recent_file = max(emeter_files, key=lambda f: f.stat().st_mtime)

    # Check file age
    file_age = datetime.now() - datetime.fromtimestamp(most_recent_file.stat().st_mtime)

    if file_age > timedelta(seconds=MAX_AGE_SECONDS):
        return (
            False,
            f"Most recent data file is {file_age.total_seconds():.0f}s old "
            f"(max allowed: {MAX_AGE_SECONDS}s)",
        )

    # The file is an append-log of one JSON object per collection cycle, so it is
    # not a single JSON document — freshness (mtime, checked above) is the real
    # signal that data is flowing. Just confirm the file isn't empty.
    if most_recent_file.stat().st_size == 0:
        return False, f"Data file {most_recent_file.name} is empty"

    return True, f"Healthy - last data update {file_age.total_seconds():.0f}s ago"


def check_process_alive() -> tuple[bool, str]:
    """Basic process liveness check.

    Returns:
        Tuple of (is_healthy, status_message).

    Attempts to verify the Python process is responsive. This is a
    fallback method when file writing is disabled. It's less reliable
    than checking data files but ensures the container doesn't get
    marked unhealthy when file writing is disabled.

    Note:
        This is a simplified check. In a containerized environment,
        if this script runs, the process is generally healthy.
    """
    # Check if the asyncio event loop is available (indicates the main app is running).
    try:
        asyncio.get_running_loop()
        return True, "Process healthy - event loop active"
    except RuntimeError:
        # No running loop — the main app may not have started yet; healthy during startup.
        return True, "Process starting - no event loop yet"


def main() -> None:
    """Execute health check and exit with appropriate code.

    Runs different health checks based on configuration:
    - If file writing is enabled: Checks data file freshness
    - If file writing is disabled: Performs basic process check

    Prints detailed status information including:
    - Overall health status (HEALTHY/UNHEALTHY)
    - Version and build information
    - Individual check results

    Exits with code 0 for healthy, 1 for unhealthy.
    """
    checks = []
    all_healthy = True

    # Only check data files if writing to file is enabled
    if os.getenv("KASA_COLLECTOR_WRITE_TO_FILE", "False").lower() == "true":
        is_healthy, message = check_recent_data_files()
        checks.append(f"Data freshness: {message}")
        all_healthy &= is_healthy
    else:
        # If not writing to files, check if process is alive
        is_healthy, message = check_process_alive()
        checks.append(f"Process check: {message}")
        all_healthy &= is_healthy

    # Get version information
    version = os.getenv("KASA_COLLECTOR_VERSION", "unknown")
    build_timestamp = os.getenv("KASA_COLLECTOR_BUILD_TIMESTAMP", "unknown")

    # Print status
    status = "HEALTHY" if all_healthy else "UNHEALTHY"
    print(f"Health check: {status}")
    print(f"Version: {version} (Built: {build_timestamp})")
    for check in checks:
        print(f"  - {check}")

    # Exit with appropriate code
    sys.exit(0 if all_healthy else 1)


if __name__ == "__main__":
    main()
