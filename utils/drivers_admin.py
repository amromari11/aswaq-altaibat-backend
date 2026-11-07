"""Driver mode, admin side (migration 019).

* The "السائقون" page: who the drivers are, whether each one is available right now (the toggle in
  their app), how many orders they are carrying, and promoting / demoting accounts.
* The assignment box on the Orders page: which driver a delivery order belongs to. The driver's app
  only lists orders whose ``driver_id`` is them, so this is how work reaches a driver.
"""

from __future__ import annotations

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
    return "متاح" if driver.get("is_available") else "غير متاح"


def driver_name(driver: dict) -> str:
    return (driver.get("full_name") or "").strip() or "سائق بدون اسم"


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


def _render_demote(drivers: list[dict], counts: dict[str, int]) -> None:
    with st.container(border=True):
        st.subheader("إعادة سائق إلى عميل")
        driver_id = st.selectbox(
            "السائق",
            options=[d["id"] for d in drivers],
            format_func=lambda i: driver_name(next(d for d in drivers if d["id"] == i)),
            key="demote_driver_select",
        )
        active = counts.get(driver_id, 0)
        if active:
            st.warning(f"لدى هذا السائق {active} طلب نشط — أعد إسناد طلباته من صفحة «الطلبات» قبل إلغاء دوره.")
        if st.button("إعادة إلى عميل", icon=":material/person_remove:", disabled=bool(active), key="demote_driver"):
            try:
                db.set_profile_role(driver_id, "customer")
            except Exception as exc:
                st.error(db.driver_mode_error_message(exc, "تعذر تغيير الدور"))
                return
            st.toast("أُعيد الحساب إلى عميل.", icon=":material/check_circle:")
            st.rerun()


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
        table = pd.DataFrame(
            [
                {
                    "الاسم": driver_name(d),
                    "الهاتف": local_phone(d.get("phone_number")) if d.get("phone_number") else "—",
                    "الحالة": availability_label(d) + (" (أثناء توصيل)" if d.get("paused_for_delivery") else ""),
                    "منذ": _when(d.get("available_changed_at")),
                    "طلبات نشطة": counts.get(d["id"], 0),
                }
                for d in drivers
            ]
        )
        # Text, never a number: keeps the leading 0 and can't turn into 7.9e+08.
        table["الهاتف"] = table["الهاتف"].astype("string")
        st.dataframe(
            table,
            hide_index=True,
            width="stretch",
            # Explicit widths so name, phone and status are never clipped; the
            # short columns give up the space.
            column_config={
                "الاسم": st.column_config.TextColumn("الاسم", width="large"),
                "الهاتف": st.column_config.TextColumn("الهاتف", width="medium"),
                "الحالة": st.column_config.TextColumn("الحالة", width="medium"),
                "منذ": st.column_config.TextColumn("منذ", width="small"),
                "طلبات نشطة": st.column_config.NumberColumn("طلبات نشطة", width="small", format="%d"),
            },
            alt="قائمة السائقين",
        )
        if st.button("تحديث", icon=":material/refresh:", key="drivers_refresh"):
            db.fetch_drivers.clear()
            db.fetch_active_driver_order_counts.clear()
            st.rerun()

    _render_promote()
    if drivers:
        _render_demote(drivers, counts)


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
