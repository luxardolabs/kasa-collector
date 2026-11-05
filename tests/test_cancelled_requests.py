"""A poll cancelled mid-request leaves the client usable for the next cycle.

The per-device read deadline cancels python-kasa while a KLAP exchange is in flight:
in the handshake, or between sending an encrypted request and reading its reply. The
next cycle's update() on the same client must still work. Driven through the real
python-kasa client against harness/fake_smart.py, cancelling at many points.
"""

import asyncio

import pytest

import tests.test_smart_strip_edges as edges
from tests.test_smart_strip_edges import _connect

pytestmark = pytest.mark.unit
fake = edges.fake  # the fixture


@pytest.mark.parametrize("cut_after_ms", [0, 1, 2, 3, 5, 8, 13, 21, 34])
async def test_a_cancelled_update_leaves_the_client_usable(fake, cut_after_ms):
    server, strip = await _connect(fake)
    try:
        await strip.update()
        # Drop the session, so the cut can land in the handshake as well.
        await strip.protocol._transport.reset()

        with pytest.raises(TimeoutError):
            async with asyncio.timeout(cut_after_ms / 1000):
                while True:  # keep the client busy until the cut lands
                    await strip.update()

        await strip.update()  # the next cycle

        assert len(strip.children) == 6
        assert all(child.has_emeter for child in strip.children)
    finally:
        await strip.disconnect()
        server.close()
