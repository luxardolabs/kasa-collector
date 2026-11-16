# luxarch:logging asset v12 - DO NOT edit this marker line; it is how repo.emitted_assets_current knows your copy is current. Re-emit with `luxarch --emit logging`.
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
`extra=` field and the traceback, in JSON and text mode alike. The line's own part (message and
traceback) carries the record's `logger`, so one redactor can scrub those by logger as well as by
value; the caller's fields are a call of their own, without it. If it raises, the line is written with
its fixed fields only and a `redaction_error`: never the unscrubbed content, never lost. The traceback
is always rendered from the exception itself, never taken from `record.exc_text`, which any other
handler's formatter may have filled first.

Trace ids on every line logged inside a span: pass the tracing module's source,
`configure_logging(..., trace_ids=current_trace_ids)` (`luxarch --emit telemetry`), and each record made
while a span is current carries `trace_id` and `span_id`; outside a span, neither. The source is called
when the record is made, in the caller's context, so a line formatted later still names its own span. A
source that raises costs the line its ids, never the line.

No character in a record stops it being written, and every line is text UTF-8 can carry. A lone
surrogate (a `str` UTF-8 cannot encode, which a client reaches by naming a form charset such as
`unicode_escape`) is written as the six characters of its escape, `\\ud800`, in JSON and text mode alike: a JSON line parses to that text, never to a
character, so two lone surrogates cannot be read back as the emoji their pair would spell. A request
field a security line quotes therefore cannot stop that line being written, nor make the stream
invalid UTF-8. A JSON record is one line by any reader's count: U+0085, U+2028 and U+2029, which some
readers split lines on and JSON may carry raw, are written as JSON escapes. In text mode every control
character but a tab in the message or a field is written as its escape (`\\n`, `\\x1b`, `\\u2028`),
so a field can neither add a line nor drive the terminal; a traceback follows on lines of its own,
each indented and escaped the same way, so not even an exception message can start a line that
reads as a record. Every other character is written as itself. The escape is text: a client who
types the six characters `\\ud800` is logged the same way as one who sent the surrogate.

`LOG_LEVEL` sets the root level (default INFO). Per-logger levels: pass
`configure_logging(..., levels={"sqlalchemy.engine": "WARNING"})` for the code's defaults, and set
`LOG_MODULE_LEVELS='{"app.services.ingest": "DEBUG"}'` to override one at runtime. `LOG_FORMAT=text` gives a plain human-readable line for
local development; anything that ships emits JSON.

