"""DNS caching module for efficient hostname resolution.

This module provides a caching layer for DNS lookups to avoid repeated
resolutions of the same IP addresses. It's particularly useful in the
Kasa Collector where devices are polled frequently and DNS lookups can
add significant latency.

Key features:
    - Async DNS resolution using thread pool executor
    - Configurable TTL for cache entries
    - Thread-safe cache operations with async locks
    - Automatic expiration of old entries
    - Fallback to IP address on lookup failure
    - Cache statistics for monitoring

The cache significantly reduces DNS query load and improves performance,
especially important when polling many devices at short intervals.
"""

import asyncio
import socket
import time

from app.core.config import Config
from app.utils.logging import setup_logger

type CacheEntry = tuple[str, float]  # (hostname, timestamp)
type CacheStats = dict[str, int | float]

logger = setup_logger(__name__)


class DNSCache:
    """Thread-safe DNS cache with TTL-based expiration.

    Caches hostname lookups to reduce DNS query load and latency.
    Particularly beneficial when polling devices frequently as it
    avoids repeated lookups for the same IP addresses.

    Attributes:
        cache: Dictionary mapping IP addresses to (hostname, timestamp) tuples.
        ttl_seconds: Time-to-live for cache entries in seconds.
        _lock: Async lock for thread-safe cache operations.

    The cache uses a simple TTL mechanism where entries expire after
    a configurable time period. Expired entries are removed on access
    or can be cleared explicitly.
    """

    def __init__(self, ttl_seconds: int | None = None):
        """Initialize DNS cache with configurable TTL.

        Args:
            ttl_seconds: Cache entry lifetime in seconds. If None,
                        uses KASA_COLLECTOR_DNS_CACHE_TTL from config.
                        Set to 0 to disable caching.
        """
        if ttl_seconds is None:
            ttl_seconds = Config.KASA_COLLECTOR_DNS_CACHE_TTL
        self.cache: dict[str, CacheEntry] = {}
        self.ttl_seconds = ttl_seconds
        self._lock = asyncio.Lock()

    async def get_hostname(self, ip: str) -> str:
        """Resolve IP address to hostname with caching.

        Args:
            ip: IP address to resolve.

        Returns:
            Resolved hostname or the original IP if lookup fails.

        Cache behavior:
        1. Check cache for non-expired entry
        2. If found, return cached hostname (cache hit)
        3. If not found or expired, perform DNS lookup
        4. Cache the result with current timestamp
        5. Return IP address as fallback on lookup failure

        Thread-safe through async lock usage.
        """
        current_time = time.time()

        async with self._lock:
            # Check cache first
            if ip in self.cache:
                hostname, timestamp = self.cache[ip]
                if current_time - timestamp < self.ttl_seconds:
                    logger.debug("DNS cache hit for %s: %s", ip, hostname)
                    return hostname
                else:
                    # Expired entry, remove it
                    del self.cache[ip]
                    logger.debug("DNS cache expired for %s", ip)

        # Cache miss or expired, perform lookup
        try:
            loop = asyncio.get_running_loop()
            hostname = await loop.run_in_executor(None, socket.getfqdn, ip)

            async with self._lock:
                self.cache[ip] = (hostname, current_time)
                logger.debug("DNS cache stored for %s: %s", ip, hostname)

            return hostname

        except Exception as e:
            logger.warning("DNS lookup failed for %s: %s", ip, e)
            return ip  # Return IP as fallback

    async def clear_expired(self) -> None:
        """Remove expired entries from the cache.

        Iterates through all cache entries and removes those whose
        TTL has expired. This can be called periodically to keep
        the cache size manageable, though expired entries are also
        removed on access.

        Thread-safe through async lock usage.
        """
        current_time = time.time()
        expired_keys = []

        async with self._lock:
            for ip, (_hostname, timestamp) in self.cache.items():
                if current_time - timestamp >= self.ttl_seconds:
                    expired_keys.append(ip)

            for key in expired_keys:
                del self.cache[key]

        if expired_keys:
            logger.debug("Cleared %s expired DNS cache entries", len(expired_keys))

    def get_cache_stats(self) -> CacheStats:
        """Get cache statistics for monitoring.

        Returns:
            Dictionary containing:
            - total_entries: Total number of cached entries
            - expired_entries: Number of expired but not yet removed entries
            - active_entries: Number of valid (non-expired) entries
            - ttl_seconds: Configured TTL value
            - cache_hit_rate: Hit rate if tracking is implemented

        Useful for monitoring cache effectiveness and tuning TTL values.
        """
        current_time = time.time()
        expired_count = sum(
            1
            for _, timestamp in self.cache.values()
            if current_time - timestamp >= self.ttl_seconds
        )

        return {
            "total_entries": len(self.cache),
            "expired_entries": expired_count,
            "active_entries": len(self.cache) - expired_count,
            "ttl_seconds": self.ttl_seconds,
            "cache_hit_rate": getattr(self, "_hit_rate", 0.0),
        }


# Global DNS cache instance
_dns_cache: DNSCache | None = None


def get_dns_cache() -> DNSCache:
    """Get or create the global DNS cache instance.

    Returns:
        The singleton DNSCache instance.

    Uses lazy initialization to create the cache on first access.
    All components share this single cache instance for consistency.
    """
    global _dns_cache
    if _dns_cache is None:
        _dns_cache = DNSCache()
    return _dns_cache


async def get_hostname_cached(ip: str) -> str:
    """Convenience function for cached hostname lookup.

    Args:
        ip: IP address to resolve.

    Returns:
        Resolved hostname or IP address if lookup fails.

    This is the primary interface for other modules to perform
    cached DNS lookups. It handles getting the global cache
    instance and calling the appropriate method.

    Example:
        hostname = await get_hostname_cached("192.168.1.100")
    """
    cache = get_dns_cache()
    return await cache.get_hostname(ip)
