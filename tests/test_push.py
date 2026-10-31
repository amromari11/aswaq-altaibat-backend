"""Push notifications: FCM payloads and responses (mock transport), the send-and-log flow,
token selection by audience (fake client) and the admin page (AppTest)."""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db
import utils.notifications as notifications
from utils.fcm import FcmClient, FcmConfigError, build_message, client_from_secrets, load_service_account

PAGE = Path(__file__).resolve().parent.parent / "app_pages" / "notifications.py"

ACCOUNT = {
    "type": "service_account",
    "project_id": "aswaq-test",
    "client_email": "push@aswaq-test.iam.gserviceaccount.com",
    "private_key": "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n",
}


# --- service-account secret ------------------------------------------------------


def test_service_account_accepts_a_toml_table_or_json_text():
    assert load_service_account(ACCOUNT)["project_id"] == "aswaq-test"
    assert load_service_account(json.dumps(ACCOUNT))["client_email"] == ACCOUNT["client_email"]


@pytest.mark.parametrize("raw", [None, "", "not json", "[]", {}, {**ACCOUNT, "type": "authorized_user"}, {**ACCOUNT, "private_key": ""}])
def test_service_account_rejects_anything_incomplete(raw):
    with pytest.raises(FcmConfigError):
        load_service_account(raw)


def test_no_secret_means_no_client_and_a_broken_one_is_reported():
    assert client_from_secrets({}) is None
    with pytest.raises(FcmConfigError):
        client_from_secrets({"FCM_SERVICE_ACCOUNT": "{broken"})


def test_a_real_looking_service_account_builds_google_credentials_offline():
    rsa = pytest.importorskip("cryptography.hazmat.primitives.asymmetric.rsa")
    from cryptography.hazmat.primitives import serialization

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    client = FcmClient({**ACCOUNT, "private_key": pem, "token_uri": "https://oauth2.googleapis.com/token"})
    assert client.project_id == "aswaq-test"


# --- message payload -------------------------------------------------------------


def test_message_has_a_visible_notification_for_both_platforms_and_string_data():
    msg = build_message("tok", "عنوان", "نص", {"type": "promo", "n": 5})["message"]
    assert msg["token"] == "tok"
    assert msg["notification"] == {"title": "عنوان", "body": "نص"}
    assert msg["data"] == {"type": "promo", "n": "5"}  # FCM rejects non-string data values
    assert msg["android"]["priority"] == "HIGH" and msg["android"]["notification"]["channel_id"] == "promotions"
    assert msg["apns"]["payload"]["aps"]["sound"] == "default"


def test_message_without_data_has_no_data_key():
    assert "data" not in build_message("tok", "t", "b")["message"]


# --- FCM transport ---------------------------------------------------------------


def fcm_error(status, code, message="m"):
    return httpx.Response(status, json={"error": {"status": code, "message": message, "details": [{"errorCode": code}]}})


def make_client(handler, **kw):
    return FcmClient(ACCOUNT, http=httpx.Client(transport=httpx.MockTransport(handler)), access_token=lambda: "BEARER", sleep=lambda s: None, **kw)


def test_every_token_gets_its_own_authorised_request_to_the_project():
    seen = []

    def handler(request):
        seen.append((str(request.url), request.headers["authorization"], json.loads(request.content)["message"]["token"]))
        return httpx.Response(200, json={"name": "projects/aswaq-test/messages/1"})

    out = make_client(handler).send_all(["t1", "t2", "t3"], "T", "B")
    assert out.sent == 3 and out.failed == 0 and out.dead == []
    assert {u for u, _, _ in seen} == {"https://fcm.googleapis.com/v1/projects/aswaq-test/messages:send"}
    assert {a for _, a, _ in seen} == {"Bearer BEARER"}
    assert sorted(t for _, _, t in seen) == ["t1", "t2", "t3"]


def test_access_token_is_fetched_once_per_batch():
    calls = []
    client = FcmClient(
        ACCOUNT,
        http=httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={}))),
        access_token=lambda: calls.append(1) or "B",
    )
    client.send_all([f"t{i}" for i in range(20)], "T", "B")
    assert len(calls) == 1


def test_empty_batch_sends_nothing():
    out = make_client(lambda r: pytest.fail("no request expected")).send_all([], "T", "B")
    assert (out.sent, out.failed, out.dead) == (0, 0, [])


