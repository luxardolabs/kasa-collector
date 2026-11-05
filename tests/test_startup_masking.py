"""No part of the TP-Link account credentials or the InfluxDB token reaches the log."""

import hashlib
import io
import json
import logging
from unittest.mock import AsyncMock

import pytest
from kasa import Credentials, DeviceConfig
from kasa.transports.ssltransport import SslTransport

from app.core.config import Config
from app.main import KasaCollector, _mask, configure_app_logging

SECRETS = [
    "x",
    "hunter2",
    "hunter2!9",
    "Summer2026",
    "Tr0ub4dor&3",
    "P@ssw0rd2026",
    "a-much-longer-influxdb-token-of-forty-ch",
    "None",
    "   ",
]

# Fake values whose 4-character windows appear nowhere else in the log, assembled here so
# the secret scan never sees a credential-shaped literal.
PASSWORD = "".join(["Qz7#", "Kp9!", "wXv"])
TOKEN = "".join(["Jq3v", "Tm8s", "Rw2y", "Lp5d"])
USERNAME = "".join(["zqx.wvb", "@qjzpkw"])
URL_PASSWORD = "".join(["FAKE", "urlPw9xQ"])


def _assert_no_window(text, secrets):
    for secret in secrets:
        for i in range(max(len(secret) - 3, 1)):
            assert secret[i : i + 4] not in text, f"{secret[i : i + 4]!r} logged"


@pytest.fixture
def credentials(monkeypatch):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", PASSWORD)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_USERNAME", USERNAME)
    monkeypatch.setattr(Config, "KASA_COLLECTOR_INFLUXDB_TOKEN", TOKEN)
    monkeypatch.setattr(
        Config,
        "KASA_COLLECTOR_INFLUXDB_URL",
        f"http://admin:{URL_PASSWORD}@influx.invalid:8086",
    )


@pytest.fixture(params=["text", "json"])
def app_log(request, monkeypatch, credentials):
    """The process's real logging setup, as `python -m app.main` installs it, in each
    LOG_FORMAT, with the installed stdout handler pointed at a buffer the test reads."""
    monkeypatch.setenv("LOG_FORMAT", request.param)
    monkeypatch.setenv("LOG_MODULE_LEVELS", '{"kasa": "DEBUG"}')
    configure_app_logging()
    buffer = io.StringIO()
    (handler,) = logging.getLogger().handlers
    assert isinstance(handler, logging.StreamHandler)
    handler.setStream(buffer)
    yield buffer
    logging.getLogger("kasa").setLevel(logging.WARNING)


@pytest.mark.unit
class TestMask:
    @pytest.mark.parametrize("secret", SECRETS)
    def test_reveals_no_character_and_no_length(self, secret):
        shown = _mask(secret)
        assert shown == "****"
        assert shown == _mask("y" * 64)

    def test_unset_value_stays_visible_as_unset(self):
        assert _mask(None) == "None"
        assert _mask("") == ""


@pytest.mark.unit
def test_startup_dump_logs_no_part_of_any_secret(credentials, caplog):
    # Only the config dump is under test: skip __init__'s device manager and poller.
    collector = object.__new__(KasaCollector)
    collector.logger = logging.getLogger("test.startup-dump")

    with caplog.at_level(logging.INFO, logger="test.startup-dump"):
        collector.check_required_configs()

    for name in ("TPLINK_PASSWORD", "TPLINK_USERNAME", "INFLUXDB_TOKEN"):
        assert f"KASA_COLLECTOR_{name}: ****" in caplog.text
    assert "KASA_COLLECTOR_INFLUXDB_URL: http://****@influx.invalid:8086" in caplog.text
    _assert_no_window(caplog.text, (PASSWORD, TOKEN, USERNAME, URL_PASSWORD))


@pytest.mark.unit
def test_password_whose_value_is_the_word_none_is_masked(monkeypatch, caplog):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", "None")
    collector = object.__new__(KasaCollector)
    collector.logger = logging.getLogger("test.startup-dump")

    with caplog.at_level(logging.INFO, logger="test.startup-dump"):
        collector.check_required_configs()

    assert "KASA_COLLECTOR_TPLINK_PASSWORD: ****" in caplog.text


@pytest.mark.unit
def test_influxdb_url_password_never_reaches_a_log_line(app_log):
    logging.getLogger("InfluxDBStorage").error(
        "Could not reach InfluxDB at: %s", Config.KASA_COLLECTOR_INFLUXDB_URL
    )
    out = app_log.getvalue()
    assert "Could not reach InfluxDB at: http://admin:****@influx.invalid:8086" in out
    _assert_no_window(out, (URL_PASSWORD,))


