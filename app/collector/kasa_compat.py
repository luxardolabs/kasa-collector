"""Local patches for two python-kasa 0.10.2 defects that break KLAP-only HS300 strips.

TEMPORARY. Delete this module the moment upstream ships either fix — the
``python-kasa>=0.10.2,<0.11.0`` pin picks a fixed 0.10.x up automatically. Nothing
here vendors a fork; each patch wraps the released function and corrects its result,
so an upstream fix simply makes the patch a no-op (and ``verify_still_needed()``
says so out loud).

The affected devices are HS300(US) hw 2.0 on firmware ``1.1.2 Build 241220``. That
build removed the legacy XOR listener — tcp/9999 is actively refused — so KLAP on
tcp/80 is the only local path. They report ``IOT.SMARTPLUGSWITCH`` / ``KLAP`` /
``login_version: 2``. Strips still on ``1.0.21 Build 210524`` keep 9999 open and are
unaffected, which is why the fleet's other HS300s are fine.

Bug 1 — wrong transport, so authentication can never succeed
    ``device_factory.get_protocol()`` builds its lookup key from device family +
    encryption type and never reads ``login_version``, so ``IOT.KLAP`` always maps to
    the v1 (MD5) ``KlapTransport``. A device declaring ``login_version: 2`` (SHA256)
    can therefore never authenticate, whatever the credentials::

        Device response did not match our challenge on ip <addr>, check that your
        e-mail and password (both case-sensitive) are correct.

    This is why only the HS300s broke: a KP125M reports ``SMART.KASAPLUG``, hits the
    ``SMART.KLAP`` row, and gets v2 already. Upstream PR #1731 (unmerged).

Bug 2 — device built as IotPlug, so no child sockets and no per-outlet emeter
    Fixing Bug 1 gets authentication and nothing else. The only path that derives the
    class from the device's own sysinfo is gated on ``XorTransport``, so IOT-over-KLAP
    falls through to the family table where ``IOT.SMARTPLUGSWITCH`` is hardcoded to
    ``IotPlug`` — which has no concept of children. The strip arrives as a single plug:
    no outlets, no per-outlet emeter. Upstream issue #1748.

    We fix this AFTER ``update()`` rather than inside the factory, because this
    collector's primary entry points are ``Discover.discover()`` /
    ``discover_single()``, and ``Discover._get_device_instance()`` is a *synchronous*
    function with no sysinfo branch to un-gate — it cannot query the device at all.
    ``sys_info["children"]`` is the reliable signal; the discovery model string is not,
    because a direct-connect path carries no discovery info and the model comes
    through empty.
"""

import inspect
import logging
import sys
from typing import Any

from kasa import Device, DeviceConfig
from kasa import device_factory as _device_factory
from kasa.device_factory import get_device_class_from_sys_info
from kasa.iot import IotDevice, IotStrip
from kasa.protocols import IotProtocol
from kasa.protocols.iotprotocol import IotProtocol as _IotProtocolCls
from kasa.transports import KlapTransport, KlapTransportV2

# A named logger whose level the entrypoint sets (KASA_COLLECTOR_LOG_LEVEL_KASA_API): this
# module's whole value is announcing itself -- both that the patch is ACTIVE and, via
# verify_still_needed(), that it has become DEAD and should be deleted. A shim whose
# announcements are filtered out by the default level is a shim nobody knows is there.
logger = logging.getLogger("KasaCompat")

_orig_get_protocol = _device_factory.get_protocol
_orig_connect = _device_factory._connect
_patched = False

# python-kasa's own sysinfo probe, used by the _connect patch below.
_GET_SYSINFO_QUERY = {"system": {"get_sysinfo": None}}


def _needs_v2_transport(config: DeviceConfig, protocol: Any) -> bool:
    """True when this is the IOT-family KLAP device that was handed the v1 transport."""
    ctype = config.connection_type
    login_version = getattr(ctype, "login_version", None)
    return (
        isinstance(protocol, IotProtocol)
        # KlapTransportV2 subclasses KlapTransport, so exclude it explicitly rather
        # than relying on the base check alone.
        and isinstance(protocol._transport, KlapTransport)
        and not isinstance(protocol._transport, KlapTransportV2)
        and login_version is not None
        and login_version >= 2
    )


