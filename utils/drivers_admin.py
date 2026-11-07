"""Driver mode, admin side (migration 019).

* The "السائقون" page: who the drivers are, whether each one is available right now (the toggle in
  their app), how many orders they are carrying, and promoting / demoting accounts.
* The assignment box on the Orders page: which driver a delivery order belongs to. The driver's app
  only lists orders whose ``driver_id`` is them, so this is how work reaches a driver.
"""

from __future__ import annotations

import re

import pandas as pd
import streamlit as st

import utils.db as db
from utils.fulfillment import order_type
from utils.insights import local_phone, to_amman


def _when(value) -> str:
    if not value:
        return "—"
    moment = to_amman([value]).iloc[0]
    return f"{moment:%Y-%m-%d %H:%M}" if pd.notna(moment) else "—"


def availability_label(driver: dict) -> str:
    return "🟢 متاح للتوصيل" if driver.get("is_available") else "🔴 غير متاح"


def _md(text: str) -> str:
    """Escape Markdown so a name typed by a driver shows as plain text."""
    return re.sub(r"([\\`*_{}\[\]()#+\-.!|<>~:])", r"\\\1", text)


def driver_name(driver: dict) -> str:
    """The Arabic name when the shop entered one (021), else the account name."""
    return (driver.get("full_name_ar") or "").strip() or (driver.get("full_name") or "").strip() or "سائق بدون اسم"


VEHICLE_TYPES = {"scooter": "🛵 سكوتر", "car": "🚗 سيارة"}


def vehicle_line(driver: dict) -> str | None:
    """'🛵 سكوتر SYM - أبيض', or None when nothing about the vehicle is known."""
    kind = VEHICLE_TYPES.get(driver.get("vehicle_type") or "")
    details = " - ".join(v.strip() for v in (driver.get("vehicle_model"), driver.get("vehicle_color")) if v and v.strip())
    if not kind and not details:
        return None
    return " ".join(p for p in (kind or "🚘", details) if p)


def sorted_drivers(drivers: list[dict]) -> list[dict]:
    """Available drivers first, then by name."""
    return sorted(drivers, key=lambda d: (not d.get("is_available"), driver_name(d)))


# ---------------------------------------------------------------------------
# Drivers page
# ---------------------------------------------------------------------------


def _render_promote() -> None:
    with st.form("promote_driver", border=True, clear_on_submit=True):
        st.subheader("إضافة سائق")
        st.caption("على السائق أن يسجّل الدخول إلى التطبيق مرة واحدة أولاً، ثم أدخل بريده هنا. يظهر له «وضع السائق» عند فتح التطبيق مجدداً.")
        email = st.text_input("البريد الإلكتروني للحساب", placeholder="driver@example.com")
        submitted = st.form_submit_button("ترقية إلى سائق", type="primary", icon=":material/person_add:")
    if not submitted:
        return
    try:
        user = db.promote_to_driver(email)
    except Exception as exc:
        st.error(db.driver_mode_error_message(exc, "تعذرت الترقية"))
        return
    st.toast(f"أصبح {user['email']} سائقاً.", icon=":material/check_circle:")
    st.rerun()


def _demote(driver_id: str) -> None:
    try:
        db.set_profile_role(driver_id, "customer")
    except Exception as exc:
        st.error(db.driver_mode_error_message(exc, "تعذر تغيير الدور"))
        return
    st.toast("أُعيد الحساب إلى عميل.", icon=":material/check_circle:")
    st.rerun()


def _render_edit(driver: dict) -> None:
    """Arabic name and vehicle details: what the customer sees on the tracking card."""
    with st.expander("✏️ تعديل الاسم والمركبة"):
        with st.form(f"edit_driver_{driver['id']}", border=False):
            name_ar = st.text_input("الاسم بالعربي", value=driver.get("full_name_ar") or "", placeholder="خالد أحمد")
            types = [None, "scooter", "car"]
            vehicle_type = st.selectbox(
                "نوع المركبة",
                options=types,
                index=types.index(driver.get("vehicle_type")) if driver.get("vehicle_type") in types else 0,
                format_func=lambda t: "— غير محدد —" if t is None else VEHICLE_TYPES[t],
            )
            model = st.text_input("الموديل", value=driver.get("vehicle_model") or "", placeholder="SYM")
            color = st.text_input("اللون", value=driver.get("vehicle_color") or "", placeholder="أبيض")
            plate = st.text_input("رقم اللوحة", value=driver.get("plate_number") or "", placeholder="12-34567")
            saved = st.form_submit_button("حفظ", type="primary", icon=":material/save:")
        if not saved:
            return
        try:
            db.update_driver_details(driver["id"], db.clean_driver_details(name_ar, vehicle_type, model, color, plate))
        except Exception as exc:
            st.error(db.DRIVER_VEHICLE_MIGRATION_HINT if db._is_missing_object(exc) else db.driver_mode_error_message(exc))
            return
        st.toast("حُفظت بيانات السائق.", icon=":material/check_circle:")
        st.rerun()


