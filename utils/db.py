"""Supabase data-access layer for the admin dashboard.

Every call here uses the service_role key (see `get_supabase`), so it
bypasses Row Level Security entirely. Treat every function in this module as
having full read/write access to the database.

Fetch functions are cached with a short TTL; every insert/update/delete
clears the relevant cache before returning so the next read is fresh.
"""

from __future__ import annotations

import unicodedata
from datetime import datetime, timezone

import streamlit as st
from supabase import Client, create_client

ORDER_STATUSES: list[str] = [
    "pending",
    "confirmed",
    "preparing",
    "out_for_delivery",
    "delivered",
    "cancelled",
]

ORDER_STATUS_LABELS_AR: dict[str, str] = {
    "pending": "قيد الانتظار",
    "confirmed": "مؤكد",
    "preparing": "قيد التحضير",
    "out_for_delivery": "في الطريق",
    "delivered": "تم التوصيل",
    "cancelled": "ملغي",
}

STOCK_STATUSES: list[str] = ["in_stock", "low_stock", "out_of_stock"]

STOCK_STATUS_LABELS_AR: dict[str, str] = {
    "in_stock": "متوفر",
    "low_stock": "كمية محدودة",
    "out_of_stock": "غير متوفر",
}

NOTIFICATION_AUDIENCES: list[str] = ["all", "weekly_offer_subscribers", "single_user"]

NOTIFICATION_AUDIENCE_LABELS_AR: dict[str, str] = {
    "all": "جميع العملاء",
    "weekly_offer_subscribers": "مهتمون بعروض الأسبوع",
    "single_user": "عميل واحد",
}

NOTIFICATION_STATUS_LABELS_AR: dict[str, str] = {
    "queued": "قيد الانتظار",
    "sent": "تم الإرسال",
    "failed": "فشل",
}


def _clean_ascii_secret(value: object) -> str:
    """Strip whitespace and any non-ASCII characters from a secret.

    `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` go straight into the
    Authorization/apikey HTTP headers on every request, and HTTP header
    values must be pure ASCII. A stray non-breaking space, curly quote, or
    right-to-left mark picked up when copying the value into Streamlit
    Cloud's secrets editor is invisible but crashes every single Supabase
    call with `'ascii' codec can't encode characters...`. Both values are
    URLs/JWTs, which are ASCII-only by construction, so it's always safe to
    drop anything outside that range here rather than fail on every page.
    """
    normalized = unicodedata.normalize("NFKC", str(value)).strip()
    return "".join(ch for ch in normalized if ord(ch) < 128)


@st.cache_resource
def get_supabase() -> Client:
    try:
        raw_url = st.secrets["SUPABASE_URL"]
        raw_key = st.secrets["SUPABASE_SERVICE_ROLE_KEY"]
    except (KeyError, FileNotFoundError) as exc:
        st.error(
            "لم يتم العثور على بيانات الاتصال. أنشئ الملف "
            "`.streamlit/secrets.toml` وأضف `SUPABASE_URL` و "
            "`SUPABASE_SERVICE_ROLE_KEY`."
        )
        raise SystemExit from exc

    url = _clean_ascii_secret(raw_url)
    key = _clean_ascii_secret(raw_key)

    if not url or not key:
        st.error(
            "قيمة SUPABASE_URL أو SUPABASE_SERVICE_ROLE_KEY فارغة أو غير "
            "صالحة بعد التنظيف. أعد نسخها من لوحة Supabase مباشرة إلى "
            "secrets.toml دون أي تنسيق إضافي."
        )
        raise SystemExit

    if url != str(raw_url).strip() or key != str(raw_key).strip():
        st.warning(
            "تم العثور على أحرف غير صالحة (غير ASCII) في بيانات اتصال "
            "Supabase وتمت إزالتها تلقائياً. يُنصح بإعادة نسخ القيم من لوحة "
            "Supabase للتأكد من سلامتها.",
            icon=":material/warning:",
        )

    return create_client(url, key)


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------
@st.cache_data(ttl="30s")
def fetch_categories() -> list[dict]:
    sb = get_supabase()
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


