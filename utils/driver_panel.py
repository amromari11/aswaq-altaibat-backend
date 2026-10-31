"""Admin panel for moving an order's driver on the customer's tracking map.

Shown on the Orders page for orders that are "out for delivery". Until there is
a driver app, this is how a position is sent: type coordinates, or use the quick
buttons — "move toward the customer" steps the driver along the way, which is
also the easiest way to watch live tracking work end to end.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

import utils.db as db
from utils.fulfillment import driver_details_problem
from utils.insights import AMMAN, local_phone, to_amman
from utils.store import STORE_LAT, STORE_LNG, distance_m, step_toward


def _pin(order: dict) -> tuple[float, float] | None:
    lat, lng = order.get("delivery_lat"), order.get("delivery_lng")
    if lat is None or lng is None:
        return None
    return float(lat), float(lng)


def _send(order_id: str, latitude: float, longitude: float) -> None:
    try:
        db.set_driver_location(order_id, latitude, longitude)
    except Exception as exc:
        st.error(db.driver_error_message(exc))
        return
    st.toast("تم تحديث موقع السائق — يظهر الآن على خريطة العميل.", icon=":material/check_circle:")
    st.rerun()


def _render_driver_details(order: dict) -> None:
    """Who is delivering: shown to the customer as the driver card on their tracking screen."""
    order_id = order["id"]
    with st.container(border=True):
        st.subheader("بيانات السائق")
        st.caption("يراها العميل في بطاقة السائق مع زري الاتصال والمراسلة عبر واتساب، فقط أثناء «خرج للتوصيل». اتركها فارغة لإظهار رقم المتجر.")
        c1, c2 = st.columns(2)
        name = c1.text_input("اسم السائق", value=order.get("driver_name") or "", key=f"drv_name_{order_id}")
        phone = c2.text_input(
            "هاتف السائق",
            value=local_phone(order.get("driver_phone")) if order.get("driver_phone") else "",
            placeholder="079XXXXXXX",
            key=f"drv_phone_{order_id}",
        )
        if st.button("حفظ بيانات السائق", icon=":material/badge:", key=f"drv_details_save_{order_id}"):
            problem = driver_details_problem(name, phone)
            if problem:
                st.error(problem)
                return
            try:
                db.set_driver_details(order_id, name, phone)
            except Exception as exc:
                text = str(exc)
                if "driver_name" in text or "driver_phone" in text:
                    st.error(db.DRIVER_DETAILS_MIGRATION_HINT)
                else:
                    st.error(f"تعذر حفظ بيانات السائق: {exc}")
                return
            st.toast("تم حفظ بيانات السائق.", icon=":material/check_circle:")
            st.rerun()


def render_driver_panel(order: dict) -> None:
    order_id = order["id"]
    _render_driver_details(order)
    pin = _pin(order)
    current = db.fetch_driver_location(order_id)
    here = (float(current["latitude"]), float(current["longitude"])) if current else None
    start = here or (STORE_LAT, STORE_LNG)

    with st.container(border=True):
        st.subheader("موقع السائق")
        st.caption("يصل الموقع إلى خريطة العميل لحظياً. يُحذف تلقائياً عند تغيير حالة الطلب عن «خرج للتوصيل».")

        if here:
            when = to_amman([current["updated_at"]]).iloc[0]
            when_text = f"{when:%H:%M:%S}" if pd.notna(when) else "—"
            st.write(f"آخر موقع مُرسَل: `{here[0]:.6f}, {here[1]:.6f}` عند {when_text}")
        else:
            st.info("لم يُرسَل موقع للسائق بعد — يظهر عند العميل أنه غادر المتجر وننتظر موقعه.")
        if pin:
            remaining = distance_m(here or (STORE_LAT, STORE_LNG), pin)
            st.write(f"موقع العميل: `{pin[0]:.6f}, {pin[1]:.6f}` — المسافة المتبقية ≈ {remaining / 1000:.2f} كم")
        else:
            st.warning("لم يحدد العميل موقعه على الخريطة، لذا لا يمكن عرض المسار أو محاكاة الاقتراب منه.")

        # Sizes are in metres: big enough to see at the zoom that frames a whole trip.
        rows = [{"lat": STORE_LAT, "lon": STORE_LNG, "color": "#13294b", "size": 180}]
        if pin:
            rows.append({"lat": pin[0], "lon": pin[1], "color": "#d7263d", "size": 180})
        if here:
            rows.append({"lat": here[0], "lon": here[1], "color": "#16a34a", "size": 240})
        st.map(pd.DataFrame(rows), latitude="lat", longitude="lon", color="color", size="size", height=240)
        st.caption("أزرق: المتجر · أحمر: العميل · أخضر: السائق")

        # Keyed by the current position so the inputs reset after every move.
        stamp = f"{order_id}_{start[0]:.6f}_{start[1]:.6f}"
        with st.container(horizontal=True):
            lat = st.number_input("خط العرض", min_value=-90.0, max_value=90.0, value=start[0], format="%.6f", step=0.001, key=f"drv_lat_{stamp}")
            lng = st.number_input("خط الطول", min_value=-180.0, max_value=180.0, value=start[1], format="%.6f", step=0.001, key=f"drv_lng_{stamp}")
        if st.button("إرسال هذا الموقع", type="primary", icon=":material/near_me:", key=f"drv_send_{stamp}"):
            _send(order_id, lat, lng)

        with st.container(horizontal=True):
            if st.button("موقع المتجر", icon=":material/storefront:", key=f"drv_store_{stamp}"):
                _send(order_id, STORE_LAT, STORE_LNG)
            if pin:
                if st.button("تحريك السائق نحو العميل", icon=":material/moped:", key=f"drv_step_{stamp}"):
                    nxt = step_toward(start, pin)
                    _send(order_id, nxt[0], nxt[1])
                if st.button("وصل إلى العميل", icon=":material/home_pin:", key=f"drv_arrive_{stamp}"):
                    _send(order_id, pin[0], pin[1])
