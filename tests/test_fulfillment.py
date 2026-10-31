"""Delivery vs pickup and scheduled times in the dashboard: labels, store settings page, orders page."""

from __future__ import annotations

from datetime import time
from pathlib import Path

import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db
from utils.fulfillment import format_clock, hours_problem, order_type, parse_clock, schedule_label, status_label

ROOT = Path(__file__).resolve().parent.parent

# --- labels -----------------------------------------------------------------------


def test_orders_without_a_type_are_deliveries():
    assert order_type({}) == "delivery"
    assert order_type({"order_type": None}) == "delivery"
    assert order_type({"order_type": "pickup"}) == "pickup"


def test_pickup_renames_the_last_two_statuses_only():
    assert status_label("out_for_delivery", "pickup") == "جاهز للاستلام"
    assert status_label("delivered", "pickup") == "تم الاستلام"
    assert status_label("preparing", "pickup") == status_label("preparing", "delivery")
    assert status_label("out_for_delivery", "delivery") == "في الطريق"


def test_schedule_label_is_amman_time():
    assert schedule_label({}) == "في أقرب وقت"
    assert schedule_label({"scheduled_time": "2026-11-01T07:00:00+00:00"}) == "2026-11-01 10:00"  # UTC+3
    assert schedule_label({"scheduled_time": "garbage"}) == "في أقرب وقت"


@pytest.mark.parametrize(
    "raw, parsed", [("08:00:00", time(8, 0)), ("23:30", time(23, 30)), ("24:00:00", time.max), (None, None), ("nope", None)]
)
def test_parse_clock(raw, parsed):
    assert parse_clock(raw) == parsed


def test_format_clock_keeps_midnight_as_24_for_closing():
    assert format_clock(time(8, 0)) == "08:00"
    assert format_clock(time.max, closing=True) == "24:00"


def test_hours_problems():
    assert hours_problem(time(8), time(23), 60) is None
    assert hours_problem(time(8), time.max, 120) is None
    assert "بعد وقت الفتح" in hours_problem(time(10), time(9), 60)
    assert "أقصر" in hours_problem(time(10), time(10, 30), 60)


# --- store settings page ----------------------------------------------------------

SETTINGS = {
    "id": True, "branch_name_ar": "أسواق الطيبات - فرع الزرقاء", "branch_address_ar": "الزرقاء", "branch_phone": None,
    "latitude": 32.073313, "longitude": 36.095312, "opens_at": "08:00:00", "closes_at": "23:00:00",
    "pickup_enabled": True, "scheduling_enabled": True, "slot_minutes": 60, "min_lead_minutes": 60,
    "max_days_ahead": 2, "pickup_ready_minutes": 20,
}
SCRIPT = "from utils.store_settings_admin import render_store_settings_page\nrender_store_settings_page()\n"


@pytest.fixture
def settings_db(monkeypatch):
    state = {"settings": dict(SETTINGS), "saved": []}
    monkeypatch.setattr(db, "fetch_store_settings", lambda: state["settings"])
    monkeypatch.setattr(db, "update_store_settings", lambda fields: state["saved"].append(fields))
    return state


