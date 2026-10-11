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
    filtered = orders if selected_status == "all" else [o for o in orders if o["status"] == selected_status]

    if not filtered:
        st.info("لا توجد طلبات بهذه الحالة.")
    else:
        df = pd.DataFrame(
            [
                {
                    "العميل": (o.get("profiles") or {}).get("full_name") or "—",
                    "الهاتف": (o.get("profiles") or {}).get("phone_number") or "—",
                    "الحالة": ORDER_STATUS_LABELS_AR.get(o["status"], o["status"]),
                    "الإجمالي": float(o.get("total_price") or 0),
                    "العنوان": o.get("delivery_address") or "—",
                    "التاريخ": o.get("created_at"),
                }
                for o in filtered
            ]
        )

        event = st.dataframe(
            df,
            hide_index=True,
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
            customer = order.get("profiles") or {}

            with st.container(border=True):
                st.subheader("تفاصيل الطلب")
                st.table(
                    {
                        "العميل": customer.get("full_name") or "—",
                        "الهاتف": customer.get("phone_number") or "—",
                        "عنوان التوصيل": order.get("delivery_address") or "—",
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

                st.divider()
                with st.container(horizontal=True):
                    new_status = st.selectbox(
                        "تحديث الحالة",
                        options=ORDER_STATUSES,
                        index=ORDER_STATUSES.index(order["status"]),
                        format_func=lambda s: ORDER_STATUS_LABELS_AR[s],
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
