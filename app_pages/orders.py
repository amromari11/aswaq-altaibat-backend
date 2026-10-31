"""الطلبات — order management and status updates."""

import pandas as pd
import streamlit as st

from utils.db import (
    ORDER_STATUS_LABELS_AR,
    ORDER_STATUSES,
    fetch_order_items,
    fetch_orders,
    update_order_status,
)
from utils.driver_panel import render_driver_panel
from utils.fulfillment import ORDER_TYPE_LABELS_AR, order_type, order_type_label, schedule_label, status_label
from utils.insights import local_phone, order_customer, to_amman

st.caption("متابعة الطلبات وتحديث حالتها")

orders = fetch_orders()

if not orders:
    st.info("لا توجد طلبات بعد.")
else:
    status_labels = {"all": "الكل", **ORDER_STATUS_LABELS_AR}
    label_to_status = {v: k for k, v in status_labels.items()}

    selected_label = st.segmented_control(
        "تصفية حسب الحالة",
        options=list(status_labels.values()),
        default=status_labels["all"],
    )
    selected_status = label_to_status.get(selected_label, "all")
    type_labels = {"all": "الكل", **ORDER_TYPE_LABELS_AR}
    selected_type_label = st.segmented_control("طريقة الاستلام", options=list(type_labels.values()), default=type_labels["all"])
    selected_type = {v: k for k, v in type_labels.items()}.get(selected_type_label, "all")
    filtered = [
        o
        for o in orders
        if (selected_status == "all" or o["status"] == selected_status)
        and (selected_type == "all" or order_type(o) == selected_type)
    ]

    if not filtered:
        st.info("لا توجد طلبات بهذه الحالة.")
    else:
        df = pd.DataFrame(
            [
                {
                    "العميل": order_customer(o)[0],
                    "الهاتف": local_phone(order_customer(o)[1]),
                    "النوع": order_type_label(o),
                    "الموعد": schedule_label(o),
                    "المنطقة": (o.get("delivery_zones") or {}).get("name_ar") or "—",
                    "الحالة": status_label(o["status"], order_type(o)),
                    "الإجمالي": float(o.get("total_price") or 0),
                    "العنوان": o.get("delivery_address") or "—",
                    "التاريخ": o.get("created_at"),
                }
                for o in filtered
            ]
        )

        df["التاريخ"] = to_amman(df["التاريخ"])
        event = st.dataframe(
            df,
            hide_index=True,
            column_config={"التاريخ": st.column_config.DatetimeColumn("التاريخ", format="YYYY-MM-DD HH:mm")},
            on_select="rerun",
            selection_mode="single-row",
            alt="قائمة الطلبات",
            key="orders_table",
        )

        selected_rows = event.selection.rows
        if not selected_rows:
            st.caption("اختر طلباً من الجدول أعلاه لعرض التفاصيل وتحديث الحالة.")
        else:
            order = filtered[selected_rows[0]]
            customer_name, customer_phone = order_customer(order)

            with st.container(border=True):
                st.subheader("تفاصيل الطلب")
                kind = order_type(order)
                st.table(
                    {
                        "العميل": customer_name,
                        "الهاتف": local_phone(customer_phone),
                        "النوع": order_type_label(order),
                        "الموعد": schedule_label(order),
                        **(
                            {}
                            if kind == "pickup"
                            else {
                                "المنطقة": (order.get("delivery_zones") or {}).get("name_ar") or "—",
                                "عنوان التوصيل": order.get("delivery_address") or "—",
                            }
                        ),
                        "طريقة الدفع": order.get("payment_method") or "—",
                        "ملاحظات": order.get("notes") or "—",
                    },
                    border="horizontal",
                    width="content",
                )

                items = fetch_order_items(order["id"])
                if items:
                    item_df = pd.DataFrame(
                        [
                            {
                                "المنتج": (
                                    (i.get("products") or {}).get("name_ar")
                                    or (i.get("products") or {}).get("name")
                                    or "—"
                                ),
                                "الكمية": i["quantity"],
                                "سعر الوحدة": float(i["unit_price"]),
                                "الإجمالي": float(i["line_total"]),
                            }
                            for i in items
                        ]
                    )
                    st.dataframe(item_df, hide_index=True, width="stretch", alt="عناصر الطلب")
                else:
                    st.caption("لا توجد عناصر مسجلة لهذا الطلب.")

                if order["status"] == "out_for_delivery" and kind == "delivery":
                    render_driver_panel(order)

                st.divider()
                with st.container(horizontal=True):
                    new_status = st.selectbox(
                        "تحديث الحالة",
                        options=ORDER_STATUSES,
                        index=ORDER_STATUSES.index(order["status"]),
                        format_func=lambda s: status_label(s, kind),
                        key=f"status_select_{order['id']}",
                    )
                    if st.button(
                        "حفظ الحالة",
                        type="primary",
                        icon=":material/save:",
                        key=f"save_status_{order['id']}",
                    ):
                        try:
                            update_order_status(order["id"], new_status)
                            st.toast("تم تحديث حالة الطلب.", icon=":material/check_circle:")
                            st.rerun()
                        except Exception as exc:
                            st.error(f"تعذر تحديث الحالة: {exc}")
