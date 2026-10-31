"""The "إعدادات المتجر" page: the pickup branch and the delivery/pickup time-slot rules.

The customer app shows these values and place_order enforces the same ones (migration 015),
so what the shopper can pick here is exactly what the database accepts.
"""

from __future__ import annotations

from datetime import time

import streamlit as st

import utils.db as db
from utils.fulfillment import format_clock, hours_problem, parse_clock

SLOT_CHOICES = [30, 60, 90, 120]


def render_store_settings_page() -> None:
    st.caption("فرع الاستلام وساعات العمل ومواعيد التوصيل/الاستلام كما تظهر في التطبيق.")
    settings = db.fetch_store_settings()
    if settings is None:
        st.warning(db.STORE_SETTINGS_MIGRATION_HINT)
        return

    opens = parse_clock(settings.get("opens_at")) or time(8, 0)
    closes = parse_clock(settings.get("closes_at")) or time(23, 0)
    open_till_midnight = closes == time.max

    with st.form("store_settings", border=True):
        st.subheader("فرع الاستلام")
        a, b = st.columns(2)
        name = a.text_input("اسم الفرع", value=settings.get("branch_name_ar") or "")
        phone = b.text_input("هاتف الفرع (اختياري)", value=settings.get("branch_phone") or "")
        address = st.text_input("العنوان كما يظهر للعميل", value=settings.get("branch_address_ar") or "")
        c, d = st.columns(2)
        lat = c.number_input("خط العرض", value=float(settings.get("latitude") or 0), format="%.6f", min_value=-90.0, max_value=90.0)
        lng = d.number_input("خط الطول", value=float(settings.get("longitude") or 0), format="%.6f", min_value=-180.0, max_value=180.0)

        st.subheader("ساعات العمل (بتوقيت عمّان)")
        e, f, g = st.columns(3)
        new_opens = e.time_input("يفتح", value=opens, step=1800)
        new_closes = f.time_input("يغلق", value=time(23, 30) if open_till_midnight else closes, step=1800, disabled=False)
        midnight = g.checkbox("يغلق عند منتصف الليل", value=open_till_midnight)

        st.subheader("المواعيد")
        h, i, j = st.columns(3)
        slot = h.selectbox(
            "مدة الموعد (دقيقة)", SLOT_CHOICES,
            index=SLOT_CHOICES.index(settings.get("slot_minutes")) if settings.get("slot_minutes") in SLOT_CHOICES else 1,
        )
        lead = i.number_input("أقرب موعد بعد (دقيقة)", min_value=0, max_value=1440, step=15, value=int(settings.get("min_lead_minutes") or 60))
        days = j.number_input("حتى كم يوماً للأمام", min_value=0, max_value=7, step=1, value=int(settings.get("max_days_ahead") or 2))
        ready = st.number_input(
            "الطلب جاهز للاستلام خلال (دقيقة)", min_value=0, max_value=240, step=5, value=int(settings.get("pickup_ready_minutes") or 20)
        )
        k, m = st.columns(2)
        pickup = k.toggle("السماح بالاستلام من الفرع", value=bool(settings.get("pickup_enabled", True)))
        scheduling = m.toggle("السماح بجدولة موعد", value=bool(settings.get("scheduling_enabled", True)))

        saved = st.form_submit_button("حفظ الإعدادات", type="primary", icon=":material/save:")

    if not saved:
        return
    final_closes = time.max if midnight else new_closes
    problem = hours_problem(new_opens, final_closes, int(slot))
    if not name.strip() or not address.strip():
        problem = "اسم الفرع وعنوانه مطلوبان."
    if problem:
        st.error(problem)
        return
    try:
        db.update_store_settings(
            {
                "branch_name_ar": name.strip(),
                "branch_address_ar": address.strip(),
                "branch_phone": phone.strip() or None,
                "latitude": round(float(lat), 6),
                "longitude": round(float(lng), 6),
                "opens_at": format_clock(new_opens),
                "closes_at": format_clock(final_closes, closing=True),
                "slot_minutes": int(slot),
                "min_lead_minutes": int(lead),
                "max_days_ahead": int(days),
                "pickup_ready_minutes": int(ready),
                "pickup_enabled": bool(pickup),
                "scheduling_enabled": bool(scheduling),
            }
        )
    except Exception as exc:
        st.error(f"تعذر حفظ الإعدادات: {exc}")
        return
    st.toast("تم حفظ إعدادات المتجر.", icon=":material/check_circle:")
    st.rerun()
