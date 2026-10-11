"""العروض — weekly offers & app-exclusive flags, edited in bulk."""

import pandas as pd
import streamlit as st

from utils.db import fetch_products, update_product

st.caption("إدارة عروض الأسبوع، المنتجات الحصرية للتطبيق، وسعر العرض")

products = fetch_products()
if not products:
    st.info("لا توجد منتجات بعد.")
else:
    df = pd.DataFrame(
        [
            {
                "id": p["id"],
                "المنتج": p.get("name_ar") or p.get("name") or "",
                "السعر": float(p["price"]) if p.get("price") is not None else None,
                "سعر العرض": float(p["discount_price"]) if p.get("discount_price") is not None else None,
                "عرض الأسبوع": bool(p.get("is_weekly_offer")),
                "حصري للتطبيق": bool(p.get("is_app_exclusive")),
            }
            for p in products
        ]
    )

    st.data_editor(
        df,
        key="offers_editor",
        hide_index=True,
        disabled=["المنتج", "السعر"],
        column_config={
            "id": None,
            "سعر العرض": st.column_config.NumberColumn(format="%.2f", min_value=0.0, step=0.25),
        },
        alt="تعديل عروض الأسبوع والمنتجات الحصرية للتطبيق",
    )

    if st.button("حفظ التغييرات", type="primary", icon=":material/save:"):
        edits = st.session_state["offers_editor"]["edited_rows"]
        if not edits:
            st.info("لا توجد تغييرات لحفظها.")
        else:
            errors = []
            for row_index, changes in edits.items():
                row = df.iloc[row_index]
                fields = {}
                if "سعر العرض" in changes:
                    fields["discount_price"] = changes["سعر العرض"]
                if "عرض الأسبوع" in changes:
                    fields["is_weekly_offer"] = changes["عرض الأسبوع"]
                if "حصري للتطبيق" in changes:
                    fields["is_app_exclusive"] = changes["حصري للتطبيق"]
                if fields:
                    try:
                        update_product(row["id"], fields)
                    except Exception as exc:
                        errors.append(f"{row['المنتج']}: {exc}")
            if errors:
                st.error("تعذر حفظ بعض التغييرات:\n" + "\n".join(errors))
            else:
                st.success("تم حفظ التغييرات.")
                st.rerun()
