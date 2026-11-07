"""Driver mode, admin side (migration 019): the drivers page, assigning orders, the loyalty rate."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db

ROOT = Path(__file__).resolve().parent.parent
MISSING = Exception("{'code': '42703', 'message': 'column profiles.role does not exist'}")

SALEM = {"id": "drv-1", "full_name": "سالم", "phone_number": "+962791112233", "role": "driver", "is_available": False,
         "paused_for_delivery": False, "available_changed_at": "2026-11-07T06:00:00+00:00"}
KHALED = {"id": "drv-2", "full_name": "خالد", "phone_number": None, "role": "driver", "is_available": True,
          "paused_for_delivery": False, "available_changed_at": "2026-11-07T07:30:00+00:00"}


def _run(at: AppTest) -> AppTest:
    at.run()
    assert not at.exception, [e.value for e in at.exception]
    return at


# --- drivers page -----------------------------------------------------------------


@pytest.fixture
def drivers_db(monkeypatch):
    state = {"drivers": [SALEM, KHALED], "counts": {"drv-1": 2}, "promoted": [], "roles": [], "fail": None}
    monkeypatch.setattr(db, "fetch_drivers", lambda: state["drivers"])
    monkeypatch.setattr(db, "fetch_active_driver_order_counts", lambda: state["counts"])

    def promote(email):
        if state["fail"]:
            raise state["fail"]
        state["promoted"].append(email)
        return {"id": "u1", "email": email}

    def set_role(profile_id, role):
        if state["fail"]:
            raise state["fail"]
        state["roles"].append((profile_id, role))

    monkeypatch.setattr(db, "promote_to_driver", promote)
    monkeypatch.setattr(db, "set_profile_role", set_role)
    return state


def drivers_page() -> AppTest:
    return _run(AppTest.from_file(str(ROOT / "app_pages/drivers.py"), default_timeout=30))


def test_drivers_page_without_019_explains_why(drivers_db):
    drivers_db["drivers"] = None
    at = drivers_page()
    assert any("019" in w.value for w in at.warning)
    assert not at.text_input  # nothing to promote into


def test_drivers_page_lists_available_first_with_active_orders(drivers_db):
    at = drivers_page()
    table = at.dataframe[0].value
    assert list(table["الاسم"]) == ["خالد", "سالم"]
    assert list(table["الحالة"]) == ["🟢 متاح", "🔴 غير متاح"]
    assert list(table["طلبات نشطة"]) == [0, 2]
    assert list(table["الهاتف"]) == ["—", "0791112233"]
    assert str(table["الهاتف"].dtype) == "string", "phones stay text (leading 0, no scientific notation)"
    assert list(table["منذ"]) == ["2026-11-07 10:30", "2026-11-07 09:00"]  # Amman time
    metrics = {m.label: m.value for m in at.metric}
    assert metrics == {"السائقون": "2", "متاحون الآن": "1", "طلبات نشطة مُسندة": "2"}


def test_drivers_page_with_no_drivers_still_offers_promotion(drivers_db):
    drivers_db["drivers"] = []
    at = drivers_page()
    assert any("لا يوجد سائقون" in i.value for i in at.info)
    assert len(at.text_input) == 1 and not at.selectbox


def test_promote_by_email(drivers_db):
    at = drivers_page()
    at.text_input[0].input("driver@example.com")
    at.button[1].click()  # form submit (button[0] is refresh)
    _run(at)
    assert drivers_db["promoted"] == ["driver@example.com"]


def test_promote_unknown_email_is_explained_in_arabic(drivers_db):
    drivers_db["fail"] = ValueError("user_not_found")
    at = drivers_page()
    at.text_input[0].input("nobody@example.com")
    at.button[1].click()
    _run(at)
    assert any("لا يوجد حساب بهذا البريد" in e.value for e in at.error)


def test_demote_is_blocked_while_the_driver_has_active_orders(drivers_db):
    at = drivers_page()
    at.selectbox(key="demote_driver_select").select("drv-1")
    _run(at)
    assert at.button(key="demote_driver").disabled
    assert any("طلب نشط" in w.value for w in at.warning)


def test_demote_an_idle_driver(drivers_db):
    at = drivers_page()
    assert at.selectbox(key="demote_driver_select").value == "drv-2"  # available first
    at.button(key="demote_driver").click()
    _run(at)
    assert drivers_db["roles"] == [("drv-2", "customer")]


# --- db helpers ---------------------------------------------------------------------


class FakeQuery:
    def __init__(self, log, result=None, fail=None):
        self.log, self.result, self.fail = log, result, fail

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.log.append((name, args))
            return self

        return call

    @property
    def not_(self):
        self.log.append(("not_", ()))
        return self

    def execute(self):
        if self.fail:
            raise self.fail
        return SimpleNamespace(data=self.result, count=None)


def test_find_auth_user_pages_through_users_case_insensitively(monkeypatch):
    pages = {1: [SimpleNamespace(id=f"x{i}", email=f"u{i}@x.com") for i in range(200)],
             2: [SimpleNamespace(id="target", email="Driver@Example.com")]}
    asked = []

    def list_users(page=None, per_page=None):
        asked.append(page)
        return pages.get(page, [])

    client = SimpleNamespace(auth=SimpleNamespace(admin=SimpleNamespace(list_users=list_users)))
    monkeypatch.setattr(db, "get_supabase", lambda: client)
    assert db.find_auth_user_by_email(" driver@example.COM ") == {"id": "target", "email": "Driver@Example.com"}
    assert asked == [1, 2]
    assert db.find_auth_user_by_email("missing@x.com") is None
    with pytest.raises(ValueError, match="invalid_email"):
        db.find_auth_user_by_email("not-an-email")


def test_set_profile_role_reports_a_missing_profile(monkeypatch):
    log = []
    monkeypatch.setattr(db, "get_supabase", lambda: SimpleNamespace(table=lambda name: FakeQuery(log, result=[])))
    with pytest.raises(ValueError, match="profile_not_found"):
        db.set_profile_role("nobody", "driver")
    assert log[0] == ("update", ({"role": "driver"},))


def test_demoting_switches_availability_off(monkeypatch):
    log = []
    monkeypatch.setattr(db, "get_supabase", lambda: SimpleNamespace(table=lambda name: FakeQuery(log, result=[{"id": "d"}])))
    db.set_profile_role("d", "customer")
    fields = log[0][1][0]
    assert fields["role"] == "customer" and fields["is_available"] is False and fields["paused_for_delivery"] is False


def test_fetch_drivers_is_none_without_019(monkeypatch):
    monkeypatch.setattr(db, "get_supabase", lambda: SimpleNamespace(table=lambda name: FakeQuery([], fail=MISSING)))
    assert db.fetch_drivers() is None
    assert db.fetch_active_driver_order_counts() == {}


def test_active_order_counts_group_by_driver(monkeypatch):
    log = []
    rows = [{"id": "o1", "driver_id": "a"}, {"id": "o2", "driver_id": "a"}, {"id": "o3", "driver_id": "b"}]
    monkeypatch.setattr(db, "get_supabase", lambda: SimpleNamespace(table=lambda name: FakeQuery(log, result=rows)))
    assert db.fetch_active_driver_order_counts() == {"a": 2, "b": 1}
    assert ("in_", ("status", ["delivered", "cancelled"])) in log


@pytest.mark.parametrize(
    "error, expected",
    [
        (Exception("{'message': 'not_a_driver', 'code': 'P0001'}"), "ليس سائقاً"),
        (MISSING, "019"),
        (Exception("Could not find the 'driver_id' column of 'orders' in the schema cache (PGRST204)"), "019"),
        (Exception("boom"), "تعذر الحفظ: boom"),
    ],
)
def test_driver_mode_error_messages(error, expected):
    assert expected in db.driver_mode_error_message(error)


# --- orders page --------------------------------------------------------------------

ORDER = {
    "id": "o1", "status": "confirmed", "order_type": "delivery", "total_price": 9.75, "delivery_address": "شارع 1",
    "created_at": "2026-11-07T06:00:00+00:00", "payment_method": "cash", "notes": None, "customer_name": "زبون",
    "customer_phone": "+962792222222", "profiles": None, "delivery_zones": {"name_ar": "الغويرية"},
    "driver_id": None, "picked_up_at": None, "delivered_at": None, "paid_at": None,
}
PICKUP = {**ORDER, "id": "p1", "order_type": "pickup", "customer_name": "مستلم"}
DONE = {**ORDER, "id": "o9", "status": "delivered", "driver_id": "drv-1", "customer_name": "قديم",
        "picked_up_at": "2026-11-07T07:00:00+00:00", "delivered_at": "2026-11-07T07:20:00+00:00", "paid_at": "2026-11-07T07:20:00+00:00"}


@pytest.fixture
def orders_db(monkeypatch):
    state = {"orders": [dict(ORDER), PICKUP, DONE], "drivers": [SALEM, KHALED], "assigned": [], "fail": None}
    monkeypatch.setattr(db, "fetch_orders", lambda: state["orders"])
    monkeypatch.setattr(db, "fetch_order_items", lambda order_id: [])
    monkeypatch.setattr(db, "fetch_driver_location", lambda order_id: None)
    monkeypatch.setattr(db, "fetch_drivers", lambda: state["drivers"])
    monkeypatch.setattr(db, "fetch_active_driver_order_counts", lambda: {"drv-1": 1})

    def assign(order_id, driver_id):
        if state["fail"]:
            raise state["fail"]
        state["assigned"].append((order_id, driver_id))

    monkeypatch.setattr(db, "assign_order_driver", assign)
    return state


def orders_page() -> AppTest:
    return _run(AppTest.from_file(str(ROOT / "app_pages/orders.py"), default_timeout=30))


def _select(at: AppTest, row: int) -> AppTest:
    """Run with a table row selected. AppTest doesn't keep a dataframe selection between runs, so every
    run in these tests goes through here."""
    at.session_state["orders_table"] = {"selection": {"rows": [row], "columns": [], "cells": []}}
    return _run(at)


def test_orders_table_shows_the_driver_column(orders_db):
    at = orders_page()
    assert list(at.dataframe[0].value["السائق"]) == ["غير مُسند", "—", "سالم"]


def test_assign_a_driver_lists_available_first(orders_db):
    at = _select(orders_page(), 0)
    box = at.selectbox(key="assign_driver_o1")
    assert box.options[:3] == ["— بدون سائق —", "خالد · 🟢 متاح", "سالم · 🔴 غير متاح · 1 طلب نشط"]
    box.select("drv-2")
    _select(at, 0)
    at.button(key="save_driver_o1").click()
    _select(at, 0)
    assert orders_db["assigned"] == [("o1", "drv-2")]


def test_assigning_a_non_driver_is_explained_in_arabic(orders_db):
    orders_db["fail"] = Exception("{'message': 'not_a_driver', 'code': 'P0001'}")
    at = _select(orders_page(), 0)
    at.selectbox(key="assign_driver_o1").select("drv-1")
    _select(at, 0)
    at.button(key="save_driver_o1").click()
    _select(at, 0)
    assert orders_db["assigned"] == [] and any("ليس سائقاً" in e.value for e in at.error)


def test_pickup_orders_have_no_driver_box(orders_db):
    at = _select(orders_page(), 1)
    assert not [s for s in at.selectbox if s.key == "assign_driver_p1"]


def test_delivered_order_shows_driver_and_times(orders_db):
    at = _select(orders_page(), 2)
    assert not [s for s in at.selectbox if s.key == "assign_driver_o9"]
    details = at.table[0].value
    text = details.to_string()
    assert "سالم" in text and "2026-11-07 10:20" in text and "2026-11-07 10:00" in text


def test_orders_page_without_019_never_asks_for_drivers(orders_db, monkeypatch):
    def boom():
        raise AssertionError("fetch_drivers must not run without 019")

    monkeypatch.setattr(db, "fetch_drivers", boom)
    orders_db["orders"] = [{k: v for k, v in ORDER.items() if k not in ("driver_id", "picked_up_at", "delivered_at", "paid_at")}]
    at = _select(orders_page(), 0)
    assert "السائق" not in at.dataframe[0].value.columns
    assert any("019" in c.value for c in at.caption)


# --- store settings: loyalty rate ------------------------------------------------------

SETTINGS = {
    "id": True, "branch_name_ar": "فرع الزرقاء", "branch_address_ar": "الزرقاء", "branch_phone": None,
    "latitude": 32.07, "longitude": 36.09, "opens_at": "08:00:00", "closes_at": "23:00:00",
    "pickup_enabled": True, "scheduling_enabled": True, "slot_minutes": 60, "min_lead_minutes": 60,
    "max_days_ahead": 2, "pickup_ready_minutes": 20,
}
SETTINGS_SCRIPT = "from utils.store_settings_admin import render_store_settings_page\nrender_store_settings_page()\n"


@pytest.fixture
def settings_db(monkeypatch):
    state = {"settings": {**SETTINGS, "points_per_jod": 1}, "saved": []}
    monkeypatch.setattr(db, "fetch_store_settings", lambda: state["settings"])
    monkeypatch.setattr(db, "update_store_settings", lambda fields: state["saved"].append(fields))
    return state


def test_points_rate_is_saved(settings_db):
    at = _run(AppTest.from_string(SETTINGS_SCRIPT, default_timeout=30))
    rate = next(n for n in at.number_input if "نقاط" in n.label)
    assert rate.value == 1.0
    rate.set_value(2.5)
    at.button[0].click()  # inside the form: the value only counts in the submit run
    _run(at)
    assert settings_db["saved"][0]["points_per_jod"] == 2.5


def test_points_rate_is_hidden_and_not_saved_without_019(settings_db):
    settings_db["settings"] = dict(SETTINGS)
    at = _run(AppTest.from_string(SETTINGS_SCRIPT, default_timeout=30))
    assert not [n for n in at.number_input if "نقاط" in n.label]
    at.button[0].click()
    _run(at)
    assert "points_per_jod" not in settings_db["saved"][0]
