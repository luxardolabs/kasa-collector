# luxarch:logging asset v6 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit logging`.
"""The fleet's ONE logging setup: standard-library `logging`, one JSON line per record on stdout.

Why the standard library (sources in `luxarch --playbook logging`): every log platform the fleet might
ship to documents it as the integration point (Datadog names stdlib JSON formatters, Google Cloud and
OpenTelemetry attach a stdlib handler), every third-party library (uvicorn, SQLAlchemy, httpx, alembic)
logs through it, and structlog itself runs on top of it. So stdlib is unavoidable; one library means
stdlib alone.

Why the collision fix: `Logger.makeRecord` raises `KeyError("Attempt to overwrite %r in LogRecord")`
for any `extra=` key that is already a LogRecord attribute (`name`, `filename`, `module`, `args`,
`message`, ...), so a log call crashes, usually inside an `except` branch. The Python docs name
`makeRecord` as the method to override; `configure_logging()` installs an override that keeps the
value under `extra_<key>` ON THE RECORD instead. Installed on `logging.Logger` itself, so it covers
every logger, including ones created before `configure_logging()` ran and third-party ones.

Why `attributes` (v5): the JSON line keeps the module's own fields (timestamp, level, service, version,
module, ...) at the top level and every caller field (`extra=`, `log_context`) under `attributes`,
UNDER ITS OWN NAME. `extra={"name": ..., "version": ..., "created": ...}` is written as exactly that,
because nothing a caller passes can collide with the envelope or with LogRecord's internals. This is
OpenTelemetry's log data model (`attributes` beside the envelope) and Elastic ECS's rule for custom
fields; v1-v4 wrote caller fields flat and renamed the common ones to `extra_<key>`.

Use, once, in the process entrypoint (`app/main.py`, a collector's `__main__`), before serving:

    from app.core.logging_config import configure_logging

    configure_logging(service="demo", version=settings.version, environment=settings.environment)

Then log as before: `logger = logging.getLogger(__name__)`, `logger.info("order paid", extra={...})`.
Per-request context (on every line logged inside it, across awaits):

    with log_context(request_id=rid, trace_id=tid):
        response = await call_next(request)

Starting uvicorn from code with an app OBJECT (`uvicorn.run(app)`, `uvicorn.Config(app)`) re-applies
uvicorn's own text config after this one: pass `log_config=None`. The `uvicorn app.main:app` CLI,
`--reload` and workers are unaffected. A separate process (a `multiprocessing` spawn/forkserver child,
a script with its own `__main__`) starts with stock logging: call `configure_logging()` there too.

A service that logs personal data (transcripts, prompts, emails, tokens) passes a redactor, and every
line goes through it before it is written: `configure_logging(..., redact=scrub)`, where `scrub` takes
the line as a dict and returns the dict to write. It sees the message, the bound context, every
`extra=` field and the traceback, in JSON and text mode alike. If it raises, the line is written with
its fixed fields only and a `redaction_error`: never the unscrubbed content, never lost.

`LOG_LEVEL` sets the root level (default INFO). Per-logger levels: pass
`configure_logging(..., levels={"sqlalchemy.engine": "WARNING"})` for the code's defaults, and set
`LOG_MODULE_LEVELS='{"app.services.ingest": "DEBUG"}'` to override one at runtime. `LOG_FORMAT=text` gives a plain human-readable line for
local development; anything that ships emits JSON.

Emitted, not shared: `luxarch --emit logging`. Drop it in at app/core/logging_config.py. Nothing
imports luxarch at runtime. Do not hand-edit: re-emit to update; repo.emitted_assets_current reds a
stale copy and repo.logging_canonical reds a second setup.
"""

from __future__ import annotations

import contextvars
import json
import logging
import os
import sys
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from datetime import UTC, datetime
from types import TracebackType
from typing import Any, TextIO, cast

