"""التحليلات — sales insights, top-selling products and top delivery zones."""

from datetime import date, timedelta

import altair as alt
import pandas as pd
import streamlit as st

from utils.db import fetch_order_insights, fetch_sales_by_day, fetch_top_products, fetch_top_zones
from utils.insights import PERIOD_LABELS_AR, day_range, pct_change, period_range, previous_range

st.caption("المبيعات والمنتجات الأكثر طلباً ومناطق التوصيل الأكثر نشاطاً — لا تشمل الطلبات الملغاة")

label_to_period = {label: key for key, label in PERIOD_LABELS_AR.items()}
chosen = st.segmented_control(
    "الفترة",
    options=list(PERIOD_LABELS_AR.values()),
    default=PERIOD_LABELS_AR["week"],
    key="analytics_period",
)
period = label_to_period.get(chosen, "week")

if period == "custom":
    picked = st.date_input("اختر الفترة", value=(date.today(), date.today()), key="analytics_custom_range")
    # A range picker yields one date until the second is chosen.
    if isinstance(picked, (tuple, list)) and len(picked) == 2:
        start, end = day_range(picked[0], picked[1])
    else:
        st.info("اختر تاريخ البداية والنهاية.")
        st.stop()
else:
    start, end = period_range(period)

prev_start, prev_end = previous_range(start, end)
st.caption(f"من {start:%Y-%m-%d} إلى {end - timedelta(days=1):%Y-%m-%d} (بتوقيت عمّان)")

insights = fetch_order_insights(start.isoformat(), end.isoformat())
previous = fetch_order_insights(prev_start.isoformat(), prev_end.isoformat())

if not insights:
    st.stop()  # the db layer already showed why


def _delta(field: str) -> str | None:
    change = pct_change(float(insights.get(field) or 0), float(previous.get(field) or 0))
    return None if change is None else f"{change:+.1f}%"


with st.container(horizontal=True):
    st.metric("إجمالي المبيعات (د.أ)", f"{float(insights['total_sales']):,.3f}", _delta("total_sales"), border=True)
    st.metric("عدد الطلبات", int(insights["orders_count"]), _delta("orders_count"), border=True)
    st.metric("متوسط قيمة الطلب (د.أ)", f"{float(insights['avg_order_value']):,.3f}", _delta("avg_order_value"), border=True)
    st.metric("عدد العملاء", int(insights["unique_customers"]), _delta("unique_customers"), border=True)
    st.metric("الطلبات الملغاة", int(insights["cancelled_count"]), border=True)
st.caption("النسبة المئوية مقارنةً بالفترة السابقة لها بنفس الطول.")

st.divider()
st.subheader("المبيعات اليومية")
daily = fetch_sales_by_day(start.isoformat(), end.isoformat())
if daily:
    daily_df = pd.DataFrame(
        [
            {"day": pd.to_datetime(d["day"]), "sales": float(d["sales"]), "orders": int(d["orders_count"])}
            for d in daily
        ]
    )
    # Every day in the window gets a bar, zero if nothing sold — a missing day
    # should read as "no sales", not vanish from the axis. Dates stay real
    # dates (not strings): "2026-10-26" labels get rotated and clipped in an
    # RTL page, and string labels would merge duplicate days on a long range.
    all_days = pd.date_range(start.date(), (end - timedelta(days=1)).date(), freq="D")
    daily_df = daily_df.set_index("day").reindex(all_days, fill_value=0).rename_axis("day").reset_index()
    chart = (
        alt.Chart(daily_df)
        .mark_bar(color="#4c9be8")
        .encode(
            x=alt.X("yearmonthdate(day):O", title="اليوم", axis=alt.Axis(format="%d/%m", labelAngle=0)),
            y=alt.Y("sales:Q", title="المبيعات (د.أ)"),
            tooltip=[
                alt.Tooltip("day:T", title="اليوم", format="%Y-%m-%d"),
                alt.Tooltip("sales:Q", title="المبيعات (د.أ)", format=",.3f"),
                alt.Tooltip("orders:Q", title="الطلبات"),
            ],
        )
    )
    st.altair_chart(chart, width="stretch")
else:
    st.info("لا توجد مبيعات في هذه الفترة.")

st.divider()
st.subheader("الأكثر طلباً")
top_n = st.select_slider("عدد المنتجات", options=[10, 20, 50, 100], value=20, key="analytics_top_n")
products = fetch_top_products(start.isoformat(), end.isoformat(), top_n)
if products:
    products_df = pd.DataFrame(
        [
            {
                "#": rank,
                "المنتج": p.get("name_ar") or p.get("name") or "—",
                "الكمية المباعة": int(p["units_sold"]),
                "عدد الطلبات": int(p["orders_count"]),
                "الإيراد (د.أ)": float(p["revenue"]),
                "الباركود": p.get("sku") or "—",
            }
            for rank, p in enumerate(products, start=1)
        ]
    )
    # The bar lives inside the table: a separate horizontal chart clips long
    # Arabic product names.
    st.dataframe(
        products_df,
        hide_index=True,
        width="stretch",
        alt="المنتجات الأكثر طلباً",
        column_config={
            "الكمية المباعة": st.column_config.ProgressColumn(
                "الكمية المباعة", min_value=0, max_value=int(products_df["الكمية المباعة"].max()), format="%d"
            ),
            "الإيراد (د.أ)": st.column_config.NumberColumn("الإيراد (د.أ)", format="%.3f"),
        },
    )
else:
    st.info("لا توجد منتجات مباعة في هذه الفترة.")

st.divider()
st.subheader("أكثر مناطق التوصيل")
zones = fetch_top_zones(start.isoformat(), end.isoformat(), 10)
if zones:
    zones_df = pd.DataFrame(
        [
            {
                "المنطقة": z.get("zone_name_ar") or "غير محددة",
                "الطلبات": int(z["orders_count"]),
                "المبيعات (د.أ)": float(z["sales"]),
            }
            for z in zones
        ]
    )
    st.dataframe(
        zones_df,
        hide_index=True,
        width="stretch",
        alt="مناطق التوصيل الأكثر نشاطاً",
        column_config={
            "الطلبات": st.column_config.ProgressColumn(
                "الطلبات", min_value=0, max_value=int(zones_df["الطلبات"].max()), format="%d"
            ),
            "المبيعات (د.أ)": st.column_config.NumberColumn("المبيعات (د.أ)", format="%.3f"),
        },
    )
else:
    st.info("لا توجد طلبات في هذه الفترة.")
