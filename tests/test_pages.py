"""Run the dashboard pages headlessly with fake data — no Supabase, no secrets.

Page scripts import their data functions from ``utils.db`` at run time, so
swapping those attributes is enough to feed them canned rows."""

from __future__ import annotations

from pathlib import Path

import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db

ROOT = Path(__file__).resolve().parent.parent

INSIGHTS = {"orders_count": 12, "total_sales": 345.5, "avg_order_value": 28.792, "cancelled_count": 2, "unique_customers": 9}
PREVIOUS = {"orders_count": 8, "total_sales": 230.0, "avg_order_value": 28.75, "cancelled_count": 1, "unique_customers": 6}

PRODUCTS = [
    {"product_id": "p1", "name_ar": "حليب", "name": "Milk", "sku": "111", "units_sold": 40, "revenue": 100.0, "orders_count": 20},
    {"product_id": "p2", "name_ar": None, "name": "Cheese", "sku": None, "units_sold": 25, "revenue": 81.25, "orders_count": 11},
]
ZONES = [
    {"zone_id": "z1", "zone_name_ar": "الغويرية", "orders_count": 7, "sales": 200.0},
    {"zone_id": None, "zone_name_ar": None, "orders_count": 1, "sales": 9.5},
]
DAILY = [{"day": "2026-10-26", "orders_count": 5, "sales": 120.0}, {"day": "2026-10-27", "orders_count": 7, "sales": 225.5}]

CUSTOMERS = [
    {"customer_id": "c1", "full_name": "سالم أحمد", "phone_number": "+962791234567", "has_google_account": True, "created_at": "2026-10-01T00:00:00+00:00",
     "orders_count": 2, "cancelled_count": 0, "total_spend": 40.5, "first_order_at": "2026-10-02T00:00:00+00:00", "last_order_at": "2026-10-20T00:00:00+00:00"},
    {"customer_id": "c2", "full_name": "Khaled", "phone_number": "+962771112222", "has_google_account": False, "created_at": "2026-10-02T00:00:00+00:00",
     "orders_count": 1, "cancelled_count": 1, "total_spend": 100, "first_order_at": "2026-10-03T00:00:00+00:00", "last_order_at": "2026-10-25T00:00:00+00:00"},
]
ORDERS = [{"id": "o1", "status": "delivered", "subtotal": 9.0, "delivery_fee": 1.5, "total_price": 10.5, "delivery_address": "شارع الجيش",
           "payment_method": "cash", "notes": None, "created_at": "2026-10-20T00:00:00+00:00", "customer_name": "سالم أحمد",
           "customer_phone": "+962791234567", "delivery_zones": {"name_ar": "الغويرية"}}]


@pytest.fixture
def fake_db(monkeypatch):
    calls: dict[str, list] = {}

    def record(name, value):
        def fn(*args, **kwargs):
            calls.setdefault(name, []).append(args)
            return value(*args) if callable(value) else value
        monkeypatch.setattr(db, name, fn)

    record("fetch_order_insights", lambda start, end: INSIGHTS if "T" in start and len(calls["fetch_order_insights"]) % 2 == 1 else PREVIOUS)
    record("fetch_top_products", PRODUCTS)
    record("fetch_top_zones", ZONES)
    record("fetch_sales_by_day", DAILY)
    record("fetch_customer_stats", CUSTOMERS)
    record("fetch_customer_orders", ORDERS)
    record("fetch_order_items", [])
    record("fetch_orders", [
        {"id": "o1", "status": "pending", "total_price": 10.5, "delivery_address": "x", "created_at": "2026-10-20", "payment_method": "cash", "notes": None,
         "customer_name": "ضيف", "customer_phone": "+962791234567", "profiles": None, "delivery_zones": {"name_ar": "الغويرية"}},
        {"id": "o2", "status": "delivered", "total_price": 5, "delivery_address": "y", "created_at": "2026-10-19", "payment_method": "cash", "notes": None,
         "customer_name": None, "customer_phone": None, "profiles": {"full_name": "قديم", "phone_number": "+962771111111"}, "delivery_zones": None},
    ])
    return calls


