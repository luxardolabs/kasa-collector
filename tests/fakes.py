"""Test doubles shared by the poller tests."""

from collections.abc import Awaitable, Callable
from types import SimpleNamespace
from typing import Any

Store = Callable[[dict[str, dict[str, Any]]], Awaitable[bool]]


def emeter_storage(store: Store) -> SimpleNamespace:
    """A storage double whose emeter writes all go to ``store``, one reading at a time.

    ``process_emeter_entries`` (a strip's batch) reports success only when every
    reading in it did.
    """

    async def entries(batch: list[tuple[str, dict[str, Any]]]) -> bool:
        stored = True
        for ip, data in batch:
            stored = await store({ip: data}) and stored
        return stored

    return SimpleNamespace(process_emeter_data=store, process_emeter_entries=entries)