@pytest.mark.unit
async def test_python_kasa_debug_login_logs_no_credential(app_log):
    transport = SslTransport(
        config=DeviceConfig(
            host="192.0.2.10", credentials=Credentials(USERNAME, PASSWORD)
        )
    )
    transport._http_client.post = AsyncMock(
        return_value=(200, {"error_code": 0, "result": {"token": "T"}})
    )

    await transport.try_login(transport._get_login_params(transport._credentials))

    out = app_log.getvalue()
    assert (
        "Sending" in out and "login" in out
    )  # the DEBUG line was written: the control
    md5 = hashlib.md5(PASSWORD.encode(), usedforsecurity=False).hexdigest()
    _assert_no_window(out, (USERNAME, PASSWORD, md5, md5.upper()))


@pytest.mark.unit
async def test_python_kasa_debug_klap_handshake_logs_no_crackable_hash(app_log):
    # KLAP's handshake1 DEBUG lines carry both seeds and the server hash
    # (sha256(local_seed + remote_seed + auth_hash), auth_hash from the TP-Link username
    # and password): together they allow an offline guess of the password.
    from kasa.transports.klaptransport import KlapTransport

    transport = KlapTransport(
        config=DeviceConfig(
            host="192.0.2.11", credentials=Credentials(USERNAME, PASSWORD)
        )
    )
    remote_seed = bytes(range(16))
    sent: list[bytes] = []

    async def post(url, *, data=None, **kwargs):
        sent.append(data)
        server_hash = transport.handshake1_seed_auth_hash(
            data, remote_seed, transport._local_auth_hash
        )
        return 200, remote_seed + server_hash

    transport._http_client.post = post

    await transport.perform_handshake1()

    out = app_log.getvalue()
    assert "Handshake1 success" in out  # the DEBUG lines were written: the control
    server_hash = transport.handshake1_seed_auth_hash(
        sent[0], remote_seed, transport._local_auth_hash
    )
    for secret in (sent[0].hex(), remote_seed.hex(), server_hash.hex()):
        assert secret not in out, f"{secret[:8]}… logged"


def test_python_kasa_transport_traceback_logs_no_hex_run(app_log):
    # A transport error can carry handshake bytes in its message; the traceback the
    # formatter renders must be scrubbed like the message is.
    hex_run = "ab" * 32
    try:
        raise RuntimeError(f"server hash {hex_run}")
    except RuntimeError:
        logging.getLogger("kasa.transports.klaptransport").warning(
            "handshake failed", exc_info=True
        )

    out = app_log.getvalue()
    assert "handshake failed" in out
    assert "RuntimeError" in out  # the failure itself is still reported
    assert hex_run not in out


def test_a_traceback_outside_the_transports_keeps_its_own_field(app_log):
    try:
        raise RuntimeError("energy module torn")
    except RuntimeError:
        logging.getLogger("KasaCollector").warning("read failed", exc_info=True)

    out = app_log.getvalue()
    assert "energy module torn" in out
    assert "Traceback" in out


# A configured password holding a 32-hex run between other characters, assembled so the
# secret scan never sees a credential-shaped literal.
HEX_CORE_PASSWORD = "".join(["Zq9#", "0123456789abcdef" * 2, "!Wv7"])


@pytest.fixture(params=["text", "json"])
def hex_secret_log(request, monkeypatch, credentials):
    monkeypatch.setattr(Config, "KASA_COLLECTOR_TPLINK_PASSWORD", HEX_CORE_PASSWORD)
    monkeypatch.setenv("LOG_FORMAT", request.param)
    configure_app_logging()
    buffer = io.StringIO()
    (handler,) = logging.getLogger().handlers
    handler.setStream(buffer)
    return request.param, buffer


def _log_transport_failure(text):
    try:
        raise RuntimeError(text)
    except RuntimeError:
        logging.getLogger("kasa.transports.sslaestransport").warning(
            "login failed", exc_info=True
        )


def test_a_secret_holding_a_hex_run_is_redacted_whole_in_a_transport_traceback(
    hex_secret_log,
):
    _, buffer = hex_secret_log
    _log_transport_failure(f"login rejected for {HEX_CORE_PASSWORD}")

    out = buffer.getvalue()
    assert "login rejected for ****" in out
    for part in ("Zq9#", "0123456789abcdef", "!Wv7"):
        assert part not in out, f"{part!r} logged"


