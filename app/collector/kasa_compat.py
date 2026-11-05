"""Local fix for the one python-kasa defect left that breaks KLAP-only HS300 strips.

TEMPORARY. Delete this module the moment upstream classifies IOT devices from sysinfo
on the DISCOVERY path too. It vendors nothing: it rebuilds a mis-classed device after
``update()``, so an upstream fix makes it a no-op, and ``verify_still_needed()`` says so
out loud at startup.

The affected devices are HS300(US) hw 2.0 on firmware ``1.1.2 Build 241220``. That build
removed the legacy XOR listener for KLAP-capable clients, reporting ``IOT.SMARTPLUGSWITCH``
/ ``KLAP`` / ``login_version: 2``. Strips still on ``1.0.21 Build 210524`` speak XOR and
are unaffected.

python-kasa 0.11.0.1 itself handles the rest: ``get_protocol`` honours
``login_version``, so a v2 device gets ``KlapTransportV2`` and authenticates, and
``_connect`` reads sysinfo over any transport, so ``Device.connect`` builds an
``IotStrip`` with its outlets.

What this module covers is DISCOVERY. ``Discover._get_device_instance()`` is synchronous and still
picks the class from the family table, where ``IOT.SMARTPLUGSWITCH`` is ``IotPlug``. The
probe saw every KLAP strip arrive from ``Discover.discover()`` as an ``IotPlug`` with no
children, so no per-outlet emeter. ``reclass_strip_if_needed()`` corrects that after
``update()``, when ``sys_info["children"]`` is the reliable signal. Upstream: #1748.
"""

import inspect
import logging

from kasa import Device, Discover
from kasa.iot import IotDevice, IotStrip

# A named logger whose level the entrypoint sets (KASA_COLLECTOR_LOG_LEVEL_KASA_API): this
# module's whole value is announcing itself -- that a device needed the fix and, via
# verify_still_needed(), that the fix has become DEAD and should be deleted. A shim whose
# announcements are filtered out by the default level is a shim nobody knows is there.
logger = logging.getLogger("KasaCompat")


async def reclass_strip_if_needed(device: Device) -> Device:
    """Rebuild a multi-outlet device as ``IotStrip`` when it was built as ``IotPlug``.

    Call AFTER ``device.update()``, so ``sys_info`` is populated. A device whose sysinfo
    carries ``children`` is a strip; if python-kasa handed us a plain
    ``IotDevice``/``IotPlug`` for it (the discovery path), rebuild on the SAME protocol
    object so the established KLAP session is reused rather than re-handshaked.

    Returns the original device untouched in every other case, including when it is
    already an ``IotStrip`` (the XOR path, and ``Device.connect`` since 0.11), so this
    is a no-op on healthy devices.
    """
    if isinstance(device, IotStrip) or not isinstance(device, IotDevice):
        return device

    children = (device.sys_info or {}).get("children")
    if not children:
        return device

    logger.info(
        "kasa_compat: %s reports %d child outlets but was built as %s — rebuilding as "
        "IotStrip so per-outlet emeter is collected (python-kasa#1748)",
        device.host,
        len(children),
        type(device).__name__,
    )
    strip = IotStrip(device.host, protocol=device.protocol)
    await strip.update()
    return strip


def discovery_classes_from_family() -> bool:
    """True while upstream discovery still picks the device class from the family table."""
    src = inspect.getsource(Discover._get_device_instance)
    return "get_device_class_from_family" in src and "sys_info" not in src


def verify_still_needed() -> bool:
    """Report whether the discovery defect is still upstream; log loudly once it is gone.

    A fix that silently stops applying is the hollow green this module would otherwise
    become. Checked at startup, so an upstream fix surfaces as a prompt to DELETE the
    module rather than as a wrapper quietly doing nothing for another year.
    """
    if discovery_classes_from_family():
        logger.info(
            "kasa_compat: python-kasa discovery still classes IOT devices by family "
            "(python-kasa#1748) — KLAP strips are re-classed after update()."
        )
        return True
    logger.warning(
        "kasa_compat: python-kasa's Discover no longer picks the class from the family "
        "table alone — #1748 looks FIXED upstream. Re-test the KLAP strips without "
        "reclass_strip_if_needed() and delete this module."
    )
    return False
