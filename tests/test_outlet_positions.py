"""SMART outlet numbering: one bad report never renumbers a strip, and a strip taking
another's address never inherits its numbering."""

import logging
from types import SimpleNamespace

import pytest

from app.collector.poller import Poller

pytestmark = pytest.mark.unit
IP = "10.0.0.5"
ONE_BASED = [1, 2, 3, 4, 5, 6]  # every python-kasa SMART strip fixture numbers from 1


def _poller():
    p = object.__new__(Poller)
    p.logger = logging.getLogger("test")
    return p


def _strip(prefix, positions):
    return [
        SimpleNamespace(
            has_emeter=True,
            sys_info={"position": pos},
            device_id=f"{prefix}-{n}",
            alias=f"{prefix} outlet {n}",
        )
        for n, pos in enumerate(positions, start=1)
    ]


def _ids(p, outlets, ip=IP):
    placed = p._outlet_positions(ip, outlets)
    return [placed.get(id(o)) for o in outlets]


def test_a_one_based_strip_keeps_its_numbering():
    p = _poller()
    strip = _strip("A", ONE_BASED)
    for _ in range(3):
        assert _ids(p, strip) == [1, 2, 3, 4, 5, 6]


def test_one_bogus_zero_never_renumbers_the_strip():
    p = _poller()
    strip = _strip("A", ONE_BASED)
    assert _ids(p, strip) == [1, 2, 3, 4, 5, 6]

    # One poll in which outlet 1 reports 0: it keeps its remembered position.
    assert _ids(p, _strip("A", [0, 2, 3, 4, 5, 6])) == [1, 2, 3, 4, 5, 6]
    for _ in range(3):
        assert _ids(p, strip) == [1, 2, 3, 4, 5, 6]


def test_a_strip_taking_another_strips_address_keeps_its_own_numbering():
    p = _poller()
    assert _ids(p, _strip("A", [1, 2, 4, 3, 5, 6])) == [1, 2, 4, 3, 5, 6]
    # DHCP hands the address to a different strip, whose outlets have their own ids.
    assert _ids(p, _strip("B", ONE_BASED)) == [1, 2, 3, 4, 5, 6]
