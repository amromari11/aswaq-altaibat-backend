"""المخزون — stock quantities and availability status, edited in bulk."""

import pandas as pd
import streamlit as st

from utils.db import STOCK_STATUS_LABELS_AR, fetch_products, update_product

st.caption("تحديث الكميات وحالة توفر المنتجات")

products = fetch_products()
if not products:
    st.info("لا توجد منتجات بعد.")
else:
    low_stock = [p for p in products if p.get("stock_status") in ("low_stock", "out_of_stock")]
    if low_stock:
        st.warning(f"{len(low_stock)} منتج بحاجة إلى مراجعة المخزون.", icon=":material/warning:")

    status_label_options = list(STOCK_STATUS_LABELS_AR.values())
    label_to_status = {v: k for k, v in STOCK_STATUS_LABELS_AR.items()}

    df = pd.DataFrame(
        [
            {
                "id": p["id"],
                "المنتج": p.get("name_ar") or p.get("name") or "",
                "الكمية": int(p.get("stock_quantity") or 0),
                "الحالة": STOCK_STATUS_LABELS_AR.get(p.get("stock_status"), status_label_options[0]),
            }
            for p in products
        ]
    )

    st.data_editor(
        df,
        key="inventory_editor",
        hide_index=True,
        disabled=["المنتج"],
        column_config={
            "id": None,
            "الكمية": st.column_config.NumberColumn(min_value=0, step=1),
            "الحالة": st.column_config.SelectboxColumn(options=status_label_options),
        },
        alt="تعديل كميات وحالة توفر المنتجات",
    )

    if st.button("حفظ المخزون", type="primary", icon=":material/save:"):
        edits = st.session_state["inventory_editor"]["edited_rows"]
        if not edits:
            st.info("لا توجد تغييرات لحفظها.")
        else:
            errors = []
            for row_index, changes in edits.items():
                row = df.iloc[row_index]
                fields = {}
                if "الكمية" in changes:
                    fields["stock_quantity"] = int(changes["الكمية"])
                if "الحالة" in changes:
                    fields["stock_status"] = label_to_status.get(changes["الحالة"], "in_stock")
                if fields:
                    try:
                        update_product(row["id"], fields)
                    except Exception as exc:
                        errors.append(f"{row['المنتج']}: {exc}")
            if errors:
                st.error("تعذر حفظ بعض التغييرات:\n" + "\n".join(errors))
            else:
                st.success("تم حفظ المخزون.")
                st.rerun()
