"""The driver panel, run headlessly with a fake database."""

from __future__ import annotations

import pytest
from streamlit.testing.v1 import AppTest

import utils.db as db
from utils.store import STORE_LAT, STORE_LNG, step_toward

PIN = (32.1500, 36.2000)
SCRIPT = """
from utils.driver_panel import render_driver_panel
render_driver_panel({"id": "order-1", "status": "out_for_delivery", "delivery_lat": %s, "delivery_lng": %s})
"""


@pytest.fixture
def fake(monkeypatch):
    state = {"driver": None, "sent": [], "fail": None}

    monkeypatch.setattr(db, "fetch_driver_location", lambda order_id: state["driver"])

    def send(order_id, latitude, longitude):
        if state["fail"]:
            raise state["fail"]
        state["sent"].append((order_id, latitude, longitude))
        state["driver"] = {"latitude": latitude, "longitude": longitude, "updated_at": "2026-10-27T09:00:00+00:00"}

    monkeypatch.setattr(db, "set_driver_location", send)
    return state


def run(pin=PIN) -> AppTest:
    lat, lng = (pin if pin else (None, None))
    at = AppTest.from_string(SCRIPT % (lat, lng), default_timeout=30).run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def click(at: AppTest, label: str) -> AppTest:
    button = next(b for b in at.button if b.label == label)
    button.click().run()
    assert not at.exception, [e.value for e in at.exception]
    return at


def test_before_any_location_it_says_so_and_offers_the_store_as_the_start(fake):
    at = run()
    assert any("لم يُرسَل موقع" in i.value for i in at.info)
    assert at.number_input[0].value == pytest.approx(STORE_LAT)
    assert at.number_input[1].value == pytest.approx(STORE_LNG)


def test_shows_the_customer_pin_and_the_distance_left(fake):
    at = run()
    text = " ".join(m.value for m in at.markdown)
    assert "32.150000, 36.200000" in text
    assert "المسافة المتبقية" in text


def test_move_toward_customer_sends_the_next_point_along_the_way(fake):
    click(run(), "تحريك السائق نحو العميل")
    expected = step_toward((STORE_LAT, STORE_LNG), PIN)
    assert fake["sent"] == [("order-1", expected[0], expected[1])]


def test_each_click_starts_from_where_the_driver_now_is(fake):
    at = run()
    for _ in range(3):
        at = click(at, "تحريك السائق نحو العميل")
    expected, point = [], (STORE_LAT, STORE_LNG)
    for _ in range(3):
        point = step_toward(point, PIN)
        expected.append(("order-1", point[0], point[1]))
    assert fake["sent"] == expected


def test_arrive_sends_exactly_the_customers_pin(fake):
    click(run(), "وصل إلى العميل")
    assert fake["sent"] == [("order-1", PIN[0], PIN[1])]


def test_store_button_sends_the_store(fake):
    click(run(), "موقع المتجر")
    assert fake["sent"] == [("order-1", STORE_LAT, STORE_LNG)]


def test_manual_coordinates_are_sent_as_typed(fake):
    at = run()
    at.number_input[0].set_value(32.111111)
    at.number_input[1].set_value(36.222222)
    at.run()
    click(at, "إرسال هذا الموقع")
    assert fake["sent"] == [("order-1", pytest.approx(32.111111), pytest.approx(36.222222))]


def test_inputs_start_from_the_drivers_current_position(fake):
    fake["driver"] = {"latitude": 32.12, "longitude": 36.15, "updated_at": "2026-10-27T09:00:00+00:00"}
    at = run()
    assert at.number_input[0].value == pytest.approx(32.12)
    assert at.number_input[1].value == pytest.approx(36.15)
    assert any("آخر موقع مُرسَل" in m.value for m in at.markdown)


def test_without_a_customer_pin_there_is_no_route_to_simulate(fake):
    at = run(pin=None)
    labels = {b.label for b in at.button}
    assert "تحريك السائق نحو العميل" not in labels and "وصل إلى العميل" not in labels
    assert {"موقع المتجر", "إرسال هذا الموقع"} <= labels
    assert any("لم يحدد العميل موقعه" in w.value for w in at.warning)


def test_a_database_refusal_is_explained_in_arabic(fake):
    fake["fail"] = Exception("{'code': 'P0001', 'message': 'not_out_for_delivery'}")
    at = click(run(), "موقع المتجر")
    assert any("خرج للتوصيل" in e.value for e in at.error)
    assert fake["sent"] == []


def test_error_messages():
    assert "خرج للتوصيل" in db.driver_error_message(Exception("not_out_for_delivery"))
    assert "إحداثيات غير صحيحة" in db.driver_error_message(Exception("invalid_location"))
    assert "010_driver_tracking" in db.driver_error_message(Exception("Could not find the function public.set_driver_location (PGRST202)"))
    assert "boom" in db.driver_error_message(Exception("boom"))