# Every attribute a bare LogRecord carries on this interpreter (taskName on 3.12+, ...), plus the two
# makeRecord also refuses. Computed, not listed, so a new CPython attribute is covered automatically.
_RECORD_ATTRS = frozenset(vars(logging.LogRecord("", 0, "", 0, "", (), None))) | {
    "message",
    "asctime",
}
# Where `_make_record` notes each caller field's own name and the record attribute it was written to
# (renamed or not). The formatter reads the VALUE from the record, so a `logging.Filter` that scrubs or
# deletes `record.email` is honoured, and writes it under the caller's name.
_FIELD_KEYS = "_log_field_keys"
# OpenTelemetry's logging instrumentation sets these record attributes; the line carries them under
# the names log platforms index (`trace_id`/`span_id`), at the top level. A `trace_id` / `span_id` the
# caller bound itself (`log_context(trace_id=...)`) is lifted there too when the instrumentation did not
# set one.
_TRACE_FIELDS = {"otelTraceID": "trace_id", "otelSpanID": "span_id"}
# What a hostile or broken value can raise while being serialised or repr()'d (RecursionError is a
# RuntimeError). A log line is never dropped for any of them.
_VALUE_ERRORS = (
    ArithmeticError,
    AttributeError,
    LookupError,
    RuntimeError,
    TypeError,
    ValueError,
)
# uvicorn adds an ANSI-coloured copy of every message for its own terminal handler; it is noise in JSON.
_DROPPED = frozenset({"color_message"})

# The stdlib method `configure_logging()` replaces on `logging.Logger` (named, not a literal, so the
# one line that installs it reads as what it is).
_OVERRIDDEN = "makeRecord"

# No default: a ContextVar default is shared by every context, so it must not be a mutable dict
# (ruff B039). `_bound()` reads it with an empty mapping instead.
_context: contextvars.ContextVar[Mapping[str, Any]] = contextvars.ContextVar(
    "log_context"
)


def _bound() -> Mapping[str, Any]:
    return _context.get({})


_SysExcInfo = (
    tuple[type[BaseException], BaseException, TracebackType | None]
    | tuple[None, None, None]
)


# A repo's redactor: a flat mapping in, the mapping to write out. It is called twice per line, on the
# envelope and on `attributes`, so it sees every caller field under its own name, never nested.
# See `configure_logging(redact=)`.
Redactor = Callable[[dict[str, Any]], Mapping[str, Any]]
# What survives a redactor that raised: only fields the module itself wrote and no caller controls.
_SAFE_ON_FAILURE = ("timestamp", "level", "logger", "service", "version", "environment")


def _scrubbed(part: dict[str, Any], redact: Redactor) -> dict[str, Any] | str:
    """`part` through the redactor, or why it failed."""
    # Any exception, not a list: one that escaped would reach logging.Handler.handleError, which prints
    # the record's raw arguments to stderr, i.e. exactly the data the redactor exists to remove.
    try:
        # Typed as returning a Mapping; a repo's redactor may still return anything at run time.
        out = cast(object, redact(dict(part)))
    except Exception as exc:
        return type(exc).__qualname__
    if isinstance(out, Mapping):
        return dict(out)
    return f"returned {type(out).__name__}, not a mapping"


def _redacted(
    line: dict[str, Any], attributes: dict[str, Any], redact: Redactor | None
) -> tuple[dict[str, Any], dict[str, Any]]:
    """The envelope and the attributes through the repo's redactor, each on its own. Fails CLOSED: if
    either call raises (or returns something that is not a mapping), neither unscrubbed part is
    written; the record still is, with its fixed fields and the reason."""
    if redact is None:
        return line, attributes
    head = _scrubbed(line, redact)
    attrs = _scrubbed(attributes, redact) if attributes else {}
    if isinstance(head, dict) and isinstance(attrs, dict):
        return head, attrs
    safe = {k: line[k] for k in _SAFE_ON_FAILURE if k in line}
    safe["message"] = "[REDACTED: the redactor failed on this line]"
    safe["redaction_error"] = head if isinstance(head, str) else str(attrs)
    return safe, {}


def _free_key(key: str, taken: Mapping[str, Any]) -> str:
    while key in taken or key in _RECORD_ATTRS:
        key = f"extra_{key}"
    return key


def _make_record(
    self: logging.Logger,
    name: str,
    level: int,
    fn: str,
    lno: int,
    msg: object,
    args: Any,
    exc_info: _SysExcInfo | None,
    func: str | None = None,
    extra: Mapping[str, object] | None = None,
    sinfo: str | None = None,
) -> logging.LogRecord:
    """`logging.Logger.makeRecord`, except a colliding `extra` key is renamed on the record, never
    raised on. The caller's fields are also kept under their own names for the formatter."""
    record = logging.getLogRecordFactory()(
        name, level, fn, lno, msg, args, exc_info, func, sinfo
    )
    names: dict[str, str] = {}
    record.__dict__[_FIELD_KEYS] = names
    for key, value in (extra or {}).items():
        free = _free_key(key, record.__dict__)
        record.__dict__[free] = value
        names[key] = free
    return record