def test_dead_tokens_are_reported_for_removal_not_counted_as_failures():
    def handler(request):
        token = json.loads(request.content)["message"]["token"]
        if token == "gone":
            return fcm_error(404, "UNREGISTERED", "Requested entity was not found.")
        if token == "bad":
            return fcm_error(400, "INVALID_ARGUMENT", "The registration token is not a valid FCM registration token")
        return httpx.Response(200, json={})

    out = make_client(handler).send_all(["ok", "gone", "bad"], "T", "B")
    assert out.sent == 1 and sorted(out.dead) == ["bad", "gone"] and out.failed == 0


def test_an_invalid_payload_is_a_failure_not_a_dead_token():
    out = make_client(lambda r: fcm_error(400, "INVALID_ARGUMENT", "Invalid value at message.notification.title")).send_all(["t"], "T", "B")
    assert out.dead == [] and out.failed == 1 and "INVALID_ARGUMENT" in out.errors[0]


def test_bad_credentials_fail_once_without_retrying():
    calls = []

    def handler(request):
        calls.append(1)
        return fcm_error(401, "UNAUTHENTICATED", "Request had invalid authentication credentials.")

    out = make_client(handler).send_all(["t"], "T", "B")
    assert len(calls) == 1 and out.failed == 1 and out.sent == 0 and "UNAUTHENTICATED" in out.errors[0]


def test_a_transient_error_is_retried_once():
    answers = iter([fcm_error(503, "UNAVAILABLE"), httpx.Response(200, json={})])
    out = make_client(lambda r: next(answers)).send_all(["t"], "T", "B")
    assert out.sent == 1 and out.failed == 0


def test_a_persistent_transient_error_gives_up_after_the_retry():
    calls = []
    out = make_client(lambda r: calls.append(1) or fcm_error(429, "QUOTA_EXCEEDED")).send_all(["t"], "T", "B")
    assert len(calls) == 2 and out.failed == 1


def test_a_network_error_is_a_failure_with_a_readable_reason():
    def handler(request):
        raise httpx.ConnectError("boom")

    out = make_client(handler).send_all(["t"], "T", "B")
    assert out.failed == 1 and "ConnectError" in out.errors[0]


def test_identical_failures_are_listed_once():
    out = make_client(lambda r: fcm_error(403, "SENDER_ID_MISMATCH")).send_all(["a", "b", "c"], "T", "B")
    assert out.failed == 3 and len(out.errors) == 1


# --- send_push_notification: pick devices, send, log -------------------------------


class FakeFcm:
    project_id = "aswaq-test"

    def __init__(self, outcome=None, error=None):
        from utils.fcm import SendOutcome

        self.outcome = outcome or SendOutcome()
        self.error = error
        self.calls = []

    def send_all(self, tokens, title, body, data=None):
        self.calls.append((list(tokens), title, body, dict(data or {})))
        if self.error:
            raise self.error
        return self.outcome


@pytest.fixture
def flow(monkeypatch):
    state = {"tokens": ["t1", "t2"], "inserted": [], "updates": [], "deleted": [], "fetches": []}

    def insert(payload):
        state["inserted"].append(payload)
        return {"id": "n1", **payload}

    monkeypatch.setattr(notifications, "insert_notification", insert)
    monkeypatch.setattr(notifications, "fetch_push_tokens", lambda a, u: state["fetches"].append((a, u)) or state["tokens"])
    monkeypatch.setattr(notifications, "delete_push_tokens", lambda t: state["deleted"].append(list(t)))
    monkeypatch.setattr(
        notifications, "update_notification_result",
        lambda nid, **kw: state["updates"].append({"id": nid, **kw}),
    )
    return state


def outcome(**kw):
    from utils.fcm import SendOutcome

    return SendOutcome(**kw)


def test_a_successful_send_reaches_every_device_and_is_logged(flow):
    fcm = FakeFcm(outcome(sent=2))
    result = notifications.send_push_notification("عنوان", "نص", "all", None, client=fcm)
    assert result == {"delivered": True, "recipient_count": 2, "failed_count": 0, "error": None}
    assert fcm.calls == [(["t1", "t2"], "عنوان", "نص", {"type": "promo", "notification_id": "n1"})]
    assert flow["inserted"][0]["status"] == "queued"
    assert flow["updates"] == [{"id": "n1", "status": "sent", "recipient_count": 2, "failed_count": 0, "error_message": None}]
    assert flow["deleted"] == []