def run(script=SCRIPT) -> AppTest:
    at = AppTest.from_string(script, default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_settings_page_without_the_migration_explains_why(settings_db):
    settings_db["settings"] = None
    assert any("015" in w.value for w in run().warning)


def test_settings_page_saves_what_was_entered(settings_db):
    at = run()
    # Inside a form, values only count when submitted in the same run.
    at.text_input[1].input("0791234567")  # branch phone
    at.selectbox[0].select(30)
    at.button[0].click().run()
    (saved,) = settings_db["saved"]
    assert saved["branch_phone"] == "0791234567" and saved["slot_minutes"] == 30
    assert saved["opens_at"] == "08:00" and saved["closes_at"] == "23:00"
    assert saved["latitude"] == 32.073313 and saved["pickup_enabled"] is True


def test_settings_page_midnight_close_is_saved_as_24(settings_db):
    at = run()
    at.checkbox[0].check()
    at.button[0].click().run()
    assert settings_db["saved"][0]["closes_at"] == "24:00"


def test_settings_page_shows_midnight_close_as_ticked(settings_db):
    settings_db["settings"]["closes_at"] = "24:00:00"
    assert run().checkbox[0].value is True


def test_settings_page_refuses_closing_before_opening(settings_db):
    at = run()
    at.time_input[1].set_value(time(7, 0))
    at.button[0].click().run()
    assert settings_db["saved"] == [] and any("بعد وقت الفتح" in e.value for e in at.error)


def test_settings_page_requires_a_branch_name(settings_db):
    at = run()
    at.text_input[0].input("  ")
    at.button[0].click().run()
    assert settings_db["saved"] == [] and any("مطلوبان" in e.value for e in at.error)


# --- orders page with a pickup order -------------------------------------------------

PICKUP = {
    "id": "p1", "status": "out_for_delivery", "order_type": "pickup", "scheduled_time": "2026-11-01T07:00:00+00:00",
    "total_price": 8.25, "delivery_address": None, "created_at": "2026-10-31T10:00:00+00:00", "payment_method": "cash",
    "notes": None, "customer_name": "مستلم", "customer_phone": "+962791111111", "profiles": None, "delivery_zones": None,
}
DELIVERY = {
    "id": "d1", "status": "out_for_delivery", "total_price": 9.75, "delivery_address": "شارع 1",
    "created_at": "2026-10-31T09:00:00+00:00", "payment_method": "cash", "notes": None, "customer_name": "موصل",
    "customer_phone": "+962792222222", "profiles": None, "delivery_zones": {"name_ar": "الغويرية"},
    "delivery_lat": 32.1, "delivery_lng": 36.1,
}


@pytest.fixture
def orders_db(monkeypatch):
    monkeypatch.setattr(db, "fetch_orders", lambda: [PICKUP, DELIVERY])
    monkeypatch.setattr(db, "fetch_order_items", lambda order_id: [])
    monkeypatch.setattr(db, "fetch_driver_location", lambda order_id: None)


def test_orders_table_shows_type_slot_and_pickup_status(orders_db):
    at = AppTest.from_file(str(ROOT / "app_pages/orders.py"), default_timeout=30).run()
    assert not at.exception
    table = at.dataframe[0].value
    assert list(table["النوع"]) == ["استلام من الفرع", "توصيل"]
    assert list(table["الموعد"]) == ["2026-11-01 10:00", "في أقرب وقت"]  # an old order without a type/slot
    assert list(table["الحالة"]) == ["جاهز للاستلام", "في الطريق"]


def test_orders_can_be_filtered_by_type(orders_db):
    at = AppTest.from_file(str(ROOT / "app_pages/orders.py"), default_timeout=30).run()
    at.segmented_control[1].set_value("استلام من الفرع").run()
    assert list(at.dataframe[0].value["العميل"]) == ["مستلم"]


# --- driver details (migration 016) -------------------------------------------------

from utils.fulfillment import driver_details_problem, to_e164  # noqa: E402


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("0791234567", "+962791234567"),
        ("791234567", "+962791234567"),
        ("+962 79 123 4567", "+962791234567"),
        ("00962791234567", "+962791234567"),
        ("079-123-4567", "+962791234567"),
        ("0771112222", "+962771112222"),
        ("0651234567", None),
        ("079123456", None),
        ("javascript:1", None),
        ("", None),
        (None, None),
    ],
)
def test_to_e164(raw, expected):
    assert to_e164(raw) == expected


def test_driver_details_problems():
    assert driver_details_problem("خالد أحمد", "0791234567") is None
    assert driver_details_problem("", "") is None, "both may be left blank"
    assert driver_details_problem(None, None) is None
    assert "حرفين" in driver_details_problem("خ", "")
    assert "حرفين" in driver_details_problem("x" * 61, "")
    assert "رقماً أردنياً" in driver_details_problem("خالد", "0651234567")


