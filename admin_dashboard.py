"""
أسواق الطيبات — لوحة التحكم الداخلية
Aswaq Altaibat internal admin dashboard (Streamlit + Supabase).
"""

from __future__ import annotations

import hmac
from collections.abc import Mapping

import pandas as pd
import streamlit as st
from supabase import Client, create_client

st.set_page_config(
    page_title="أسواق الطيبات | لوحة التحكم",
    page_icon="🛒",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ---------------------------------------------------------------------------
# RTL + Arabic typography
# ---------------------------------------------------------------------------
st.markdown(
    """
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&display=swap" rel="stylesheet">
    <style>
      html, body, [class*="st-"], .stApp, .stMarkdown, .stTextInput,
      .stNumberInput, .stSelectbox, .stCheckbox, .stButton, .stDataFrame {
        font-family: "Tajawal", "Segoe UI", sans-serif !important;
      }
      html, body, .stApp { direction: rtl; text-align: right; }
      [data-testid="stSidebar"] { direction: rtl; text-align: right; }
      [data-testid="stSidebarNav"] { display: none; }
      h1, h2, h3 { font-weight: 800 !important; }
      .block-container { padding-top: 1.5rem; }
      div[data-testid="stMetricValue"] { direction: ltr; text-align: right; }
      .stButton > button { width: 100%; font-weight: 700; }
    </style>
    """,
    unsafe_allow_html=True,
)

NAV_OVERVIEW = "نظرة عامة"
NAV_CATEGORIES = "الأقسام"
NAV_PRODUCTS = "المنتجات"
PAGES = [NAV_OVERVIEW, NAV_CATEGORIES, NAV_PRODUCTS]


# ---------------------------------------------------------------------------
# Authentication (credentials live in st.secrets)
# ---------------------------------------------------------------------------
def _secret_str(secrets: Mapping[str, object], key: str) -> str:
    value = secrets.get(key)
    if value is None:
        raise KeyError(key)
    return str(value)


def _constant_time_equal(left: str, right: str) -> bool:
    left_b = left.encode("utf-8")
    right_b = right.encode("utf-8")
    if len(left_b) != len(right_b):
        hmac.compare_digest(left_b, left_b)
        return False
    return hmac.compare_digest(left_b, right_b)


def _credentials_valid(username: str, password: str) -> bool:
    try:
        expected_user = _secret_str(st.secrets, "ADMIN_USERNAME")
        expected_pass = _secret_str(st.secrets, "ADMIN_PASSWORD")
    except (KeyError, FileNotFoundError):
        st.error(
            "لم يتم العثور على بيانات تسجيل الدخول. أضف `ADMIN_USERNAME` و "
            "`ADMIN_PASSWORD` إلى `.streamlit/secrets.toml`."
        )
        return False
    user_ok = _constant_time_equal(username.strip(), expected_user.strip())
    pass_ok = _constant_time_equal(password, expected_pass)
    return user_ok and pass_ok


def require_login() -> None:
    st.session_state.setdefault("authenticated", False)
    if st.session_state.authenticated:
        return

    st.markdown(
        """
        <style>
          [data-testid="stSidebar"] { display: none; }
        </style>
        """,
        unsafe_allow_html=True,
    )

    _, center, _ = st.columns([1, 1.4, 1])
    with center:
        with st.container(border=True):
            st.title("تسجيل الدخول")
            st.caption("لوحة التحكم الداخلية — أسواق الطيبات")
            with st.form("admin_login"):
                username = st.text_input("اسم المستخدم")
                password = st.text_input("كلمة المرور", type="password")
                submitted = st.form_submit_button(
                    "دخول",
                    type="primary",
                    icon=":material/login:",
                    width="stretch",
                )
            if submitted:
                if _credentials_valid(username or "", password or ""):
                    st.session_state.authenticated = True
                    st.rerun()
                st.error("اسم المستخدم أو كلمة المرور غير صحيحة.")
    st.stop()


# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------
@st.cache_resource
def get_supabase() -> Client:
    try:
        url = st.secrets["SUPABASE_URL"]
        key = st.secrets["SUPABASE_SERVICE_ROLE_KEY"]
    except (KeyError, FileNotFoundError) as exc:
        st.error(
            "لم يتم العثور على بيانات الاتصال. أنشئ الملف "
            "`.streamlit/secrets.toml` وأضف `SUPABASE_URL` و "
            "`SUPABASE_SERVICE_ROLE_KEY`."
        )
        raise SystemExit from exc
    return create_client(url, key)


def fetch_categories(sb: Client) -> list[dict]:
    try:
        res = (
            sb.table("categories")
            .select("id, name, name_ar, display_order, is_active, created_at")
            .order("display_order")
            .order("created_at")
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل الأقسام: {exc}")
        return []
    return res.data or []


def fetch_products(sb: Client) -> list[dict]:
    try:
        res = (
            sb.table("products")
            .select(
                "id, name, name_ar, price, discount_price, category_id, "
                "is_weekly_offer, is_app_exclusive, is_active, stock_quantity, "
                "stock_status, created_at, categories(name, name_ar)"
            )
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل المنتجات: {exc}")
        return []
    return res.data or []


def category_label(row: dict) -> str:
    return (row.get("name_ar") or row.get("name") or "").strip()


def product_label(row: dict) -> str:
    return (row.get("name_ar") or row.get("name") or "").strip()


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------
def page_overview(sb: Client) -> None:
    st.title("نظرة عامة")
    st.caption("ملخص سريع لكتالوج أسواق الطيبات")

    categories = fetch_categories(sb)
    products = fetch_products(sb)

    active_products = [p for p in products if p.get("is_active")]
    weekly = [p for p in products if p.get("is_weekly_offer")]
    exclusive = [p for p in products if p.get("is_app_exclusive")]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("الأقسام", len(categories))
    c2.metric("المنتجات", len(products))
    c3.metric("عروض الأسبوع", len(weekly))
    c4.metric("حصري للتطبيق", len(exclusive))

    st.divider()
    left, right = st.columns(2)
    with left:
        st.subheader("عروض هذا الأسبوع")
        if weekly:
            st.dataframe(
                pd.DataFrame(
                    [
                        {
                            "المنتج": product_label(p),
                            "السعر": float(p["price"]),
                        }
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
                        {
                            "المنتج": product_label(p),
                            "السعر": float(p["price"]),
                        }
                        for p in exclusive
                    ]
                ),
                width="stretch",
                hide_index=True,
                alt="منتجات حصرية للتطبيق",
            )
        else:
            st.info("لا توجد منتجات حصرية حالياً.")

    if not active_products and not products:
        st.warning("الكتالوج فارغ. ابدأ بإضافة الأقسام ثم المنتجات من الشريط الجانبي.")


def page_categories(sb: Client) -> None:
    st.title("الأقسام")
    st.caption("إضافة أقسام الكتالوج (ألبان، وجبات خفيفة، لحوم…)")

    with st.form("new_category", clear_on_submit=True):
        st.subheader("إضافة قسم جديد")
        name = st.text_input("اسم القسم", placeholder="مثال: الألبان")
        submitted = st.form_submit_button("حفظ القسم")

    if submitted:
        clean = (name or "").strip()
        if not clean:
            st.error("الرجاء إدخال اسم القسم.")
        else:
            try:
                sb.table("categories").insert(
                    {"name": clean, "name_ar": clean, "is_active": True}
                ).execute()
                st.success(f"تمت إضافة القسم «{clean}».")
                st.rerun()
            except Exception as exc:
                st.error(f"تعذر حفظ القسم: {exc}")

    st.divider()
    st.subheader("الأقسام الحالية")
    rows = fetch_categories(sb)
    if not rows:
        st.info("لا توجد أقسام بعد. أضف أول قسم من النموذج أعلاه.")
        return

    df = pd.DataFrame(
        [
            {
                "الاسم": category_label(r),
                "مفعّل": r.get("is_active"),
                "تاريخ الإنشاء": r.get("created_at"),
            }
            for r in rows
        ]
    )
    st.dataframe(df, width="stretch", hide_index=True, alt="قائمة الأقسام")


def page_products(sb: Client) -> None:
    st.title("المنتجات")
    st.caption("إضافة منتجات جديدة ومتابعة الكتالوج مباشرة")

    categories = fetch_categories(sb)
    if not categories:
        st.warning("أضف قسماً واحداً على الأقل من صفحة الأقسام قبل إضافة المنتجات.")
        return

    options = {category_label(c): c["id"] for c in categories}

    with st.form("new_product", clear_on_submit=True):
        st.subheader("إضافة منتج جديد")
        col_a, col_b = st.columns(2)
        with col_a:
            name = st.text_input("اسم المنتج", placeholder="مثال: حليب كامل الدسم")
            price = st.number_input(
                "السعر",
                min_value=0.0,
                step=0.25,
                format="%.2f",
            )
        with col_b:
            category_name = st.selectbox("القسم", options=list(options.keys()))
            st.write("")
            is_weekly = st.checkbox("عرض الأسبوع (is_weekly_offer)", value=False)
            is_exclusive = st.checkbox("حصري للتطبيق (is_app_exclusive)", value=False)

        submitted = st.form_submit_button("حفظ المنتج")

    if submitted:
        clean = (name or "").strip()
        if not clean:
            st.error("الرجاء إدخال اسم المنتج.")
        elif price is None:
            st.error("الرجاء إدخال السعر.")
        else:
            try:
                sb.table("products").insert(
                    {
                        "name": clean,
                        "name_ar": clean,
                        "price": price,
                        "category_id": options[category_name],
                        "is_weekly_offer": bool(is_weekly),
                        "is_app_exclusive": bool(is_exclusive),
                        "is_active": True,
                    }
                ).execute()
                st.success(f"تمت إضافة المنتج «{clean}».")
                st.rerun()
            except Exception as exc:
                st.error(f"تعذر حفظ المنتج: {exc}")

    st.divider()
    st.subheader("كل المنتجات")
    products = fetch_products(sb)
    if not products:
        st.info("لا توجد منتجات بعد.")
        return

    records = []
    for p in products:
        cat = p.get("categories") or {}
        records.append(
            {
                "المنتج": product_label(p),
                "القسم": category_label(cat) if isinstance(cat, dict) else "",
                "السعر": float(p["price"]) if p.get("price") is not None else None,
                "عرض الأسبوع": p.get("is_weekly_offer"),
                "حصري للتطبيق": p.get("is_app_exclusive"),
                "مفعّل": p.get("is_active"),
                "المخزون": p.get("stock_quantity"),
            }
        )
    st.dataframe(
        pd.DataFrame(records),
        width="stretch",
        hide_index=True,
        alt="قائمة المنتجات",
    )


# ---------------------------------------------------------------------------
# App shell
# ---------------------------------------------------------------------------
def main() -> None:
    require_login()
    sb = get_supabase()

    with st.sidebar:
        st.markdown("### أسواق الطيبات")
        st.caption("لوحة التحكم الداخلية")
        page = st.radio("التنقل", PAGES, index=0)
        st.divider()
        if st.button("تسجيل الخروج", icon=":material/logout:"):
            st.session_state.authenticated = False
            st.rerun()
        st.caption("الاتصال عبر مفتاح service_role — يتجاوز سياسات RLS.")

    if page == NAV_OVERVIEW:
        page_overview(sb)
    elif page == NAV_CATEGORIES:
        page_categories(sb)
    else:
        page_products(sb)


if __name__ == "__main__":
    main()