def _get_protocol_login_version_aware(
    config: DeviceConfig, *, strict: bool = False
) -> Any:
    """``get_protocol`` that honours ``login_version`` for IOT-family KLAP devices."""
    protocol = _orig_get_protocol(config, strict=strict)
    if protocol is not None and _needs_v2_transport(config, protocol):
        logger.debug(
            "kasa_compat: %s declares login_version>=2 — substituting KlapTransportV2 "
            "for the v1 transport python-kasa selected",
            config.host,
        )
        return IotProtocol(transport=KlapTransportV2(config=config))
    return protocol


async def _connect_sysinfo_over_klap(config: DeviceConfig, protocol: Any) -> Device:
    """``_connect`` that derives the class from sysinfo for IOT over ANY transport.

    Upstream gates the sysinfo branch on ``XorTransport``, so IOT-over-KLAP falls
    through to the family table and a strip is built as ``IotPlug``. That is not merely
    a missing-children problem: ``IotPlug._initialize_modules()`` reads ``has_emeter``
    during ``update()``, which raises *"You need to await update() to access the data"*
    on a multi-outlet device — so the update never completes and there is no built
    device to correct afterwards. The class must be right BEFORE update, which is why
    this patches the factory rather than fixing up the result.

    ``GET_SYSINFO_QUERY`` works fine over KLAP; only the gate was wrong.
    """
    if isinstance(protocol, _IotProtocolCls):
        info = await protocol.query(_GET_SYSINFO_QUERY)
        device_class = get_device_class_from_sys_info(info)
        device = device_class(config.host, protocol=protocol)
        device.update_from_discover_info(info)
        await device.update()
        logger.debug(
            "kasa_compat: %s built as %s from its own sysinfo (upstream would have used "
            "the family table)",
            config.host,
            type(device).__name__,
        )
        return device
    return await _orig_connect(config, protocol)


def apply_patches() -> None:
    """Install the local python-kasa patches. Idempotent; call once at startup."""
    global _patched
    if _patched:
        return
    # Rebind in EVERY module that holds a reference, not just device_factory.
    # `kasa/discover.py` does `from kasa.device_factory import (...)` at module level,
    # which binds the original function object at import time -- so patching only the
    # factory module leaves the entire discovery path running the unpatched code. That
    # would be a silent half-patch: the connect path fixed, discovery quietly not.
    for _mod in list(sys.modules.values()):
        if _mod is None or not getattr(_mod, "__name__", "").startswith("kasa"):
            continue
        if getattr(_mod, "get_protocol", None) is _orig_get_protocol:
            _mod.get_protocol = _get_protocol_login_version_aware  # type: ignore[attr-defined]
        if getattr(_mod, "_connect", None) is _orig_connect:
            _mod._connect = _connect_sysinfo_over_klap  # type: ignore[attr-defined]
    _patched = True
    logger.info(
        "kasa_compat: applied local python-kasa patches (KLAP login_version transport "
        "selection + IotStrip re-class). Remove this module when upstream ships "
        "python-kasa#1731 / #1748."
    )


async def reclass_strip_if_needed(device: Device) -> Device:
    """Rebuild a multi-outlet device as ``IotStrip`` when it was built as ``IotPlug``.

    Call AFTER ``device.update()``, so ``sys_info`` is populated. A device whose
    sysinfo carries ``children`` is a strip; if python-kasa handed us a plain
    ``IotDevice``/``IotPlug`` for it (the Bug 2 path), rebuild on the SAME protocol
    object so the established KLAP session is reused rather than re-handshaked.

    Returns the original device untouched in every other case — including when it is
    already an ``IotStrip`` (the XOR path, and whatever upstream ships), so this is a
    no-op on healthy devices.
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


def verify_still_needed() -> bool:
    """Report whether upstream still has both defects; log loudly when a patch is dead.

    A patch that silently stops applying is the hollow green this module would
    otherwise become — the fleet's own lesson about carve-outs that bless forever. This
    is checked at startup so an upstream fix surfaces as a prompt to DELETE the shim,
    rather than as a wrapper quietly doing nothing for another year.
    """
    still_needed = True
    src = inspect.getsource(_device_factory._connect)
    if "XorTransport" not in src:
        logger.warning(
            "kasa_compat: python-kasa's _connect no longer gates the sysinfo branch on "
            "XorTransport — issue #1748 looks FIXED upstream. Re-test without this "
            "module and delete it."
        )
        still_needed = False
    if "login_version" in inspect.getsource(_orig_get_protocol):
        logger.warning(
            "kasa_compat: python-kasa's get_protocol now reads login_version — PR #1731 "
            "looks MERGED upstream. Re-test without this module and delete it."
        )
        still_needed = False
    return still_needed
