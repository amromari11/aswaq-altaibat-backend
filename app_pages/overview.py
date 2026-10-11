"""نظرة عامة — overview / KPI summary."""

import pandas as pd
import streamlit as st

from utils.db import fetch_categories, fetch_orders, fetch_products

st.caption("ملخص سريع لكتالوج ومبيعات أسواق الطيبات")

categories = fetch_categories()
products = fetch_products()
orders = fetch_orders()

weekly = [p for p in products if p.get("is_weekly_offer")]
exclusive = [p for p in products if p.get("is_app_exclusive")]
pending_orders = [o for o in orders if o.get("status") in ("pending", "confirmed", "preparing")]
delivered_orders = [o for o in orders if o.get("status") == "delivered"]
total_revenue = sum(float(o.get("total_price") or 0) for o in delivered_orders)

with st.container(horizontal=True):
    st.metric("الأقسام", len(categories), border=True)
    st.metric("المنتجات", len(products), border=True)
    st.metric("عروض الأسبوع", len(weekly), border=True)
    st.metric("حصري للتطبيق", len(exclusive), border=True)

with st.container(horizontal=True):
    st.metric("إجمالي الطلبات", len(orders), border=True)
    st.metric("طلبات قيد التنفيذ", len(pending_orders), border=True)
    st.metric("الطلبات المكتملة", len(delivered_orders), border=True)
    st.metric("إجمالي مبيعات الطلبات المكتملة", f"{total_revenue:,.2f}", border=True)

st.divider()
left, right = st.columns(2)
with left:
    st.subheader("عروض هذا الأسبوع")
    if weekly:
        st.dataframe(
            pd.DataFrame(
                [
                    {"المنتج": p.get("name_ar") or p.get("name") or "", "السعر": float(p["price"])}
                    for p in weekly
                ]
            ),
            width="stretch",
            hide_index=True,
            alt="عروض هذا الأسبوع",
        )
    else:
        st.info("لا توجد عروض أسبوعية حالياً.")

with right:
    st.subheader("منتجات حصرية للتطبيق")
    if exclusive:
        st.dataframe(
            pd.DataFrame(
                [
                    {"المنتج": p.get("name_ar") or p.get("name") or "", "السعر": float(p["price"])}
                    for p in exclusive
                ]
            ),
            width="stretch",
            hide_index=True,
            alt="منتجات حصرية للتطبيق",
        )
    else:
        st.info("لا توجد منتجات حصرية حالياً.")

if not products:
    st.warning("الكتالوج فارغ. ابدأ بإضافة الأقسام ثم المنتجات من القائمة الجانبية.")
