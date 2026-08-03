"""Logging setup for kasa-collector.

Fleet standard: a structured JSON formatter (opt-in via ``KASA_COLLECTOR_STRUCTURED_LOGS``)
for log aggregation, and a colored console formatter otherwise. Log CALLS everywhere use
lazy ``%s`` args, never f-strings (enforced by ruff's ``G`` rules) — so formatting is
deferred when the level is disabled and structured fields survive.
"""

import json
import logging
import sys
from datetime import UTC, datetime

from app.core.config import Config

_RESERVED = frozenset(logging.makeLogRecord({}).__dict__) | {
    "message",
    "asctime",
    "taskName",
}


class StructuredFormatter(logging.Formatter):
    """JSON formatter for machine-readable logs."""

    def format(self, record: logging.LogRecord) -> str:
        data: dict[str, object] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            data["exception"] = self.formatException(record.exc_info)
        # Carry any extra=... fields through to the JSON.
        for key, value in record.__dict__.items():
            if key not in _RESERVED:
                data[key] = value
        return json.dumps(data)


class ColoredFormatter(logging.Formatter):
    """Colored formatter for console output."""

    COLORS = {
        "DEBUG": "\033[36m",  # Cyan
        "INFO": "\033[32m",  # Green
        "WARNING": "\033[33m",  # Yellow
        "ERROR": "\033[31m",  # Red
        "CRITICAL": "\033[35m",  # Magenta
    }
    RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        color = self.COLORS.get(record.levelname)
        if color:
            record.levelname = f"{color}{record.levelname}{self.RESET}"
        return super().format(record)


def setup_logger(name: str, level: str = "INFO") -> logging.Logger:
    """Configure and return a named logger (structured JSON or colored, per config)."""
    log = logging.getLogger(name)
    log.setLevel(level)
    log.propagate = False
    log.handlers.clear()

    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level)
    if Config.KASA_COLLECTOR_STRUCTURED_LOGS:
        handler.setFormatter(StructuredFormatter())
    else:
        handler.setFormatter(
            ColoredFormatter("%(asctime)s [%(levelname)s] %(name)s %(message)s")
        )
    log.addHandler(handler)
    return log