def test_audience_and_target_decide_which_devices_are_fetched(flow):
    notifications.send_push_notification("t", "b", "single_user", "u-1", client=FakeFcm(outcome(sent=1)))
    notifications.send_push_notification("t", "b", "weekly_offer_subscribers", None, client=FakeFcm(outcome(sent=1)))
    assert flow["fetches"] == [("single_user", "u-1"), ("weekly_offer_subscribers", None)]
    assert flow["inserted"][0]["target_user_id"] == "u-1"


def test_no_registered_devices_is_logged_as_failed_and_fcm_is_not_called(flow):
    flow["tokens"] = []
    fcm = FakeFcm()
    result = notifications.send_push_notification("t", "b", "all", None, client=fcm)
    assert result["delivered"] is False and fcm.calls == []
    assert flow["updates"][0]["status"] == "failed" and flow["updates"][0]["recipient_count"] == 0
    assert "أجهزة" in flow["updates"][0]["error_message"]


def test_without_credentials_nothing_is_sent_and_the_log_says_why(flow):
    result = notifications.send_push_notification("t", "b", "all", None, client_factory=lambda: (None, "FCM_SERVICE_ACCOUNT ناقص: private_key"))
    assert result["delivered"] is False
    assert flow["updates"][0]["status"] == "failed" and "private_key" in flow["updates"][0]["error_message"]


def test_dead_tokens_are_removed_and_counted_as_failed(flow):
    fcm = FakeFcm(outcome(sent=1, dead=["t2"]))
    result = notifications.send_push_notification("t", "b", "all", None, client=fcm)
    assert flow["deleted"] == [["t2"]]
    assert result["delivered"] is True and result["recipient_count"] == 1 and result["failed_count"] == 1
    assert flow["updates"][0]["status"] == "sent" and "تمت إزالته" in flow["updates"][0]["error_message"]


def test_when_fcm_accepts_none_the_log_is_failed_with_the_reasons(flow):
    fcm = FakeFcm(outcome(failed=2, errors=["UNAUTHENTICATED: bad key"]))
    result = notifications.send_push_notification("t", "b", "all", None, client=fcm)
    assert result["delivered"] is False and result["failed_count"] == 2
    assert flow["updates"][0]["status"] == "failed" and "UNAUTHENTICATED" in flow["updates"][0]["error_message"]


def test_an_unexpected_error_never_leaves_the_log_queued(flow):
    with pytest.raises(RuntimeError):
        notifications.send_push_notification("t", "b", "all", None, client=FakeFcm(error=RuntimeError("boom")))
    assert flow["updates"][0]["status"] == "failed" and "boom" in flow["updates"][0]["error_message"]


def test_fcm_status_reports_a_missing_or_broken_secret(monkeypatch):
    monkeypatch.setattr(notifications.st, "secrets", {})
    client, problem = notifications.fcm_status()
    assert client is None and "FCM_SERVICE_ACCOUNT" in problem
    monkeypatch.setattr(notifications.st, "secrets", {"FCM_SERVICE_ACCOUNT": "{broken"})
    client, problem = notifications.fcm_status()
    assert client is None and "JSON" in problem


# --- which tokens each audience gets (fake Supabase) ---------------------------------