def test_a_transport_traceback_keeps_its_exception_type_and_its_own_lines(
    hex_secret_log,
):
    fmt, buffer = hex_secret_log
    _log_transport_failure("handshake refused")

    out = buffer.getvalue()
    assert "handshake refused" in out
    if fmt == "json":
        line = json.loads(out)
        assert line["exception_type"] == "RuntimeError"
        assert "handshake refused" in line["exception"]
    else:
        assert len(out.strip().splitlines()) > 1


def test_a_malformed_transport_log_call_never_raises_into_python_kasa(app_log, capsys):
    # The format wants two arguments and gets one. The record goes through the installed
    # handler alone: pytest's own capture handler re-raises logging errors by design.
    logger = logging.getLogger("kasa.transports.klaptransport")
    record = logger.makeRecord(
        logger.name, logging.WARNING, __file__, 1, "seed %s and %s", (1,), None
    )
    (installed,) = [
        h for h in logging.getLogger().handlers if getattr(h, "stream", None) is app_log
    ]

    installed.handle(record)

    assert "Logging error in kasa.transports.klaptransport" in capsys.readouterr().err
    assert "seed" not in app_log.getvalue()


@pytest.fixture(params=["text", "json"])
def log_with(request, monkeypatch, credentials):
    """The real logging setup in each format, with the credentials the test sets."""

    def install(**settings):
        for name, value in settings.items():
            monkeypatch.setattr(Config, name, value)
        monkeypatch.setenv("LOG_FORMAT", request.param)
        configure_app_logging()
        buffer = io.StringIO()
        (handler,) = logging.getLogger().handlers
        handler.setStream(buffer)
        return buffer

    return install


def test_a_hex_only_secret_inside_a_handshake_run_leaves_none_of_the_run(log_with):
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD="".join(["4", "8", "1", "5"]))
    seed = "0123456789abcdef" + "4815" + "0123456789abcdef"
    logging.getLogger("kasa.transports.klaptransport").warning(
        "remote_seed is: %s", seed
    )

    out = buffer.getvalue()
    assert "remote_seed is: ****" in out
    assert "0123456789abcdef" not in out


def test_overlapping_secrets_leave_no_tail(log_with):
    username = "".join(["kq.user-", "ABCD"])
    token = "".join(["ABCD-", "tok9xy"])
    buffer = log_with(
        KASA_COLLECTOR_TPLINK_USERNAME=username, KASA_COLLECTOR_INFLUXDB_TOKEN=token
    )
    logging.getLogger("KasaCollector").warning("cred %s", "kq.user-ABCD-tok9xy")

    out = buffer.getvalue()
    assert "cred ****" in out
    assert "tok9xy" not in out and "kq.user" not in out