A pydantic or FastAPI validation error's text quotes the value that failed, a submitted password
included, so no line carries it: a traceback whose exception chain (cause, context, exception group,
or an exception's own arguments) holds one keeps its frames under a message naming the exception type,
and one in a `%` argument, an `extra=` field or a `log_context` field, at any depth of a list, tuple,
set or dict, is written as its type. An
entry of its `errors()` (a dict carrying `type`, `loc`, `msg` and `input`) is written without its
`input`, wherever it is passed, and as its `type` and `loc` alone when its message is the validator's
own text (`value_error`, `assertion_error`, a custom error type), which may quote the value. An
exception whose arguments or attributes (`HTTPException(detail=err.errors())`) hold either is withheld
as one, and an object whose instance dict or slots hold one (a dataclass of results) is written as
its type. Text the application builds itself (`f"failed: {err}"`, `str(err)`,
`err.json()`) is already a string when the log call is made and is written as it is: log
`err.errors(include_input=False)` instead. A custom error type named like one of pydantic's own keeps
its message; an object whose text comes from state outside its instance dict and slots is written
as it renders. Each argument and field of a log call is first searched, without recursion (20,000
values for the whole call), for a validation error or an `errors()` entry: one that holds none is
written as passed, so an ordinary error with a live, cyclic object graph (an HTTP client's status
error, a database client's API error) keeps its text, beside a validation error too. One that holds
one, or that the search could not clear (a batch of more than 20,000 values), is walked: a dict's
`keys()`, `values()` and `items()` views as the dict, and a container nested past 16 levels, or an
argument whose graph runs past 10,000 containers and objects, is written as its type. An answer the
walk gave while an object was still being answered further up (an error that names its row, a row
that keeps its error) is not reused, so each is judged whole.

Emitted, not shared: `luxarch --emit logging`. Drop it in at app/core/logging_config.py. Nothing
imports luxarch at runtime. Do not hand-edit: re-emit to update; repo.emitted_assets_current reds a
stale copy and repo.logging_canonical reds a second setup.
"""

from __future__ import annotations

import contextvars
import copy
import json
import logging
import os
import re
import sys
from collections import deque
from collections.abc import (
    Callable,
    ItemsView,
    Iterable,
    Iterator,
    KeysView,
    Mapping,
    ValuesView,
)
from contextlib import contextmanager
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from types import (
    BuiltinFunctionType,
    BuiltinMethodType,
    FunctionType,
    MethodType,
    ModuleType,
    TracebackType,
)
from typing import Any, TextIO, cast
from uuid import UUID

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
# A caller who passes either of these as `extra=` names its own trace: the span's pair is then not
# written, so a line never carries one id from the caller and the other from the span.
_OWN_IDS = frozenset(_TRACE_FIELDS)
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
# The current span's (trace id, span id) as hex, or None outside a span. See `configure_logging(trace_ids=)`.
TraceIds = Callable[[], tuple[str, str] | None]
_trace_ids: list[TraceIds | None] = [None]
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
    source = _trace_ids[0]
    if source is not None and _OWN_IDS.isdisjoint(extra or ()):
        # Any exception, not a list: a tracing defect must never cost the application its log line.
        try:
            ids = cast(object, source())
        except Exception:
            ids = None
        if (
            isinstance(ids, tuple)
            and len(ids) == 2
            and all(isinstance(i, str) for i in ids)
        ):
            record.__dict__["otelTraceID"], record.__dict__["otelSpanID"] = ids
    for key, value in (extra or {}).items():
        free = _free_key(key, record.__dict__)
        record.__dict__[free] = value
        names[key] = free
    return record


# A validation error's text quotes the value that failed (`input_value=...`), a password included.
_QUOTING_CLASSES = frozenset({"ValidationError", "ValidationException"})
_QUOTING_PACKAGES = frozenset({"pydantic", "pydantic_core", "fastapi"})
# The keys of one entry of a validation error's `errors()`; its `input` is the value that failed.
_ERROR_ENTRY = frozenset({"type", "loc", "msg", "input"})
# The pydantic error types whose `msg` is a fixed template, or one filled only from the schema
# (a bound, a pattern, the expected values, a class name): an entry of one of these is written without
# its `input`. Any other entry (`value_error` and `assertion_error`, whose `msg` and `ctx` carry the
# validator's own text, and every custom type) is written as its `type` and `loc` only.
_TEMPLATED_ERRORS = frozenset(
    {
        "json_type",
        "recursion_loop",
        "recursion_depth_exceeded",
        "missing",
        "frozen_field",
        "frozen_instance",
        "extra_forbidden",
        "invalid_key",
        "model_attributes_type",
        "default_factory_not_called",
        "none_required",
        "finite_number",
        "iterable_type",
        "string_type",
        "string_unicode",
        "string_not_ascii",
        "dict_type",
        "frozen_dict_type",
        "ordered_dict_type",
        "counter_type",
        "list_type",
        "deque_type",
        "tuple_type",
        "set_type",
        "set_item_not_hashable",
        "bool_type",
        "bool_parsing",
        "int_type",
        "int_parsing",
        "int_parsing_size",
        "int_from_float",
        "float_type",
        "float_parsing",
        "bytes_type",
        "missing_sentinel_error",
        "ellipsis_error",
        "date_type",
        "date_from_datetime_inexact",
        "date_past",
        "date_future",
        "time_type",
        "datetime_type",
        "datetime_past",
        "datetime_future",
        "timezone_naive",
        "timezone_aware",
        "time_delta_type",
        "frozen_set_type",
        "callable_type",
        "arguments_type",
        "missing_argument",
        "unexpected_keyword_argument",
        "missing_keyword_only_argument",
        "unexpected_positional_argument",
        "missing_positional_only_argument",
        "multiple_argument_values",
        "url_type",
        "uuid_type",
        "decimal_type",
        "decimal_parsing",
        "fraction_type",
        "fraction_parsing",
        "complex_type",
        "complex_str_parsing",
        "greater_than",
        "greater_than_equal",
        "less_than",
        "less_than_equal",
        "multiple_of",
        "string_too_short",
        "string_too_long",
        "bytes_too_short",
        "bytes_too_long",
        "url_too_long",
        "uuid_version",
        "decimal_max_digits",
        "decimal_max_places",
        "decimal_whole_digits",
        "literal_error",
        "enum",
        "string_pattern_mismatch",
        "model_type",
        "dataclass_type",
        "is_instance_of",
        "too_short",
        "too_long",
    }
)
_UNTEMPLATED_KEPT = ("type", "loc")
# The containers looked into, and how deep: one nested deeper is written as its type, never printed.
_CONTAINERS = (list, tuple, set, frozenset, deque)
_MAX_DEPTH = 16
# The types a container made only of is written as it is, unwalked: none of them can hold a validation
# error. Exact types: a subclass (a `str` subclass with its own `__str__`) is walked.
_SCALARS = frozenset(
    {
        str,
        bytes,
        int,
        float,
        bool,
        type(None),
        datetime,
        date,
        time,
        timedelta,
        UUID,
        Decimal,
    }
)


# Values written as they are (subclasses included): they hold nothing a walk could reach.
_SCALAR_BASES = (
    str | bytes | int | float | complex | date | time | timedelta | UUID | Decimal
)


def _all_scalar(values: Iterable[object]) -> bool:
    return set(map(type, values)) <= _SCALARS


# Objects whose attributes are not a value's data: walked, they would reach a whole module or class.
_OPAQUE = (
    type
    | ModuleType
    | FunctionType
    | BuiltinFunctionType
    | MethodType
    | BuiltinMethodType
)
# How many containers and objects one look walks: past it, each is written as its type.
_MAX_NODES = 10_000


_CLEAR = sys.maxsize  # no answer below a value leaned on an ancestor's


class _Walk:
    """One look through the values of one log call: which of its arguments or fields hold a
    validation error at all (one search each, before any walk), the objects on the current path and
    where (a cycle), the ones answered, and how many more it may walk."""

    def __init__(self, *roots: object) -> None:
        self.holds = _found_in(roots)
        self.at: dict[int, int] = {}  # id -> its place on the current path
        self.low = (
            _CLEAR  # the highest ancestor a cycle below the current value reached
        )
        self.done: dict[int, object] = {}
        self.kept: list[
            object
        ] = []  # copies the walk made, alive so their ids are never reused
        self.left = _MAX_NODES


def _attributes(value: object) -> list[object]:
    """What an object's `repr` / `str` is usually built from: its instance dict and its slots (a
    dataclass's fields are one or the other), read without running the class's own `__getattr__`."""
    found: list[object] = []
    try:
        own = object.__getattribute__(value, "__dict__")
    except AttributeError:
        own = None
    if isinstance(own, dict):
        found.extend(own.values())
    for cls in type(value).__mro__:
        slots = cls.__dict__.get("__slots__", ())
        for name in (slots,) if isinstance(slots, str) else slots:
            if not isinstance(name, str) or name in ("__dict__", "__weakref__"):
                continue
            if name.startswith("__") and not name.endswith("__"):
                name = f"_{cls.__name__.lstrip('_')}{name}"
            try:
                found.append(object.__getattribute__(value, name))
            except AttributeError:
                continue
    return found


def _holds_input(values: list[object], walk: _Walk, depth: int) -> bool:
    return not _all_scalar(values) and any(
        _withheld(v, walk, depth) is not v for v in values
    )


def _quotes_input(exc: BaseException, walk: _Walk, depth: int) -> bool:
    """Whether `exc` is a pydantic or FastAPI validation error (classes named by package, so this
    module imports neither), or anything in its cause / context chain, its exception group or its
    arguments is one or holds one, or an entry of one's `errors()`."""
    if _is_validation_error(exc):
        return True
    members = getattr(exc, "exceptions", None)
    inner = (
        [m for m in members if isinstance(m, BaseException)]
        if isinstance(members, tuple)
        else []
    )
    for linked in [exc.__cause__, exc.__context__, *inner]:
        if linked is not None and _withheld(linked, walk, depth) is not linked:
            return True
    args = exc.args
    if not isinstance(args, tuple) or _withheld(args, walk, depth + 1) is not args:
        return True
    # what `str()` of an exception often reads instead of its args (`HTTPException.detail`)
    return _holds_input(_attributes(exc), walk, depth + 1)


def _is_validation_error(exc: BaseException) -> bool:
    """A pydantic or FastAPI validation error, by its class alone (named by package, so this module
    imports neither)."""
    return any(
        cls.__module__.partition(".")[0] in _QUOTING_PACKAGES
        and cls.__name__ in _QUOTING_CLASSES
        for cls in type(exc).__mro__
    )


# How many values the one search of a log call looks at before it stops, finding nothing.
_MAX_SEARCHED = 20_000


def _below(value: object) -> list[object]:
    """The values the search looks into next: what the walk would reach from `value`."""
    if isinstance(value, BaseException):
        members = getattr(value, "exceptions", None)
        return [
            value.__cause__,
            value.__context__,
            *(members if isinstance(members, tuple) else ()),
            *(value.args if isinstance(value.args, tuple) else (value.args,)),
            *_attributes(value),
        ]
    if isinstance(value, Mapping):
        return [*value.keys(), *value.values()]
    if isinstance(value, (*_CONTAINERS, KeysView, ValuesView, ItemsView)):
        return list(value)
    if isinstance(value, _SCALAR_BASES | _OPAQUE):
        return []
    return _attributes(value)


def _found_in(roots: tuple[object, ...]) -> list[bool]:
    """For each argument or field of one log call, whether it is or holds a validation error or an
    `errors()` entry: an iterative search of each (no recursion, no depth bound), in order, each
    value looked at once per argument. Only an argument that holds one is walked and withheld, so an
    ordinary error whose live response graph is cyclic or large (an HTTP client's status error, a
    database client's API error) is written as passed, beside a validation error too. The searches
    of one call share `_MAX_SEARCHED` values: an argument not cleared within it, or holding a value
    the search cannot read, is walked, as one that holds input is."""
    holds: list[bool] = []
    searched = 0
    for root in roots:
        if searched >= _MAX_SEARCHED:
            holds.append(
                True
            )  # not cleared within the budget: the bounded walk decides
            continue
        found, used = _search(root, _MAX_SEARCHED - searched)
        searched += used
        holds.append(found)
    return holds


def _search(root: object, budget: int) -> tuple[bool, int]:
    """Whether `root` is or holds a validation error or an `errors()` entry, and how many values the
    search looked at. Not cleared within `budget` values counts as found."""
    seen: dict[
        int, object
    ] = {}  # holding each value, so no id is reused while it searches
    todo = [root]
    while todo:
        if len(seen) >= budget:
            return True, len(seen)
        item = todo.pop()
        if (
            item is None
            or isinstance(item, str | bytes | int | float)
            or id(item) in seen
        ):
            continue
        seen[id(item)] = item
        try:
            if isinstance(item, BaseException) and _is_validation_error(item):
                return True, len(seen)
            if isinstance(item, Mapping) and _ERROR_ENTRY.issubset(item.keys()):
                return True, len(seen)
            below = _below(item)
            if not _all_scalar(below):  # rows of plain values hold nothing to find
                todo.extend(reversed(below))
        except _VALUE_ERRORS:
            return True, len(seen)  # a value it cannot read is not one it has cleared
    return False, len(seen)


def _withheld(value: object, walk: _Walk, depth: int) -> object:
    """`value` itself when it holds no validation error, else a copy without one: such an error is
    written as its type, an `errors()` entry without its `input`."""
    if value is None or isinstance(value, str | bytes | int | float):
        return value
    key = id(value)
    if key in walk.done:
        return walk.done[key]
    if key in walk.at:
        # a cycle: the value is being answered further up. What is answered below it until then
        # leans on that answer, so it is not kept (`walk.low`).
        walk.low = min(walk.low, walk.at[key])
        return value if isinstance(value, BaseException) else "[...]"
    if walk.left <= 0:
        return f"<{type(value).__qualname__}: too much to look through, withheld>"
    walk.left -= 1
    place = len(walk.at)
    walk.at[key] = place
    outer = walk.low
    walk.low = _CLEAR
    try:
        out = _withheld_new(value, walk, depth)
    except _VALUE_ERRORS:
        out = f"<{type(value).__qualname__}: unreadable, withheld>"
    finally:
        del walk.at[key]
        inner = walk.low
        # kept only when no cycle below it reached past it: then the answer is its own
        if inner >= place:
            walk.done[key] = out
            inner = _CLEAR
        walk.low = min(outer, inner)
    return out


def _root(value: object, walk: _Walk, place: int, depth: int) -> object:
    """An argument or field of the log call: walked only when its search found a validation error."""
    return _withheld(value, walk, depth) if walk.holds[place] else value


def _withheld_new(value: object, walk: _Walk, depth: int) -> object:
    if isinstance(value, KeysView | ValuesView | ItemsView):
        # `.keys()`, `.values()`, `.items()` render what they view
        items = list(value)
        walk.kept.append(items)
        hidden = _withheld(items, walk, depth)
        return value if hidden is items else hidden
    if isinstance(value, BaseException):
        if _quotes_input(value, walk, depth):
            return f"<{type(value).__qualname__}: input withheld>"
        return value
    container = isinstance(value, Mapping | list | tuple | set | frozenset | deque)
    if not container and isinstance(value, _SCALAR_BASES | _OPAQUE):
        return value
    if depth >= _MAX_DEPTH:
        return f"<{type(value).__qualname__} nested past {_MAX_DEPTH} levels: withheld>"
    if not container:
        # an object (a dataclass, a result record) whose repr would print what it holds
        if _holds_input(_attributes(value), walk, depth + 1):
            return f"<{type(value).__qualname__}: input withheld>"
        return value
    if isinstance(value, Mapping):
        entry = _ERROR_ENTRY.issubset(value.keys())
        if not entry and _all_scalar(value.keys()) and _all_scalar(value.values()):
            return value
        templated = entry and value["type"] in _TEMPLATED_ERRORS
        pairs = [
            (_withheld(k, walk, depth + 1), _withheld(v, walk, depth + 1))
            for k, v in value.items()
            if not entry or (k != "input" if templated else k in _UNTEMPLATED_KEPT)
        ]
        if entry or any(
            k is not old_k or v is not old_v
            for (k, v), (old_k, old_v) in zip(pairs, value.items(), strict=True)
        ):
            return dict(pairs)
        return value
    if not isinstance(value, _CONTAINERS) or _all_scalar(value):
        return value
    items = [_withheld(v, walk, depth + 1) for v in value]
    if all(new is old for new, old in zip(items, value, strict=True)):
        return value
    kind = next(t for t in _CONTAINERS if isinstance(value, t))
    return kind(items)


def _hide_input(value: object) -> object:
    return _root(value, _Walk(value), 0, 0)


def _hidden_fields(fields: dict[str, Any]) -> dict[str, Any]:
    """The caller's fields, each through `_withheld`: a field the JSON line writes with `str()`."""
    if _all_scalar(fields.values()):
        return fields
    walk = _Walk(*fields.values())
    return {k: _root(v, walk, i, 1) for i, (k, v) in enumerate(fields.items())}


def _withhold_input(exc_info: _SysExcInfo) -> _SysExcInfo:
    """`exc_info`, or, when its chain holds a validation error, the same frames under a message that
    names the exception type and withholds the text."""
    exc = exc_info[1]
    if exc is None or _hide_input(exc) is exc:
        return exc_info
    kept = RuntimeError(
        f"{type(exc).__qualname__} (message withheld: its chain holds a validation error's input)"
    )
    return (RuntimeError, kept, exc_info[2])


class _Withholding(logging.Formatter):
    """A formatter whose line never quotes a validation error's input, for every logger (a server's
    own `Exception in ASGI application` line included): not in a traceback, a `%` argument, an
    `extra=` field or a `log_context` field."""

    def formatException(self, ei: _SysExcInfo) -> str:
        return super().formatException(_withhold_input(ei))

    def message(self, record: logging.LogRecord) -> str:
        """`record.getMessage()`, with each validation error in a `%` argument (or the message), at
        any depth of a list, tuple, set or dict, replaced by its type name, and each `errors()` entry
        written without its `input`: `logger.exception("failed: %s", err)` would print its text."""
        args, msg = record.args, record.msg
        if type(msg) is str and (
            not args or (type(args) is tuple and _all_scalar(args))
        ):
            return record.getMessage()
        walk = _Walk(msg, *args) if isinstance(args, tuple) else _Walk(msg, args)
        safe_msg = _root(msg, walk, 0, 0)
        safe_args = args
        if isinstance(args, tuple):
            hidden = tuple(_root(a, walk, i, 1) for i, a in enumerate(args, start=1))
            if any(new is not old for new, old in zip(hidden, args, strict=True)):
                safe_args = hidden
        elif isinstance(args, Mapping):
            # the one mapping argument of `log("%(e)s", {...})` is itself what `%s` would print
            hidden_map = _root(args, walk, 1, 0)
            if isinstance(hidden_map, Mapping):
                safe_args = hidden_map
            else:
                safe_msg = hidden_map
        if safe_msg is msg and safe_args is args:
            return record.getMessage()
        clone = copy.copy(record)
        clone.msg = safe_msg
        clone.args = () if safe_msg is not msg else safe_args
        return clone.getMessage()


class JsonFormatter(_Withholding):
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
            "message": self.message(record),
            "service": self.service,
            "version": self.version,
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
            "thread_name": record.threadName,
        }
        if self.environment:
            line["environment"] = self.environment
        attributes = _hidden_fields({**_bound(), **_extras(record)})
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
            text = json.dumps(line, default=str, ensure_ascii=False, allow_nan=False)
        except _VALUE_ERRORS:
            # A circular structure, a non-string key, NaN/Infinity, or a value whose str() raises:
            # stock logging would still print this record, so it must not be lost here either.
            safe = {str(k): _plain(v) for k, v in line.items() if k != "attributes"}
            if isinstance(line.get("attributes"), Mapping):
                safe["attributes"] = {
                    str(k): _plain(v) for k, v in line["attributes"].items()
                }
            text = json.dumps(safe, ensure_ascii=False)
        return _encodable(text)


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


class TextFormatter(_Withholding):
    """`LOG_FORMAT=text`: one readable line for a terminal; context and extras appended as k=v.

    Built from the same fields as the JSON line, and through the same redactor: a developer's
    terminal is still a place personal data must not reach."""

    def __init__(self, redact: Redactor | None = None) -> None:
        super().__init__()
        self.redact = redact

    def format(self, record: logging.LogRecord) -> str:
        # `logger` is there for the redactor (one that scrubs by logger), as in the JSON line; the
        # head below names the logger, so it is not repeated in the tail
        line: dict[str, Any] = {"message": self.message(record), "logger": record.name}
        if record.exc_info:
            line["exception"] = self.formatException(record.exc_info)
        if record.stack_info:
            line["stack"] = self.formatStack(record.stack_info)
        extras = _extras(record)
        for otel, ours in _TRACE_FIELDS.items():
            if otel in extras:
                line[ours] = extras.pop(otel)
        line, attributes = _redacted(
            line, _hidden_fields({**_bound(), **extras}), self.redact
        )
        line.pop("logger", None)
        message = _one_line(str(line.pop("message", "")))
        # A traceback keeps its own lines, each indented under the record's head and with its
        # control characters escaped, so an exception message cannot start a line of its own.
        trace = [
            f"    {_one_line(part)}"
            for k in ("exception", "stack")
            if k in line
            for part in str(line.pop(k)).split("\n")
        ]
        head = (
            f"{self.formatTime(record)} {_one_line(str(record.levelname))} "
            f"{_one_line(str(record.name))} {message}"
        )
        tail = " ".join(
            f"{_one_line(str(k))}={_one_line(str(v))}"
            for k, v in [*line.items(), *attributes.items()]
        )
        text = "\n".join([f"{head} {tail}" if tail else head, *trace])
        return _SURROGATE.sub(lambda m: f"\\u{ord(m.group()):04x}", text)


# The code points UTF-8 cannot encode: a `str` holds them only as lone surrogates.
_SURROGATE = re.compile("[\ud800-\udfff]")
# What `json.dumps` leaves raw and a line reader may still break a line at.
_LINE_BREAKS = re.compile("[\x85\u2028\u2029]")
# Every control character but a tab, and the two Unicode line separators: one text line holds none.
_CONTROL = re.compile("[\x00-\x08\x0a-\x1f\x7f-\x9f\u2028\u2029]")


def _encodable(text: str) -> str:
    """A JSON line as UTF-8 carries it: each lone surrogate becomes an escaped backslash and `uXXXX`,
    so the line parses to the six characters of the escape. JSON's own `\\uXXXX` would parse back to
    the surrogate, which some readers refuse (and stop at), and a high one followed by a low one
    would read as the single character they spell. A line separator becomes its JSON escape."""
    text = _SURROGATE.sub(lambda m: f"\\\\u{ord(m.group()):04x}", text)
    return _LINE_BREAKS.sub(lambda m: f"\\u{ord(m.group()):04x}", text)


def _one_line(text: str) -> str:
    """`text` on one line of a terminal: each control character but a tab as its escape."""
    return _CONTROL.sub(
        lambda m: m.group().encode("unicode_escape").decode("ascii"), text
    )


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
    trace_ids: TraceIds | None = None,
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
    envelope (message, `logger` and traceback included) and, separately, on the caller's fields (context and
    `extra=`, flat, under their own names); each returns the dict to write. If either raises, the line
    keeps its fixed fields and says the redaction failed; the unscrubbed content is dropped.

    `trace_ids` is the tracing module's `current_trace_ids`: every record made inside a span gets
    `trace_id` and `span_id`. A record whose `extra=` names `otelTraceID` or `otelSpanID` itself keeps
    the caller's and gets none from the span: the two ids of a line always come from one place.
    `luxarch --emit logging-contract` is the contract test for this source.

    Idempotent: calling it again replaces the handler instead of adding a second one.
    """
    # The documented override point (Python docs: "can be overridden in subclasses"), installed on the
    # base class so loggers created before this call, and third-party ones, are covered as well.
    setattr(logging.Logger, _OVERRIDDEN, _make_record)
    _trace_ids[0] = trace_ids
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