class JsonFormatter(logging.Formatter):
    """One JSON object per record: the fixed fields, then `attributes`: the bound context and every
    `extra=` field, each under the name the caller gave it.

    The fixed fields are what an operator needs from one line read on its own: when, how bad, which
    service/version/environment, WHERE in the code (`module`, `function`, `line`, `thread_name`), the
    trace it belongs to (`trace_id`/`span_id`, from OpenTelemetry's logging instrumentation when it is
    installed), and an exception's type beside its traceback."""

    def __init__(
        self,
        service: str,
        version: str,
        environment: str | None = None,
        redact: Redactor | None = None,
    ) -> None:
        super().__init__()
        self.service = service
        self.version = version
        self.environment = environment
        self.redact = redact

    def format(self, record: logging.LogRecord) -> str:
        line: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self.service,
            "version": self.version,
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
            "thread_name": record.threadName,
        }
        if self.environment:
            line["environment"] = self.environment
        attributes = {**_bound(), **_extras(record)}
        for otel, ours in _TRACE_FIELDS.items():
            if otel in attributes:
                line[ours] = attributes.pop(otel)
        for ours in _TRACE_FIELDS.values():
            if ours not in line and ours in attributes:
                line[ours] = attributes.pop(ours)
        if record.exc_info:
            line["exception"] = self.formatException(record.exc_info)
            if record.exc_info[0] is not None:
                line["exception_type"] = record.exc_info[0].__qualname__
        if record.stack_info:
            line["stack"] = self.formatStack(record.stack_info)
        line, attributes = _redacted(line, attributes, self.redact)
        if attributes:
            line["attributes"] = attributes
        try:
            return json.dumps(line, default=str, ensure_ascii=False, allow_nan=False)
        except _VALUE_ERRORS:
            # A circular structure, a non-string key, NaN/Infinity, or a value whose str() raises:
            # stock logging would still print this record, so it must not be lost here either.
            safe = {str(k): _plain(v) for k, v in line.items() if k != "attributes"}
            if isinstance(line.get("attributes"), Mapping):
                safe["attributes"] = {
                    str(k): _plain(v) for k, v in line["attributes"].items()
                }
            return json.dumps(safe, ensure_ascii=False)


class _Handler(logging.StreamHandler[TextIO]):
    """stdout, and a failure report that cannot leak what a redactor exists to remove.

    A record that cannot be formatted at all (a message whose `%` arguments do not fit) fails before
    the redactor runs, and stock `handleError` then prints the record's raw message and arguments to
    stderr. With a redactor configured, the report names the logger and the error type only."""

    def __init__(self, redact: Redactor | None) -> None:
        super().__init__(sys.stdout)
        self.redact = redact

    def handleError(self, record: logging.LogRecord) -> None:
        if self.redact is None:
            super().handleError(record)
            return
        if logging.raiseExceptions and sys.stderr:
            failure = sys.exc_info()[0]
            sys.stderr.write(
                f"--- Logging error in {record.name}: "
                f"{failure.__qualname__ if failure else 'unknown'} "
                "(record content withheld: a redactor is configured) ---\n"
            )


class TextFormatter(logging.Formatter):
    """`LOG_FORMAT=text`: one readable line for a terminal; context and extras appended as k=v.

    Built from the same fields as the JSON line, and through the same redactor: a developer's
    terminal is still a place personal data must not reach."""

    def __init__(self, redact: Redactor | None = None) -> None:
        super().__init__()
        self.redact = redact

    def format(self, record: logging.LogRecord) -> str:
        line: dict[str, Any] = {"message": record.getMessage()}
        if record.exc_info:
            line["exception"] = self.formatException(record.exc_info)
        if record.stack_info:
            line["stack"] = self.formatStack(record.stack_info)
        line, attributes = _redacted(line, {**_bound(), **_extras(record)}, self.redact)
        message = line.pop("message", "")
        trace = [str(line.pop(k)) for k in ("exception", "stack") if k in line]
        head = f"{self.formatTime(record)} {record.levelname} {record.name} {message}"
        tail = " ".join(f"{k}={v}" for k, v in {**line, **attributes}.items())
        return "\n".join([f"{head} {tail}" if tail else head, *trace])