def _render_driver_card(driver: dict, active: int) -> None:
    """One driver: name, full phone, live status badge, active orders, and demotion."""
    with st.container(border=True):
        st.markdown(f"### {_md(driver_name(driver))}")
        on = bool(driver.get("is_available"))
        status = availability_label(driver) + (" · أثناء توصيل" if driver.get("paused_for_delivery") else "")
        st.badge(status, color="green" if on else "red")
        phone = local_phone(driver.get("phone_number")) if driver.get("phone_number") else "—"
        # Inline code keeps the number left-to-right and in one piece: 0798989867, never 7.9e+08.
        st.markdown(f"📞 رقم الهاتف: `{phone}`")
        vehicle = vehicle_line(driver)
        st.markdown(f"{_md(vehicle) if vehicle else '🚘 المركبة: لم تُحدَّد بعد'}")
        if driver.get("plate_number"):
            st.markdown(f"🔢 رقم اللوحة: `{driver['plate_number']}`")
        st.markdown(f"📦 الطلبات النشطة المُسندة: **{active}**")
        st.caption(f"🕒 آخر تغيير للحالة: {_when(driver.get('available_changed_at'))}")
        if (driver.get("full_name_ar") or "").strip() and (driver.get("full_name") or "").strip():
            st.caption(f"اسم الحساب: {_md(driver['full_name'].strip())}")
        _render_edit(driver)
        if st.button(
            "إلغاء رتبة سائق",
            icon=":material/person_remove:",
            key=f"demote_{driver['id']}",
            disabled=bool(active),
            help="أعد إسناد طلباته النشطة من صفحة «الطلبات» أولاً." if active else "يعود الحساب عميلاً عادياً ويختفي منه «وضع السائق».",
            width="stretch",
        ):
            _demote(driver["id"])


def render_drivers_page() -> None:
    st.caption("السائقون وحالة توفرهم لحظة بلحظة كما يحددونها من التطبيق، وعدد الطلبات التي يحملونها.")
    drivers = db.fetch_drivers()
    if drivers is None:
        st.warning(db.DRIVER_MODE_MIGRATION_HINT)
        return
    counts = db.fetch_active_driver_order_counts()
    drivers = sorted_drivers(drivers)

    if not drivers:
        st.info("لا يوجد سائقون بعد — أضف أول سائق من النموذج أدناه.")
    else:
        available = sum(1 for d in drivers if d.get("is_available"))
        a, b, c = st.columns(3)
        a.metric("السائقون", len(drivers))
        b.metric("متاحون الآن", available)
        c.metric("طلبات نشطة مُسندة", sum(counts.get(d["id"], 0) for d in drivers))
        # Cards, two per row: nothing is clipped the way table columns were.
        for start in range(0, len(drivers), 2):
            cols = st.columns(2)
            for col, d in zip(cols, drivers[start : start + 2]):
                with col:
                    _render_driver_card(d, counts.get(d["id"], 0))
        if st.button("تحديث", icon=":material/refresh:", key="drivers_refresh"):
            st.rerun()

    _render_promote()


# ---------------------------------------------------------------------------
# Orders page: assigning a delivery order to a driver
# ---------------------------------------------------------------------------


def order_driver_rows(order: dict, drivers: list[dict] | None) -> dict[str, str]:
    """The assignment/timestamp rows for the order details table ({} without migration 019)."""
    if "driver_id" not in order:
        return {}
    rows: dict[str, str] = {}
    if order_type(order) == "delivery":
        driver_id = order.get("driver_id")
        match = next((d for d in drivers or [] if d["id"] == driver_id), None)
        rows["السائق المُسند"] = driver_name(match) if match else ("سائق غير معروف" if driver_id else "غير مُسند")
        rows["وقت الاستلام من المتجر"] = _when(order.get("picked_up_at"))
    rows["وقت التسليم"] = _when(order.get("delivered_at"))
    rows["وقت الدفع"] = _when(order.get("paid_at"))
    return rows


def render_driver_assignment(order: dict, drivers: list[dict] | None, counts: dict[str, int]) -> None:
    """Driver select box + save for a delivery order."""
    if order_type(order) != "delivery":
        return
    order_id = order["id"]
    if drivers is None or "driver_id" not in order:
        st.caption(db.DRIVER_MODE_MIGRATION_HINT)
        return
    current = order.get("driver_id")
    if order.get("status") in db.ACTIVE_ORDER_EXCLUDED:
        return  # finished orders keep whoever delivered them; nothing to change

    with st.container(border=True):
        st.subheader("إسناد إلى سائق")
        ordered = sorted_drivers(drivers)
        by_id = {d["id"]: d for d in ordered}
        options: list[str | None] = [None] + list(by_id)
        if current and current not in by_id:
            options.append(current)  # assigned to someone who is no longer a driver

        def label(driver_id: str | None) -> str:
            if driver_id is None:
                return "— بدون سائق —"
            d = by_id.get(driver_id)
            if d is None:
                return "سائق غير معروف (لم يعد سائقاً)"
            busy = counts.get(driver_id, 0)
            return f"{driver_name(d)} · {availability_label(d)}" + (f" · {busy} طلب نشط" if busy else "")

        if not drivers:
            st.info("لا يوجد سائقون بعد — أضفهم من صفحة «السائقون».")
        with st.container(horizontal=True):
            choice = st.selectbox(
                "السائق", options=options, index=options.index(current), format_func=label, key=f"assign_driver_{order_id}"
            )
            if st.button("حفظ السائق", type="primary", icon=":material/local_shipping:", key=f"save_driver_{order_id}", disabled=choice == current):
                try:
                    db.assign_order_driver(order_id, choice)
                except Exception as exc:
                    st.error(db.driver_mode_error_message(exc, "تعذر إسناد السائق"))
                    return
                st.toast("تم إسناد الطلب إلى السائق." if choice else "أُلغي إسناد الطلب.", icon=":material/check_circle:")
                st.rerun()
        if choice and choice in by_id and not by_id[choice].get("is_available"):
            st.caption("هذا السائق غير متاح حالياً — سيظهر له الطلب في التطبيق لكنه قد لا يراه فوراً.")