def run(page: str) -> AppTest:
    at = AppTest.from_file(str(ROOT / page), default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_analytics_shows_metrics_tables_and_charts(fake_db):
    at = run("app_pages/analytics.py")
    labels = {m.label: m.value for m in at.metric}
    assert labels["إجمالي المبيعات (د.أ)"] == "345.500"
    assert labels["عدد الطلبات"] == "12"
    assert labels["متوسط قيمة الطلب (د.أ)"] == "28.792"
    assert labels["الطلبات الملغاة"] == "2"
    assert len(at.dataframe) == 2  # top products + top zones
    products_df = at.dataframe[0].value
    assert list(products_df["المنتج"]) == ["حليب", "Cheese"]  # falls back to the English name
    zones_df = at.dataframe[1].value
    assert "غير محددة" in list(zones_df["المنطقة"])  # orders with no zone
    assert not at.error


def test_analytics_default_period_is_a_week_and_compares_to_the_previous_one(fake_db):
    run("app_pages/analytics.py")
    # one call for the window, one for the window before it
    assert len(fake_db["fetch_order_insights"]) == 2
    (start, end), (prev_start, prev_end) = [c[:2] for c in fake_db["fetch_order_insights"]]
    assert prev_end == start


def test_analytics_period_buttons_change_the_window(fake_db):
    at = run("app_pages/analytics.py")
    week_start = fake_db["fetch_top_products"][-1][0]
    at.session_state["analytics_period"] = "اليوم"
    at.run()
    assert not at.exception
    today_start = fake_db["fetch_top_products"][-1][0]
    assert today_start > week_start  # "today" starts later than "last 7 days" (both ISO, same +03:00 offset)


def test_analytics_with_no_data_shows_empty_states(fake_db, monkeypatch):
    monkeypatch.setattr(db, "fetch_top_products", lambda *a: [])
    monkeypatch.setattr(db, "fetch_top_zones", lambda *a: [])
    monkeypatch.setattr(db, "fetch_sales_by_day", lambda *a: [])
    at = run("app_pages/analytics.py")
    infos = [i.value for i in at.info]
    assert any("لا توجد مبيعات" in i for i in infos)
    assert any("لا توجد منتجات" in i for i in infos)
    assert any("لا توجد طلبات" in i for i in infos)


def test_analytics_stops_quietly_when_the_migration_is_missing(fake_db, monkeypatch):
    monkeypatch.setattr(db, "fetch_order_insights", lambda *a: {})
    at = run("app_pages/analytics.py")
    assert len(at.metric) == 0  # nothing rendered below the period picker


def test_customers_lists_everyone_sorted_by_spend(fake_db):
    at = run("app_pages/customers.py")
    table = at.dataframe[0].value
    assert list(table["الاسم"]) == ["Khaled", "سالم أحمد"]  # 100 then 40.5
    assert list(table["الهاتف"]) == ["0771112222", "0791234567"]  # shown the way customers write it
    labels = {m.label: m.value for m in at.metric}
    assert labels["عدد العملاء"] == "2"
    assert labels["إجمالي إنفاق العملاء (د.أ)"] == "140.500"
    assert labels["عملاء لديهم حساب Google"] == "1"


def test_customers_search_by_phone_in_local_format(fake_db):
    at = run("app_pages/customers.py")
    at.text_input(key="customer_search").set_value("0791234567").run()
    assert not at.exception
    assert list(at.dataframe[0].value["الاسم"]) == ["سالم أحمد"]


def test_customers_search_with_no_match(fake_db):
    at = run("app_pages/customers.py")
    at.text_input(key="customer_search").set_value("nobody").run()
    assert any("لا يوجد عملاء مطابقون" in i.value for i in at.info)


def test_customers_empty_state(fake_db, monkeypatch):
    monkeypatch.setattr(db, "fetch_customer_stats", lambda: [])
    at = run("app_pages/customers.py")
    assert any("لا يوجد عملاء بعد" in i.value for i in at.info)


def test_orders_page_shows_guest_and_profile_customers(fake_db):
    at = run("app_pages/orders.py")
    table = at.dataframe[0].value
    assert list(table["العميل"]) == ["ضيف", "قديم"]  # guest snapshot, then the legacy profile
    assert list(table["الهاتف"]) == ["0791234567", "0771111111"]
    assert list(table["المنطقة"]) == ["الغويرية", "—"]
