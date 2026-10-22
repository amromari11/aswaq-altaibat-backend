"""نظرة عامة — overview / KPI summary."""

import pandas as pd
import streamlit as st

from utils.db import count_categories, count_orders, count_products, fetch_orders, fetch_products

st.caption("ملخص سريع لكتالوج ومبيعات أسواق الطيبات")

# Exact counts (see utils.db._exact_count) — a plain `len(fetch_x())` silently
# capped at ~1000 once the catalog passed that size (PostgREST's default
# per-request row limit), which is exactly what made "المنتجات" read 1000
# instead of the real ~11,443.
categories_count = count_categories()
products_count = count_products()
weekly_count = count_products(is_weekly_offer=True)
exclusive_count = count_products(is_app_exclusive=True)
orders_count = count_orders()
pending_count = count_orders(statuses=("pending", "confirmed", "preparing"))
delivered_count = count_orders(statuses=("delivered",))

with st.container(horizontal=True):
    st.metric("الأقسام", categories_count, border=True)
    st.metric("المنتجات", products_count, border=True)
    st.metric("عروض الأسبوع", weekly_count, border=True)
    st.metric("حصري للتطبيق", exclusive_count, border=True)

with st.container(horizontal=True):
    st.metric("إجمالي الطلبات", orders_count, border=True)
    st.metric("طلبات قيد التنفيذ", pending_count, border=True)
    st.metric("الطلبات المكتملة", delivered_count, border=True)
    # Revenue is a SUM, not a row count — count="exact" can't help here.
    # Still safe for now since `fetch_orders()` won't itself be size-capped
    # until the orders table passes ~1000 rows too, which it's nowhere
    # near yet. If order volume ever grows that large, this needs the same
    # treatment as the counts above (a server-side aggregate, since a
    # client-side sum over a capped row list would quietly undercount the
    # same way the product counts just did).
    delivered_orders = [o for o in fetch_orders() if o.get("status") == "delivered"]
    total_revenue = sum(float(o.get("total_price") or 0) for o in delivered_orders)
    st.metric("إجمالي مبيعات الطلبات المكتملة", f"{total_revenue:,.2f}", border=True)

st.divider()
left, right = st.columns(2)
with left:
    st.subheader("عروض هذا الأسبوع")
    # These two tables list the *curated* subset (expected to stay a small,
    # deliberately-flagged handful), not the full catalog — fetch_products()
    # is fine to reuse here even while it's capped for the full-catalog case.
    weekly_products = [p for p in fetch_products() if p.get("is_weekly_offer")]
    if weekly_products:
        st.dataframe(
            pd.DataFrame(
                [
                    {"المنتج": p.get("name_ar") or p.get("name") or "", "السعر": float(p["price"])}
                    for p in weekly_products
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
    exclusive_products = [p for p in fetch_products() if p.get("is_app_exclusive")]
    if exclusive_products:
        st.dataframe(
            pd.DataFrame(
                [
                    {"المنتج": p.get("name_ar") or p.get("name") or "", "السعر": float(p["price"])}
                    for p in exclusive_products
                ]
            ),
            width="stretch",
            hide_index=True,
            alt="منتجات حصرية للتطبيق",
        )
    else:
        st.info("لا توجد منتجات حصرية حالياً.")

if products_count == 0:
    st.warning("الكتالوج فارغ. ابدأ بإضافة الأقسام ثم المنتجات من القائمة الجانبية.")
