from datetime import date, datetime, timedelta, timezone

from utils.insights import (
    AMMAN,
    day_range,
    filter_customers,
    local_phone,
    order_customer,
    pct_change,
    period_range,
    previous_range,
    sort_customers,
)

# Wednesday 2026-10-28, 15:30 in Amman — a mid-day "now" for the windows below.
NOW = datetime(2026, 10, 28, 15, 30, tzinfo=AMMAN)


def test_today_is_midnight_to_midnight_amman():
    start, end = period_range("today", NOW)
    assert start == datetime(2026, 10, 28, 0, 0, tzinfo=AMMAN)
    assert end == datetime(2026, 10, 29, 0, 0, tzinfo=AMMAN)


def test_week_is_seven_calendar_days_including_today():
    start, end = period_range("week", NOW)
    assert start.date() == date(2026, 10, 22)
    assert (end - start) == timedelta(days=7)


def test_month_is_thirty_calendar_days_including_today():
    start, end = period_range("month", NOW)
    assert start.date() == date(2026, 9, 29)
    assert (end - start) == timedelta(days=30)


def test_window_uses_amman_day_even_when_now_is_given_in_utc():
    # 22:30 UTC on the 27th is already 01:30 on the 28th in Amman (UTC+3).
    utc_now = datetime(2026, 10, 27, 22, 30, tzinfo=timezone.utc)
    start, _ = period_range("today", utc_now)
    assert start.date() == date(2026, 10, 28)


def test_custom_range_is_inclusive_and_order_insensitive():
    start, end = day_range(date(2026, 10, 5), date(2026, 10, 7))
    assert (start.date(), end.date()) == (date(2026, 10, 5), date(2026, 10, 8))
    assert day_range(date(2026, 10, 7), date(2026, 10, 5)) == (start, end)


def test_previous_range_is_the_same_length_immediately_before():
    start, end = period_range("week", NOW)
    prev_start, prev_end = previous_range(start, end)
    assert prev_end == start
    assert (prev_end - prev_start) == (end - start)


def test_unknown_period_is_an_error():
    try:
        period_range("year", NOW)
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_pct_change():
    assert pct_change(150, 100) == 50
    assert pct_change(50, 100) == -50
    assert pct_change(10, 0) is None  # nothing to compare against


def test_order_customer_prefers_the_order_snapshot_then_the_profile():
    guest = {"customer_name": "سالم", "customer_phone": "+962791234567", "profiles": None}
    assert order_customer(guest) == ("سالم", "+962791234567")

    legacy = {"customer_name": None, "customer_phone": None, "profiles": {"full_name": "Old", "phone_number": "+962771111111"}}
    assert order_customer(legacy) == ("Old", "+962771111111")

    snapshot_wins = {"customer_name": "New", "customer_phone": "+962781111111", "profiles": {"full_name": "Old", "phone_number": "+962771111111"}}
    assert order_customer(snapshot_wins) == ("New", "+962781111111")

    assert order_customer({}) == ("—", "—")


def test_local_phone():
    assert local_phone("+962791234567") == "0791234567"
    assert local_phone(None) == "—"
    assert local_phone("0791234567") == "0791234567"


CUSTOMERS = [
    {"customer_id": "1", "full_name": "سالم أحمد", "phone_number": "+962791234567", "total_spend": 40.5, "orders_count": 2, "last_order_at": "2026-10-20T10:00:00+00:00", "created_at": "2026-10-01T00:00:00+00:00"},
    {"customer_id": "2", "full_name": "Khaled", "phone_number": "+962771112222", "total_spend": 100, "orders_count": 1, "last_order_at": "2026-10-25T10:00:00+00:00", "created_at": "2026-10-02T00:00:00+00:00"},
    {"customer_id": "3", "full_name": None, "phone_number": "+962781110000", "total_spend": 0, "orders_count": 0, "last_order_at": None, "created_at": "2026-10-03T00:00:00+00:00"},
]


def ids(rows):
    return [c["customer_id"] for c in rows]


def test_filter_by_name_and_by_phone_in_any_format():
    assert ids(filter_customers(CUSTOMERS, "khal")) == ["2"]
    assert ids(filter_customers(CUSTOMERS, "سالم")) == ["1"]
    for query in ("0791234567", "791234567", "+962 79 123 4567", "079-123-4567"):
        assert ids(filter_customers(CUSTOMERS, query)) == ["1"], query
    assert filter_customers(CUSTOMERS, "  ") == CUSTOMERS
    assert filter_customers(CUSTOMERS, "zzz") == []


def test_filter_ignores_one_or_two_stray_digits():
    assert filter_customers(CUSTOMERS, "7") == []  # would otherwise match everyone


def test_sort_numeric_descending():
    assert ids(sort_customers(CUSTOMERS, "total_spend")) == ["2", "1", "3"]
    assert ids(sort_customers(CUSTOMERS, "orders_count")) == ["1", "2", "3"]


def test_sort_by_time_newest_first_with_never_ordered_last():
    assert ids(sort_customers(CUSTOMERS, "last_order_at")) == ["2", "1", "3"]
    assert ids(sort_customers(CUSTOMERS, "created_at")) == ["3", "2", "1"]


def test_to_amman_converts_utc_and_tolerates_missing_values():
    from utils.insights import to_amman

    out = to_amman(["2026-10-27T09:00:00+00:00", None, "not a date"])
    assert out[0].hour == 12 and out[0].utcoffset() == timedelta(hours=3)  # 09:00 UTC = 12:00 in Amman
    assert out[1] != out[1] and out[2] != out[2]  # NaT never equals itself
