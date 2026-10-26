"""Pure helpers for the analytics / customers pages (no Streamlit, no DB).

Kept separate from ``utils.db`` so the date windows and display rules can be
unit-tested without a database or a running dashboard.
"""

from __future__ import annotations

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

AMMAN = ZoneInfo("Asia/Amman")

# Quick periods offered on the analytics page. "week" and "month" are rolling
# windows that end today (7 / 30 calendar days including today), not calendar
# weeks/months — "the last week" is what a shop owner actually wants to compare.
PERIOD_LABELS_AR: dict[str, str] = {
    "today": "اليوم",
    "week": "آخر 7 أيام",
    "month": "آخر 30 يوماً",
    "custom": "فترة مخصصة",
}
_PERIOD_DAYS = {"today": 1, "week": 7, "month": 30}


def day_range(first_day: date, last_day: date) -> tuple[datetime, datetime]:
    """``[start, end)`` in Amman time covering ``first_day`` through
    ``last_day`` inclusive (whole days, midnight to midnight)."""
    if last_day < first_day:
        first_day, last_day = last_day, first_day
    start = datetime.combine(first_day, time.min, tzinfo=AMMAN)
    end = datetime.combine(last_day + timedelta(days=1), time.min, tzinfo=AMMAN)
    return start, end


def period_range(period: str, now: datetime | None = None) -> tuple[datetime, datetime]:
    """``[start, end)`` for a quick period, ending with today (Amman time)."""
    if period not in _PERIOD_DAYS:
        raise ValueError(f"unknown period: {period!r}")
    today = (now or datetime.now(AMMAN)).astimezone(AMMAN).date()
    return day_range(today - timedelta(days=_PERIOD_DAYS[period] - 1), today)


def previous_range(start: datetime, end: datetime) -> tuple[datetime, datetime]:
    """The window of the same length immediately before ``[start, end)`` —
    for "vs the previous period" comparisons."""
    return start - (end - start), start


def pct_change(current: float, previous: float) -> float | None:
    """Percentage change from ``previous`` to ``current``; ``None`` when there
    is no previous value to compare against (avoids a meaningless "+inf%")."""
    if not previous:
        return None
    return (current - previous) / previous * 100


def order_customer(order: dict) -> tuple[str, str]:
    """(name, phone) to show for an order. Prefers the snapshot taken when the
    order was placed (guest orders have only that), then the signed-in
    profile, then a dash."""
    profile = order.get("profiles") or {}
    name = order.get("customer_name") or profile.get("full_name") or "—"
    phone = order.get("customer_phone") or profile.get("phone_number") or "—"
    return name, phone


def local_phone(e164: str | None) -> str:
    """``+962791234567`` -> ``0791234567`` (the way customers write it)."""
    if not e164:
        return "—"
    return "0" + e164[4:] if e164.startswith("+962") else e164


def filter_customers(customers: list[dict], query: str) -> list[dict]:
    """Customers whose name contains ``query`` or whose phone matches it.

    Phones compare on their last 9 digits, so ``0791234567``, ``791234567`` and
    ``+962 79 123 4567`` all find ``+962791234567``."""
    needle = query.strip().lower()
    if not needle:
        return customers
    digits = "".join(ch for ch in needle if ch.isdigit())
    matches = []
    for customer in customers:
        if needle in (customer.get("full_name") or "").lower():
            matches.append(customer)
        elif len(digits) >= 3 and digits[-9:] in (customer.get("phone_number") or "").replace("+", ""):
            matches.append(customer)
    return matches


def sort_customers(customers: list[dict], field: str) -> list[dict]:
    """Largest/newest first by ``field``; customers with no value (e.g. no
    ``last_order_at`` yet) go last. ISO timestamps sort correctly as text."""
    with_value = [c for c in customers if c.get(field) is not None]
    without = [c for c in customers if c.get(field) is None]
    key = (lambda c: float(c[field])) if field in ("total_spend", "orders_count", "cancelled_count") else (lambda c: str(c[field]))
    return sorted(with_value, key=key, reverse=True) + without


def to_amman(values):
    """Series of ISO timestamps (UTC, as Supabase returns them) -> tz-aware
    Amman-time datetimes for display; unparseable/missing become ``NaT``."""
    import pandas as pd  # local import: keeps the rest of this module pandas-free

    return pd.to_datetime(pd.Series(list(values), dtype="object"), utc=True, errors="coerce").dt.tz_convert(AMMAN)