def _extras(record: logging.LogRecord) -> dict[str, Any]:
    """The caller's fields under their own names, plus any attribute a filter or adapter set on the
    record (OpenTelemetry's trace ids, for one)."""
    names = record.__dict__.get(_FIELD_KEYS)
    names = names if isinstance(names, dict) else {}
    own = set(names.values())
    other = {
        k: v
        for k, v in record.__dict__.items()
        if k not in _RECORD_ATTRS
        and k not in _DROPPED
        and k not in own
        and k != _FIELD_KEYS
    }
    # v6: `_DROPPED` applies to the caller's fields too. uvicorn passes `color_message` through
    # `extra=`, so it arrived here, and every uvicorn line carried ANSI escapes under `attributes`.
    fields = {
        name: record.__dict__[key]
        for name, key in names.items()
        if key in record.__dict__ and name not in _DROPPED
    }
    return {**other, **fields}


def _plain(value: object) -> object:
    """A JSON-safe stand-in for one value that `json.dumps` refused."""
    if value is None or isinstance(value, bool | int | str):
        return value
    if isinstance(value, float):
        return (
            value
            if value == value and value not in (float("inf"), float("-inf"))
            else str(value)
        )
    try:
        return repr(value)
    except _VALUE_ERRORS:
        # a broken __repr__ must not lose the log line; object's own repr cannot raise
        return object.__repr__(value)


def _env_levels() -> dict[str, str | int]:
    """`LOG_MODULE_LEVELS` as {logger: level}; anything that is not a JSON object of those is ignored."""
    try:
        parsed = json.loads(os.environ.get("LOG_MODULE_LEVELS") or "{}")
    except ValueError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {
        str(k): v
        for k, v in parsed.items()
        if isinstance(v, str | int) and not isinstance(v, bool)
    }


def _level(level: str | int | None) -> int:
    """`level`, else `LOG_LEVEL`, as a number: names in any case, digits, never a startup crash."""
    raw = os.environ.get("LOG_LEVEL", "INFO") if level is None else level
    if isinstance(raw, int):
        return raw
    text = raw.strip().upper()
    if text.isdigit():
        return int(text)
    return logging.getLevelNamesMapping().get(text, logging.INFO)


@contextmanager
def log_context(**fields: Any) -> Iterator[None]:
    """Add `fields` to every line logged inside the block, in this task and the tasks it awaits."""
    token = _context.set({**_bound(), **fields})
    try:
        yield
    finally:
        _context.reset(token)


def configure_logging(
    service: str,
    version: str,
    level: str | int | None = None,
    levels: Mapping[str, str | int] | None = None,
    environment: str | None = None,
    redact: Redactor | None = None,
) -> None:
    """Install the fleet's logging: JSON to stdout, the collision fix, server loggers routed through it.

    `level` (else `LOG_LEVEL`) is the root level. `levels` sets individual loggers, for example
    `{"sqlalchemy.engine": "WARNING", "app.services.ingest": "DEBUG"}`: the code's defaults. The
    `LOG_MODULE_LEVELS` environment variable (a JSON object of the same shape) is applied on top,
    so one module can be turned up in production without a deploy. A malformed entry is skipped,
    never a startup crash.

    `environment` (e.g. `settings.environment`: dev, staging, prod) goes on every JSON line, so a line
    copied out of one cluster's logs still says which one it came from.

    `redact` is the repo's redactor, for a service that logs personal data. It is called on the
    envelope (message and traceback included) and, separately, on the caller's fields (context and
    `extra=`, flat, under their own names); each returns the dict to write. If either raises, the line
    keeps its fixed fields and says the redaction failed; the unscrubbed content is dropped.

    Idempotent: calling it again replaces the handler instead of adding a second one.
    """
    # The documented override point (Python docs: "can be overridden in subclasses"), installed on the
    # base class so loggers created before this call, and third-party ones, are covered as well.
    setattr(logging.Logger, _OVERRIDDEN, _make_record)
    formatter: logging.Formatter
    if os.environ.get("LOG_FORMAT", "json").lower() == "text":
        formatter = TextFormatter(redact)
    else:
        formatter = JsonFormatter(service, version, environment, redact)
    handler = _Handler(redact)
    handler.setFormatter(formatter)
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(_level(level))
    for name, value in {**(levels or {}), **_env_levels()}.items():
        logging.getLogger(name).setLevel(_level(value))
    # uvicorn/gunicorn install their own text handlers (uvicorn.access does not even propagate); route
    # them through the root handler so their lines are the same JSON as the app's.
    for name in (
        "uvicorn",
        "uvicorn.error",
        "uvicorn.access",
        "gunicorn",
        "gunicorn.error",
        "gunicorn.access",
    ):
        server = logging.getLogger(name)
        server.handlers.clear()
        server.propagate = True