class Rows:
    def __init__(self, rows):
        self.rows, self.filters, self.ops = rows, [], []

    def select(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def eq(self, col, val):
        self.filters.append((col, val))
        return self

    def range(self, a, b):
        self.window = (a, b)
        return self

    def execute(self):
        rows = [r for r in self.rows if all(r.get(c) == v for c, v in self.filters)]
        a, b = self.window
        return type("R", (), {"data": rows[a : b + 1], "count": len(rows)})()


@pytest.fixture
def tokens_db(monkeypatch):
    rows = [
        {"token": "a", "user_id": "u1", "weekly_offers": True},
        {"token": "b", "user_id": "u1", "weekly_offers": False},
        {"token": "c", "user_id": None, "weekly_offers": True},
    ]
    client = type("C", (), {"table": lambda self, n: Rows(rows)})()
    monkeypatch.setattr(db, "get_supabase", lambda: client)
    return rows


def test_all_includes_guest_devices(tokens_db):
    assert db.fetch_push_tokens("all") == ["a", "b", "c"]


def test_weekly_offers_only_opted_in_devices(tokens_db):
    assert db.fetch_push_tokens("weekly_offer_subscribers") == ["a", "c"]


def test_single_user_only_that_customers_devices(tokens_db):
    assert db.fetch_push_tokens("single_user", "u1") == ["a", "b"]
    assert db.fetch_push_tokens("single_user", None) == []


def test_more_than_one_page_of_devices_is_all_fetched(monkeypatch):
    rows = [{"token": f"t{i}", "user_id": None, "weekly_offers": True} for i in range(2500)]
    monkeypatch.setattr(db, "get_supabase", lambda: type("C", (), {"table": lambda self, n: Rows(rows)})())
    assert len(db.fetch_push_tokens("all")) == 2500


def test_deleting_dead_tokens_is_chunked(monkeypatch):
    calls = []

    class Del:
        def delete(self):
            return self

        def in_(self, col, values):
            calls.append((col, len(values)))
            return self

        def execute(self):
            return None

    monkeypatch.setattr(db, "get_supabase", lambda: type("C", (), {"table": lambda self, n: Del()})())
    db.delete_push_tokens([f"t{i}" for i in range(250)])
    assert calls == [("token", 100), ("token", 100), ("token", 50)]


# --- the page ------------------------------------------------------------------------


@pytest.fixture
def page(monkeypatch):
    state = {"sent": [], "client": None, "problem": "لم يتم ضبط FCM_SERVICE_ACCOUNT", "result": None}
    monkeypatch.setattr(notifications, "fcm_status", lambda: (state["client"], state["problem"]))
    monkeypatch.setattr(db, "count_push_tokens", lambda user_id=None: 7)
    monkeypatch.setattr(db, "fetch_profiles", lambda: [{"id": "u1", "full_name": "سارة", "phone_number": "0791234567"}])
    monkeypatch.setattr(db, "fetch_notifications", lambda: [
        {"title": "قديم", "audience": "all", "status": "sent", "recipient_count": 5, "failed_count": 1, "error_message": "x", "created_at": "2026-11-01"}
    ])

    def send(title, body, audience, target):
        state["sent"].append((title, body, audience, target))
        return state["result"] or {"delivered": True, "recipient_count": 7, "failed_count": 0, "error": None}

    monkeypatch.setattr(notifications, "send_push_notification", send)
    return state


def run_page():
    at = AppTest.from_file(str(PAGE), default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_page_says_when_real_sending_is_not_configured(page):
    at = run_page()
    assert any("غير مفعّل" in w.value for w in at.warning)
    assert at.metric[0].value == "7"


def test_page_shows_the_connected_project(page):
    page["client"] = FakeFcm()
    at = run_page()
    assert not at.warning and any("aswaq-test" in s.value for s in at.success)


def test_page_validates_before_sending(page):
    at = run_page()
    at.button[0].click().run()
    assert page["sent"] == [] and any("العنوان والنص" in e.value for e in at.error)


def test_page_sends_and_reports_the_device_count(page):
    at = run_page()
    at.text_input[0].set_value("عرض")
    at.text_area[0].set_value("خصم 10%")
    at.button[0].click().run()
    assert page["sent"] == [("عرض", "خصم 10%", "all", None)]
    assert any("تم الإرسال إلى 7 جهاز" in s.value for s in at.success)


def test_page_reports_a_failed_send_with_its_reason(page):
    page["result"] = {"delivered": False, "recipient_count": 0, "failed_count": 0, "error": "لا توجد أجهزة"}
    at = run_page()
    at.text_input[0].set_value("عرض")
    at.text_area[0].set_value("نص")
    at.button[0].click().run()
    assert any("لا توجد أجهزة" in w.value for w in at.warning)


def test_page_history_shows_delivered_failed_and_notes(page):
    df = run_page().dataframe[0].value
    assert list(df.columns[:4]) == ["العنوان", "الجهة", "الحالة", "وصل إلى"]
    assert df.iloc[0]["وصل إلى"] == 5 and df.iloc[0]["تعذّر"] == 1 and df.iloc[0]["ملاحظات"] == "x"