def insert_category(name: str, name_ar: str) -> None:
    sb = get_supabase()
    sb.table("categories").insert({"name": name, "name_ar": name_ar, "is_active": True}).execute()
    fetch_categories.clear()


def update_category(category_id: str, fields: dict) -> None:
    sb = get_supabase()
    sb.table("categories").update(fields).eq("id", category_id).execute()
    fetch_categories.clear()


def delete_category(category_id: str) -> None:
    sb = get_supabase()
    sb.table("categories").delete().eq("id", category_id).execute()
    fetch_categories.clear()


# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------
@st.cache_data(ttl="30s")
def fetch_products() -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("products")
            .select(
                "id, name, name_ar, description, sku, unit, price, discount_price, "
                "category_id, stock_quantity, stock_status, is_weekly_offer, "
                "is_app_exclusive, is_active, created_at, categories(name, name_ar)"
            )
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل المنتجات: {exc}")
        return []
    return res.data or []


def insert_product(payload: dict) -> None:
    sb = get_supabase()
    sb.table("products").insert(payload).execute()
    fetch_products.clear()


def update_product(product_id: str, fields: dict) -> None:
    sb = get_supabase()
    sb.table("products").update(fields).eq("id", product_id).execute()
    fetch_products.clear()


def delete_product(product_id: str) -> None:
    sb = get_supabase()
    sb.table("products").delete().eq("id", product_id).execute()
    fetch_products.clear()


# ---------------------------------------------------------------------------
# Profiles (customers)
# ---------------------------------------------------------------------------
@st.cache_data(ttl="30s")
def fetch_profiles() -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("profiles")
            .select("id, full_name, phone_number, loyalty_points, created_at")
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل العملاء: {exc}")
        return []
    return res.data or []


# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------
@st.cache_data(ttl="20s")
def fetch_orders() -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("orders")
            .select(
                "id, status, subtotal, delivery_fee, discount_amount, total_price, "
                "delivery_address, payment_method, notes, created_at, user_id, "
                "profiles(full_name, phone_number)"
            )
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل الطلبات: {exc}")
        return []
    return res.data or []


@st.cache_data(ttl="20s")
def fetch_order_items(order_id: str) -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("order_items")
            .select("id, quantity, unit_price, line_total, products(name, name_ar, unit)")
            .eq("order_id", order_id)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل عناصر الطلب: {exc}")
        return []
    return res.data or []


def update_order_status(order_id: str, status: str) -> None:
    sb = get_supabase()
    sb.table("orders").update({"status": status}).eq("id", order_id).execute()
    fetch_orders.clear()


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
@st.cache_data(ttl="20s")
def fetch_notifications() -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("notifications")
            .select("*")
            .order("created_at", desc=True)
            .limit(100)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل سجل الإشعارات: {exc}")
        return []
    return res.data or []


def count_push_tokens(user_id: str | None = None) -> int:
    sb = get_supabase()
    query = sb.table("push_tokens").select("id", count="exact")
    if user_id:
        query = query.eq("user_id", user_id)
    res = query.execute()
    return res.count or 0


def insert_notification(payload: dict) -> dict:
    sb = get_supabase()
    res = sb.table("notifications").insert(payload).execute()
    fetch_notifications.clear()
    return (res.data or [{}])[0]


def update_notification_result(
    notification_id: str,
    status: str,
    recipient_count: int,
    error_message: str | None = None,
) -> None:
    sb = get_supabase()
    sb.table("notifications").update(
        {
            "status": status,
            "recipient_count": recipient_count,
            "error_message": error_message,
            "sent_at": datetime.now(timezone.utc).isoformat(),
        }
    ).eq("id", notification_id).execute()
    fetch_notifications.clear()