def test_a_secret_in_its_repr_form_is_redacted(log_with):
    password = "".join(["Qz7", "\\", "Kp9wXv"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    try:
        {}[password]
    except KeyError:
        logging.getLogger("KasaAPI").warning("lookup failed", exc_info=True)

    out = buffer.getvalue()
    assert "KeyError" in out
    assert "Kp9wXv" not in out


def test_a_transport_traceback_names_no_stand_in_exception(app_log):
    try:
        raise RuntimeError("handshake refused")
    except RuntimeError:
        logging.getLogger("kasa.transports.klaptransport").warning(
            "login failed", exc_info=True
        )

    out = app_log.getvalue()
    assert "RuntimeError: handshake refused" in out
    assert "Scrubbed" not in out


SESSION_HEX = "".join(["0123456789ABCDEF", "FEDCBA9876543210"])


def test_a_python_kasa_http_request_url_logs_no_session_token(log_with):
    # python-kasa's HTTP client logs every request URL at DEBUG, and the AES and SSL
    # transports put the session token in its query.
    buffer = log_with()
    logging.getLogger("kasa").setLevel(logging.DEBUG)
    try:
        logging.getLogger("kasa.httpclient").debug(
            "Posting to %s", f"http://192.0.2.5/app?token={SESSION_HEX}"
        )
    finally:
        logging.getLogger("kasa").setLevel(logging.WARNING)

    out = buffer.getvalue()
    assert "Posting to http://192.0.2.5/app?token=****" in out
    assert SESSION_HEX[:16] not in out


def test_an_app_logger_keeps_its_hex_device_ids(log_with):
    buffer = log_with()
    device_id = "".join(["8006", "A1B2C3D4E5F6", "0718293A4B5C6D7E8F90", "AB12"])
    logging.getLogger("KasaCollector").warning("polled %s", device_id)

    assert device_id in buffer.getvalue()


def test_secrets_nested_in_fields_and_keys_are_scrubbed(log_with):
    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "payloads",
        extra={
            "nested": {"pw": PASSWORD},
            "listed": [TOKEN],
            "raw": PASSWORD.encode(),
            PASSWORD: 1,
        },
    )

    _assert_no_window(buffer.getvalue(), [PASSWORD, TOKEN])


def test_a_multiline_secret_in_an_exception_group_is_scrubbed(log_with):
    password = "".join(["Qz7#Ab", "\n", "Kp9!wXv"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    try:
        raise ExceptionGroup("tasks failed", [RuntimeError(password)])
    except ExceptionGroup:
        logging.getLogger("KasaCollector").warning("failed", exc_info=True)

    out = buffer.getvalue()
    assert "Qz7#Ab" not in out and "Kp9!wXv" not in out


def test_a_password_holding_a_lone_surrogate_still_starts_logging(log_with):
    password = "".join(["Qz7#", "\udcff", "Kp9!"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    logging.getLogger("KasaCollector").warning("started")

    assert "started" in buffer.getvalue()


def test_a_secret_inside_an_object_field_is_scrubbed(log_with):
    # The formatter writes an object field's str after the redactor has run.
    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "failed",
        extra={
            "err": RuntimeError(f"login failed for {PASSWORD}"),
            "nested": {"err": RuntimeError(f"token {TOKEN}")},
        },
    )

    out = buffer.getvalue()
    assert "login failed for ****" in out
    _assert_no_window(out, [PASSWORD, TOKEN])


def test_a_non_ascii_secret_in_a_bytes_field_is_scrubbed(log_with):
    password = "".join(["Grüß", "e2026!x"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    logging.getLogger("KasaCollector").warning(
        "raw", extra={"raw": password.encode("utf-8")}
    )

    out = buffer.getvalue()
    assert "e2026!x" not in out
    assert "\\xc3" not in out


def test_a_tuple_key_in_a_field_keeps_the_line(log_with):
    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "grid", extra={"cells": {(1, 2): "a", frozenset({3}): "b"}}
    )

    out = buffer.getvalue()
    assert "grid" in out
    assert "redactor failed" not in out


def test_a_self_referencing_field_keeps_the_line(log_with):
    buffer = log_with()
    loop: dict[str, object] = {"name": "loop"}
    loop["self"] = loop
    logging.getLogger("KasaCollector").warning("cyclic", extra={"loop": loop})

    out = buffer.getvalue()
    assert "cyclic" in out
    assert "redactor failed" not in out


def test_keys_that_scrub_alike_keep_both_values(log_with):
    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "keys",
        extra={"payload": {f"pw={PASSWORD}": "first", "pw=****": "second"}},
    )

    out = buffer.getvalue()
    assert "first" in out and "second" in out


def test_a_percent_encoded_influxdb_url_password_is_scrubbed_decoded(log_with):
    decoded = "".join(["Fake@", "urlPw9"])
    buffer = log_with(
        KASA_COLLECTOR_INFLUXDB_URL="http://admin:Fake%40urlPw9@influx.invalid:8086"
    )
    logging.getLogger("InfluxDBStorage").warning("auth %s", decoded)

    out = buffer.getvalue()
    assert "auth ****" in out
    assert "urlPw9" not in out


def test_a_quote_secret_beside_a_double_quote_is_scrubbed(log_with):
    # repr writes the secret's ' as \' once the same string also holds a ".
    password = "".join(["Qz7'", "Kp9wXv"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    logging.getLogger("KasaAPI").warning("said %r", f'{password} said "hi"')

    out = buffer.getvalue()
    assert "said" in out
    assert "Kp9wXv" not in out


def test_a_non_ascii_secret_in_logged_bytes_repr_is_scrubbed(log_with):
    password = "".join(["Grüß", "e2026!x"])
    buffer = log_with(KASA_COLLECTOR_TPLINK_PASSWORD=password)
    logging.getLogger("kasa.transports.klaptransport").warning(
        "payload %r", password.encode("utf-8")
    )

    out = buffer.getvalue()
    assert "payload" in out
    assert "2026!x" not in out


def test_a_url_password_requoted_in_uppercase_is_scrubbed(log_with):
    buffer = log_with(
        KASA_COLLECTOR_INFLUXDB_URL="http://admin:Fake%2furlPw9@influx.invalid:8086"
    )
    logging.getLogger("InfluxDBStorage").warning(
        "connecting to %s", "http://admin:Fake%2FurlPw9@influx.invalid:8086"
    )

    out = buffer.getvalue()
    assert "connecting to" in out
    assert "urlPw9" not in out


def test_a_str_subclass_field_is_written_as_its_plain_text(log_with):
    class Sneaky(str):
        def __str__(self):
            return PASSWORD

    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "note", extra={"note": Sneaky("benign-note")}
    )

    out = buffer.getvalue()
    assert "benign-note" in out
    _assert_no_window(out, [PASSWORD])


@pytest.mark.parametrize(
    "url",
    [
        "http://192.0.2.5/app?token=Ab3-short_TOKEN&seq=1",
        "https://192.0.2.5:443/stok=Ab3-short_TOKEN/ds",
    ],
)
def test_a_session_token_of_any_shape_is_scrubbed_from_a_request_url(log_with, url):
    buffer = log_with()
    logging.getLogger("kasa").setLevel(logging.DEBUG)
    try:
        logging.getLogger("kasa.httpclient").debug("Posting to %s", url)
    finally:
        logging.getLogger("kasa").setLevel(logging.WARNING)

    out = buffer.getvalue()
    assert "Posting to" in out
    assert "short_TOKEN" not in out


def test_a_field_key_whose_str_raises_keeps_the_line(log_with):
    class BadKey:
        def __str__(self):
            raise RuntimeError("no text")

        def __repr__(self):
            return "BadKey()"

    buffer = log_with()
    logging.getLogger("KasaCollector").warning("odd", extra={"map": {BadKey(): 1}})

    out = buffer.getvalue()
    assert "odd" in out
    assert "redactor failed" not in out


def test_a_field_whose_iteration_raises_keeps_the_line(log_with):
    class Broken(list):
        def __iter__(self):
            raise RuntimeError("cannot iterate")

    buffer = log_with()
    logging.getLogger("KasaCollector").warning(
        "broken", extra={"items": Broken([PASSWORD])}
    )

    out = buffer.getvalue()
    assert "broken" in out
    assert "redactor failed" not in out
    _assert_no_window(out, [PASSWORD])


def test_a_field_sharing_its_children_is_walked_in_bounded_time(log_with):
    import time

    shared: object = "leaf"
    for _ in range(20):
        shared = [shared] * 3  # 3**20 paths, 21 distinct objects

    buffer = log_with()
    started = time.monotonic()
    logging.getLogger("KasaCollector").warning("deep", extra={"tree": shared})

    assert time.monotonic() - started < 5
    assert "deep" in buffer.getvalue()


def test_many_keys_that_scrub_alike_are_named_in_linear_time(log_with):
    import time

    class Same:  # distinct keys with one text, as many objects of one kind would be
        def __str__(self):
            return "same"

    payload = {Same(): i for i in range(20_000)}
    buffer = log_with()
    started = time.monotonic()
    logging.getLogger("KasaCollector").warning("keys", extra={"payload": payload})

    assert time.monotonic() - started < 1
    assert "keys" in buffer.getvalue()


async def test_a_session_token_in_a_logged_login_reply_is_scrubbed(app_log):
    # python-kasa's SSL transport logs its login reply at DEBUG, the token a dict value.
    session = "".join(["ST7g", "Hq2R", "wK9p", "Lm4Z"])
    transport = SslTransport(
        config=DeviceConfig(
            host="192.0.2.10", credentials=Credentials(USERNAME, PASSWORD)
        )
    )
    transport._http_client.post = AsyncMock(
        return_value=(200, {"error_code": 0, "result": {"token": session}})
    )
    await transport.try_login(transport._get_login_params(transport._credentials))
    # A request after login carries the token in the URL query: the control.
    await transport.send_request('{"method": "get_device_info"}')

    out = app_log.getvalue()
    assert "token=****" in out  # control: the URL form is scrubbed
    assert "Response with 200" in out  # the response line was written
    assert session not in out, [l for l in out.splitlines() if session in l]


@pytest.mark.parametrize(
    "line",
    [
        "Response with 200: {'error_code': 0, 'result': {'token': '%s'}}",
        """KasaException('bad reply {\\'token\\': \\'%s\\'} at "x"')""",
        'payload "{\\"result\\": {\\"token\\": \\"%s\\"}}"',
    ],
    ids=["repr", "repr-escaped-quote", "json-in-json"],
)
def test_a_session_token_field_is_scrubbed_in_each_quoting(line):
    from app.main import _scrubbed

    token = "".join(["Zq81bQ", "7uLm0xT"])  # not hex: only the token patterns catch it
    assert "7uLm0xT" not in _scrubbed(line % token, [], hex_runs=True)
