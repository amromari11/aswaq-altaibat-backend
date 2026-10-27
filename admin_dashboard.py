"""
أسواق الطيبات — لوحة التحكم الداخلية
Aswaq Altaibat internal admin dashboard (Streamlit + Supabase).
"""

from __future__ import annotations

import streamlit as st

from utils.auth import require_login
from utils.styling import apply_page_style

st.set_page_config(
    page_title="أسواق الطيبات | لوحة التحكم",
    page_icon="🛒",
    layout="wide",
    initial_sidebar_state="expanded",
)

apply_page_style()
require_login()

with st.sidebar:
    st.markdown("### أسواق الطيبات")
    st.caption("لوحة التحكم الداخلية")

page = st.navigation(
    [
        st.Page("app_pages/overview.py", title="نظرة عامة", icon=":material/dashboard:"),
        st.Page("app_pages/orders.py", title="الطلبات", icon=":material/receipt_long:"),
        st.Page("app_pages/customers.py", title="العملاء", icon=":material/group:"),
        st.Page("app_pages/analytics.py", title="التحليلات", icon=":material/insights:"),
        st.Page("app_pages/products.py", title="المنتجات", icon=":material/inventory_2:"),
        st.Page("app_pages/product_images.py", title="صور المنتجات", icon=":material/add_photo_alternate:"),
        st.Page("app_pages/offers.py", title="العروض", icon=":material/local_offer:"),
        st.Page("app_pages/inventory.py", title="المخزون", icon=":material/warehouse:"),
        st.Page("app_pages/categories.py", title="الأقسام", icon=":material/category:"),
        st.Page("app_pages/banners.py", title="البانرات", icon=":material/view_carousel:"),
        st.Page("app_pages/notifications.py", title="الإشعارات", icon=":material/notifications:"),
    ],
    position="sidebar",
)

with st.sidebar:
    st.divider()
    if st.button("تسجيل الخروج", icon=":material/logout:"):
        st.session_state.authenticated = False
        st.rerun()
    st.caption("الاتصال عبر مفتاح service_role — يتجاوز سياسات RLS.")

st.title(page.title, icon=page.icon)
page.run()