def test_set_driver_details_stores_e164_and_clears_blanks(monkeypatch):
    calls = []

    class Table:
        def update(self, values):
            calls.append(values)
            return self

        def eq(self, *a):
            return self

        def execute(self):
            return None

    class Client:
        def table(self, name):
            assert name == "orders"
            return Table()

    monkeypatch.setattr(db, "get_supabase", lambda: Client())
    monkeypatch.setattr(db.fetch_orders, "clear", lambda: calls.append("cache_clear"), raising=False)
    db.set_driver_details("o1", " خالد ", "079 123 4567")
    db.set_driver_details("o1", "", "")
    assert calls == [{"driver_name": "خالد", "driver_phone": "+962791234567"}, "cache_clear", {"driver_name": None, "driver_phone": None}, "cache_clear"]


DRIVER_SCRIPT = (
    "from utils.driver_panel import render_driver_panel\n"
    "render_driver_panel({'id': 'o1', 'status': 'out_for_delivery', 'order_type': 'delivery', 'delivery_lat': 32.1, 'delivery_lng': 36.1,"
    " 'driver_name': 'سالم', 'driver_phone': '+962791112233'})\n"
)


@pytest.fixture
def driver_db(monkeypatch):
    state = {"saved": [], "fail": None}
    monkeypatch.setattr(db, "fetch_driver_location", lambda order_id: None)
    monkeypatch.setattr(db, "set_driver_location", lambda *a: None)

    def save(order_id, name, phone):
        if state["fail"]:
            raise state["fail"]
        state["saved"].append((order_id, name, phone))

    monkeypatch.setattr(db, "set_driver_details", save)
    return state


def _driver_page() -> AppTest:
    at = AppTest.from_string(DRIVER_SCRIPT, default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_driver_panel_prefills_the_saved_details(driver_db):
    at = _driver_page()
    assert at.text_input(key="drv_name_o1").value == "سالم"
    assert at.text_input(key="drv_phone_o1").value == "0791112233"


def test_driver_panel_saves_what_was_typed(driver_db):
    at = _driver_page()
    at.text_input(key="drv_name_o1").input("خالد")
    at.text_input(key="drv_phone_o1").input("0781230000")
    at.run()
    at.button(key="drv_details_save_o1").click().run()
    assert driver_db["saved"] == [("o1", "خالد", "0781230000")]


def test_driver_panel_refuses_a_bad_number_without_saving(driver_db):
    at = _driver_page()
    at.text_input(key="drv_phone_o1").input("12345").run()
    at.button(key="drv_details_save_o1").click().run()
    assert driver_db["saved"] == [] and any("رقماً أردنياً" in e.value for e in at.error)


def test_driver_panel_explains_a_database_without_016(driver_db):
    driver_db["fail"] = Exception("column orders.driver_name does not exist")
    at = _driver_page()
    at.button(key="drv_details_save_o1").click().run()
    assert any("016" in e.value for e in at.error)


def test_orders_load_on_a_database_without_the_newer_columns(monkeypatch):
    """fetch_orders falls back tier by tier: 016 columns, then 015's, then the original ones."""
    seen = []

    class Q:
        def __init__(self, cols):
            self.cols = cols

        def order(self, *a, **k):
            return self

        def execute(self):
            seen.append(self.cols)
            if "driver_name" in self.cols or "order_type" in self.cols:
                raise Exception("Could not find the column in the schema cache (PGRST204): does not exist")

            class R:
                data = [{"id": "o1"}]

            return R()

    class T:
        def select(self, cols):
            return Q(cols)

    class C:
        def table(self, name):
            return T()

    monkeypatch.setattr(db, "get_supabase", lambda: C())
    rows = db.fetch_orders.__wrapped__() if hasattr(db.fetch_orders, "__wrapped__") else db.fetch_orders()
    assert rows == [{"id": "o1"}]
    assert ["driver_name" in c for c in seen] == [True, False, False] and "order_type" in seen[1] and "order_type" not in seen[2]
