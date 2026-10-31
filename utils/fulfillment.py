"""How an order is fulfilled (delivery or pickup, now or at a slot), as the dashboard shows it.

Pure helpers (no Streamlit, no database) so they can be unit-tested. Pickup orders reuse the
order statuses: "out_for_delivery" means "ready for pickup" and "delivered" means "picked up".
"""

from __future__ import annotations

from datetime import datetime, time

from utils.db import ORDER_STATUS_LABELS_AR
from utils.insights import AMMAN

ORDER_TYPE_LABELS_AR = {"delivery": "توصيل", "pickup": "استلام من الفرع"}

_PICKUP_STATUS_LABELS_AR = {
    "out_for_delivery": "جاهز للاستلام",
    "delivered": "تم الاستلام",
}


def order_type(order: dict) -> str:
    """Orders placed before migration 015 have no type: they were all deliveries."""
    return "pickup" if order.get("order_type") == "pickup" else "delivery"


def order_type_label(order: dict) -> str:
    return ORDER_TYPE_LABELS_AR[order_type(order)]


def status_label(status: str, kind: str = "delivery") -> str:
    if kind == "pickup" and status in _PICKUP_STATUS_LABELS_AR:
        return _PICKUP_STATUS_LABELS_AR[status]
    return ORDER_STATUS_LABELS_AR.get(status, status)


def _parse(value) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        moment = value
    else:
        try:
            moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None
    return moment if moment.tzinfo else moment.replace(tzinfo=AMMAN)


def schedule_label(order: dict) -> str:
    """"في أقرب وقت" for an as-soon-as-possible order, else the slot start in Amman time."""
    moment = _parse(order.get("scheduled_time"))
    if moment is None:
        return "في أقرب وقت"
    return moment.astimezone(AMMAN).strftime("%Y-%m-%d %H:%M")


def to_e164(raw: str | None) -> str | None:
    """Jordanian mobile in any common spelling ('0791234567', '791234567', '+962 79 123 4567',
    '00962...') -> '+962791234567'; None when it isn't one."""
    import re

    digits = re.sub(r"[\s\-()]", "", raw or "")
    if digits.startswith("+962"):
        digits = digits[4:]
    elif digits.startswith("00962"):
        digits = digits[5:]
    elif digits.startswith("0"):
        digits = digits[1:]
    return f"+962{digits}" if re.fullmatch(r"7[789]\d{7}", digits) else None


def driver_details_problem(name: str | None, phone: str | None) -> str | None:
    """Arabic reason the driver's name / phone can't be saved, or None (both may be blank)."""
    name = (name or "").strip()
    if name and not 2 <= len(name) <= 60:
        return "اسم السائق يجب أن يكون بين حرفين و60 حرفاً."
    if (phone or "").strip() and to_e164(phone) is None:
        return "رقم السائق يجب أن يكون رقماً أردنياً يبدأ بـ 077 أو 078 أو 079."
    return None


def parse_clock(value) -> time | None:
    """'08:00' / '08:00:00' / '24:00:00' -> time; '24:00' (midnight close) becomes 23:59:59.999999."""
    if value is None:
        return None
    if isinstance(value, time):
        return value
    text = str(value)
    if text.startswith("24:"):
        return time.max
    try:
        return time.fromisoformat(text)
    except ValueError:
        return None


def format_clock(value: time, *, closing: bool = False) -> str:
    """time -> 'HH:MM' for the database; the end of the day is stored as '24:00' for a closing time."""
    if closing and value == time.max:
        return "24:00"
    return value.strftime("%H:%M")


def hours_problem(opens: time, closes: time, slot_minutes: int) -> str | None:
    """Arabic reason the opening hours can't be saved, or None."""
    if closes <= opens:
        return "يجب أن يكون وقت الإغلاق بعد وقت الفتح في نفس اليوم."
    open_minutes = opens.hour * 60 + opens.minute
    close_minutes = 1440 if closes == time.max else closes.hour * 60 + closes.minute
    if close_minutes - open_minutes < slot_minutes:
        return "ساعات العمل أقصر من فترة موعد واحدة."
    return None
