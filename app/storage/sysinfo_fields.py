"""One InfluxDB field type per sysinfo key, whatever a device reports.

InfluxDB fixes a field's type per shard from the first value written, and rejects a
whole point whose field has another type (a 422 "field type conflict"). sysinfo is
written as the device reports it, so one device sending ``rssi`` as text would cost
every other device its whole sysinfo point until the shard rolls over. Each key
therefore has one type here, and a value is converted to it or left out of the point.

The types are those python-kasa 0.11.0.1's device fixtures (IOT ``get_sysinfo`` and
SMART ``get_device_info``, 189 devices) report for each key: no key appears there with
two types. Every key not named here is written as text.

A device's coordinates are never written. Real devices send them as a float in degrees
(IOT ``latitude``) or as a scaled int (SMART), so no one type fits, and python-kasa's
fixtures zero them. No dashboard reads them, and they are the owner's home location.
"""

import math
from typing import Any

_INT64_MIN, _INT64_MAX = -(2**63), 2**63 - 1

INT_KEYS = frozenset(
    {
        "LEF",
        "abnormal_detect",
        "auto_off_remain_time",
        "battery_percentage",
        "bind_count",
        "boost_remain_time",
        "boost_temp",
        "boost_time",
        "brightness",
        "child_num",
        "color_temp",
        "current_humidity",
        "current_humidity_exception",
        "current_temp_exception",
        "dc_state",
        "default_boost_temp",
        "default_boost_time",
        "default_hold_on_time",
        "err_code",
        "heapsize",
        "hold_on_remain_time",
        "hold_on_time",
        "hue",
        "humidity_offset",
        "is_color",
        "is_dimmable",
        "is_variable_color_temp",
        "jamming_rssi",
        "jamming_signal_level",
        "lastOnboardingTimestamp",
        "led_off",
        "length",
        "max_control_temp",
        "min_control_temp",
        "next_schedule_time",
        "ntc_state",
        "on_time",
        "position",
        "relay_state",
        "report_interval",
        "rssi",
        "saturation",
        "signal_level",
        "slot_number",
        "state",
        "temp_offset",
        "time_diff",
        "time_usage_past30",
        "time_usage_past7",
        "time_usage_today",
        "trigger_timestamp",
        "updating",
    }
)

BOOL_KEYS = frozenset(
    {
        "accessory_at_low_battery",
        "at_low_battery",
        "auto_biorhythm_light_enable",
        "child_protection",
        "detected",
        "device_on",
        "dynamic_light_effect_enable",
        "frost_protection_on",
        "has_set_location_info",
        "hidden",
        "hold_on",
        "in_alarm",
        "is_factory",
        "is_low",
        "music_rhythm_enable",
        "open",
        "overheated",
        "smart_switch_state",
        "status_follow_edge",
        "temp_humidity_notification",
    }
)

FLOAT_KEYS = frozenset({"current_temp", "target_temp"})

DROPPED_KEYS = frozenset({"latitude", "latitude_i", "longitude", "longitude_i"})


def _as_text(value: Any) -> str:
    if isinstance(value, str):
        return str.__str__(value)
    if isinstance(value, list):
        return ",".join(map(str, value))
    return str(value)


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        number = int.__int__(value)
    elif isinstance(value, float):
        real = float.__float__(value)
        if not math.isfinite(real) or not real.is_integer():
            return None
        number = int(real)
    else:
        return None
    return number if _INT64_MIN <= number <= _INT64_MAX else None


def _as_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        number = int.__int__(value)
        return float(number) if _INT64_MIN <= number <= _INT64_MAX else None
    if isinstance(value, float):
        real = float.__float__(value)
        return real if math.isfinite(real) else None
    return None


def sysinfo_field(key: str, value: Any) -> int | float | bool | str | None:
    """``value`` as the type InfluxDB holds ``key`` in, or None to leave it out."""
    if key in DROPPED_KEYS:
        return None
    if key in INT_KEYS:
        return _as_int(value)
    if key in FLOAT_KEYS:
        return _as_float(value)
    if key in BOOL_KEYS:
        return bool.__bool__(value) if isinstance(value, bool) else None
    return _as_text(value)
