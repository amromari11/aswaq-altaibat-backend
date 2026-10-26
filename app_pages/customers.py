"""العملاء — every customer with their order history and total spend."""

import pandas as pd
import streamlit as st

from utils.db import (
    ORDER_STATUS_LABELS_AR,
    fetch_customer_orders,
    fetch_customer_stats,
    fetch_order_items,
)
from utils.insights import filter_customers, local_phone, sort_customers, to_amman

st.caption(
    "العملاء يُنشأون تلقائياً عند أول طلب (حتى بدون حساب) ويُعرَّفون برقم الهاتف. "
    "الإنفاق لا يشمل الطلبات الملغاة. الأرقام غير مُتحقَّق منها بالرسائل."
)

customers = fetch_customer_stats()
if not customers:
    st.info("لا يوجد عملاء بعد — سيظهر العميل هنا عند أول طلب.")
    st.stop()

with st.container(horizontal=True):
    st.metric("عدد العملاء", len(customers), border=True)
    st.metric("عملاء لديهم طلبات", sum(1 for c in customers if c["orders_count"]), border=True)
    st.metric("إجمالي إنفاق العملاء (د.أ)", f"{sum(float(c['total_spend']) for c in customers):,.3f}", border=True)
    st.metric("عملاء لديهم حساب Google", sum(1 for c in customers if c["has_google_account"]), border=True)

query = st.text_input("بحث بالاسم أو رقم الهاتف", placeholder="مثال: سالم أو 0791234567", key="customer_search")
sort_labels = {
    "الأعلى إنفاقاً": "total_spend",
    "الأكثر طلباً": "orders_count",
    "الأحدث طلباً": "last_order_at",
    "الأحدث تسجيلاً": "created_at",
}
sort_choice = st.segmented_control("الترتيب", options=list(sort_labels), default="الأعلى إنفاقاً", key="customer_sort")
sort_field = sort_labels.get(sort_choice, "total_spend")

customers = sort_customers(filter_customers(customers, query), sort_field)

if not customers:
    st.info("لا يوجد عملاء مطابقون للبحث.")
    st.stop()

table = pd.DataFrame(
    [
        {
            "الاسم": c.get("full_name") or "—",
            "الهاتف": local_phone(c.get("phone_number")),
            "الطلبات": int(c["orders_count"]),
            "الملغاة": int(c["cancelled_count"]),
            "إجمالي الإنفاق (د.أ)": float(c["total_spend"]),
            "آخر طلب": c.get("last_order_at"),
            "حساب Google": "نعم" if c["has_google_account"] else "—",
        }
        for c in customers
    ]
)
table["آخر طلب"] = to_amman(table["آخر طلب"])
event = st.dataframe(
    table,
    hide_index=True,
    width="stretch",
    column_config={
        "آخر طلب": st.column_config.DatetimeColumn("آخر طلب", format="YYYY-MM-DD HH:mm"),
        "إجمالي الإنفاق (د.أ)": st.column_config.NumberColumn("إجمالي الإنفاق (د.أ)", format="%.3f"),
    },
    on_select="rerun",
    selection_mode="single-row",
    alt="قائمة العملاء",
    key="customers_table",
)

if not event.selection.rows:
    st.caption("اختر عميلاً من الجدول لعرض سجل طلباته.")
    st.stop()

customer = customers[event.selection.rows[0]]
with st.container(border=True):
    st.subheader(customer.get("full_name") or "—")
    st.caption(
        f"الهاتف: {local_phone(customer.get('phone_number'))} · "
        f"طلبات: {int(customer['orders_count'])} · "
        f"إجمالي الإنفاق: {float(customer['total_spend']):,.3f} د.أ"
    )

    orders = fetch_customer_orders(customer["customer_id"])
    if not orders:
        st.info("لا توجد طلبات لهذا العميل بعد.")
        st.stop()

    history = pd.DataFrame(
        [
            {
                "التاريخ": o.get("created_at"),
                "الحالة": ORDER_STATUS_LABELS_AR.get(o["status"], o["status"]),
                "المنطقة": (o.get("delivery_zones") or {}).get("name_ar") or "—",
                "التوصيل": float(o.get("delivery_fee") or 0),
                "الإجمالي (د.أ)": float(o.get("total_price") or 0),
                "العنوان": o.get("delivery_address") or "—",
                "الاسم وقت الطلب": o.get("customer_name") or "—",
            }
            for o in orders
        ]
    )
    history["التاريخ"] = to_amman(history["التاريخ"])
    pick = st.dataframe(
        history,
        hide_index=True,
        width="stretch",
        column_config={
            "التاريخ": st.column_config.DatetimeColumn("التاريخ", format="YYYY-MM-DD HH:mm"),
            "الإجمالي (د.أ)": st.column_config.NumberColumn("الإجمالي (د.أ)", format="%.3f"),
        },
        on_select="rerun",
        selection_mode="single-row",
        alt="سجل طلبات العميل",
        key="customer_orders_table",
    )
    if pick.selection.rows:
        items = fetch_order_items(orders[pick.selection.rows[0]]["id"])
        if items:
            st.dataframe(
                pd.DataFrame(
                    [
                        {
                            "المنتج": (i.get("products") or {}).get("name_ar") or (i.get("products") or {}).get("name") or "—",
                            "الكمية": i["quantity"],
                            "سعر الوحدة": float(i["unit_price"]),
                            "الإجمالي": float(i["line_total"]),
                        }
                        for i in items
                    ]
                ),
                hide_index=True,
                width="stretch",
                alt="عناصر الطلب",
            )
    else:
        st.caption("اختر طلباً لعرض محتوياته.")
