"""Supabase data-access layer for the admin dashboard.

Every call here uses the service_role key (see `get_supabase`), so it
bypasses Row Level Security entirely. Treat every function in this module as
having full read/write access to the database.

Fetch functions are cached with a short TTL; every insert/update/delete
clears the relevant cache before returning so the next read is fresh.
"""

from __future__ import annotations

import hashlib
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


# TEMPORARY DEBUG OVERRIDE — remove once Streamlit Cloud is confirmed to
# load secrets edits correctly, and go back to st.secrets["SUPABASE_URL"].
# Hardcoded here (instead of read from st.secrets) purely to rule out a
# Streamlit Cloud secrets-loading problem as the cause of the "Name or
# service not known" DNS error. Value matches .streamlit/secrets.toml,
# which was confirmed locally to resolve and return real data.
_HARDCODED_SUPABASE_URL = "https://fbtxwrxewykgewrykvir.supabase.co"


@st.cache_resource
def get_supabase() -> Client:
    url = _HARDCODED_SUPABASE_URL

    try:
        key = st.secrets["SUPABASE_SERVICE_ROLE_KEY"].strip()
    except (KeyError, FileNotFoundError) as exc:
        st.error(
            "لم يتم العثور على بيانات الاتصال. أنشئ الملف "
            "`.streamlit/secrets.toml` وأضف `SUPABASE_SERVICE_ROLE_KEY`."
        )
        raise SystemExit from exc

    # Startup diagnostics for "Name or service not known" (DNS failure):
    # printed to the server-side app log (Streamlit Cloud > Manage app >
    # Logs), never to the page. Only the URL is printed in full — a
    # service_role key is a credential and never belongs in logs — the key
    # is checked the same way but only its length is logged.
    print(f"[get_supabase] SUPABASE_URL (hardcoded) repr: {url!r}", flush=True)
    print(f"[get_supabase] SUPABASE_URL length: {len(url)}", flush=True)

    # A fingerprint, not the key: a 401 Invalid API key means the stored
    # value is wrong somehow (stale, from a different/rotated project key,
    # truncated, etc.), but the key itself is a full-access credential that
    # must never be hardcoded into source or printed in full — even in
    # private logs. This is enough to compare "is Cloud loading the same
    # key as local" without ever exposing or materializing the real value.
    key_fingerprint = hashlib.sha256(key.encode()).hexdigest()[:12]
    print(
        f"[get_supabase] SUPABASE_SERVICE_ROLE_KEY length={len(key)} "
        f"prefix={key[:6]!r} suffix={key[-4:]!r} sha256={key_fingerprint}",
        flush=True,
    )

    # .strip() only trims the two ends; it can't catch whitespace or a
    # newline pasted into the *middle* of the value (e.g. a secrets-editor
    # textarea that line-wrapped a long key into two literal lines). That
    # corrupts the credential, so flag it loudly instead of silently
    # rewriting the secret.
    if any(ch.isspace() for ch in key):
        print(
            "[get_supabase] SUPABASE_SERVICE_ROLE_KEY contains embedded whitespace",
            flush=True,
        )
        st.error(
            "تحتوي قيمة SUPABASE_SERVICE_ROLE_KEY على مسافة أو سطر جديد في "
            "منتصفها. افتح Settings → Secrets على Streamlit Cloud وتأكد "
            "أنها سطر واحد متواصل، ثم أعد تشغيل التطبيق (Reboot)."
        )
        raise SystemExit

    return create_client(url, key)


def _exact_count(table: str, filters: dict | None = None) -> int:
    """Row count via PostgREST's ``count="exact"``, independent of any
    per-request row limit.

    Supabase/PostgREST caps a plain ``.select()`` at ~1000 rows per request
    by default (a server-side ``db-max-rows`` setting) — harmless for small
    tables, but once a table passes that size every ``len(fetch_x())``-based
    count on this dashboard silently reported 1000 instead of the real
    total (this is exactly what happened to the "المنتجات" card once the
    catalog passed 11,000 rows). ``count="exact"`` runs a server-side
    ``SELECT count(*)`` instead, so it's correct regardless of table size —
    and cheaper, since ``.limit(1)`` means only one row of data actually
    transfers.
    """
    sb = get_supabase()
    query = sb.table(table).select("id", count="exact").limit(1)
    if filters:
        for column, value in filters.items():
            query = query.eq(column, value)
    res = query.execute()
    return res.count or 0


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------
@st.cache_data(ttl="30s")
def count_categories() -> int:
    return _exact_count("categories")


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
    count_categories.clear()


def update_category(category_id: str, fields: dict) -> None:
    sb = get_supabase()
    sb.table("categories").update(fields).eq("id", category_id).execute()
    fetch_categories.clear()


def delete_category(category_id: str) -> None:
    sb = get_supabase()
    sb.table("categories").delete().eq("id", category_id).execute()
    fetch_categories.clear()
    count_categories.clear()


# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------
@st.cache_data(ttl="30s")
def count_products(*, is_weekly_offer: bool | None = None, is_app_exclusive: bool | None = None) -> int:
    filters: dict[str, bool] = {}
    if is_weekly_offer is not None:
        filters["is_weekly_offer"] = is_weekly_offer
    if is_app_exclusive is not None:
        filters["is_app_exclusive"] = is_app_exclusive
    return _exact_count("products", filters or None)


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
    count_products.clear()


def update_product(product_id: str, fields: dict) -> None:
    sb = get_supabase()
    sb.table("products").update(fields).eq("id", product_id).execute()
    fetch_products.clear()
    # Cheap and correct either way: a plain price/name edit doesn't change
    # any count, but a weekly-offer/exclusive flag toggle does, and this
    # function doesn't know which `fields` changed.
    count_products.clear()


def delete_product(product_id: str) -> None:
    sb = get_supabase()
    sb.table("products").delete().eq("id", product_id).execute()
    fetch_products.clear()
    count_products.clear()


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
def count_orders(*, statuses: tuple[str, ...] | None = None) -> int:
    sb = get_supabase()
    query = sb.table("orders").select("id", count="exact").limit(1)
    if statuses:
        query = query.in_("status", list(statuses))
    res = query.execute()
    return res.count or 0


@st.cache_data(ttl="20s")
def fetch_orders() -> list[dict]:
    sb = get_supabase()
    try:
        res = (
            sb.table("orders")
            .select(
                "id, status, subtotal, delivery_fee, discount_amount, total_price, "
                "delivery_address, payment_method, notes, created_at, user_id, "
                "customer_id, customer_name, customer_phone, zone_id, delivery_lat, delivery_lng, "
                "delivery_zones(name_ar), profiles(full_name, phone_number)"
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
    count_orders.clear()


# ---------------------------------------------------------------------------
# Customers & analytics (backend supabase/008_guest_checkout_customers.sql)
#
# Aggregated in SQL, never by summing fetched rows: PostgREST caps any
# response at ~1000 rows, so a client-side sum would silently undercount once
# order volume grows (the same trap the product counts above fell into).
# "Sales" exclude cancelled orders. Timestamps go in as ISO strings so these
# functions stay cacheable.
# ---------------------------------------------------------------------------
_MIGRATION_HINT = (
    "يبدو أن ملف الترحيل `supabase/008_guest_checkout_customers.sql` "
    "لم يُطبَّق بعد على Supabase — شغّله من SQL Editor ثم أعد تحميل الصفحة."
)


def _is_missing_object(exc: Exception) -> bool:
    text = str(exc)
    return any(
        marker in text
        for marker in ("PGRST202", "PGRST205", "Could not find the function", "Could not find the table", "does not exist")
    )


def _rpc_rows(function: str, params: dict) -> list[dict]:
    sb = get_supabase()
    try:
        res = sb.rpc(function, params).execute()
    except Exception as exc:
        st.error(_MIGRATION_HINT if _is_missing_object(exc) else f"تعذر تحميل التحليلات: {exc}")
        return []
    return res.data or []


@st.cache_data(ttl="30s")
def fetch_order_insights(start_iso: str, end_iso: str) -> dict:
    """orders_count, total_sales, avg_order_value, cancelled_count,
    unique_customers for ``[start, end)``; ``{}`` if unavailable."""
    rows = _rpc_rows("admin_order_insights", {"p_from": start_iso, "p_to": end_iso})
    return rows[0] if rows else {}


@st.cache_data(ttl="30s")
def fetch_top_products(start_iso: str, end_iso: str, limit: int = 20) -> list[dict]:
    """Best-selling products by units sold: product_id, name_ar, name, sku,
    units_sold, revenue, orders_count."""
    return _rpc_rows("admin_top_products", {"p_from": start_iso, "p_to": end_iso, "p_limit": limit})


@st.cache_data(ttl="30s")
def fetch_top_zones(start_iso: str, end_iso: str, limit: int = 10) -> list[dict]:
    """Delivery zones by order count: zone_id, zone_name_ar, orders_count,
    sales. Orders with no zone appear with a null name."""
    return _rpc_rows("admin_top_zones", {"p_from": start_iso, "p_to": end_iso, "p_limit": limit})


@st.cache_data(ttl="30s")
def fetch_sales_by_day(start_iso: str, end_iso: str) -> list[dict]:
    """One row per Amman calendar day with orders: day, orders_count, sales."""
    return _rpc_rows("admin_sales_by_day", {"p_from": start_iso, "p_to": end_iso})


@st.cache_data(ttl="30s")
def fetch_customer_stats() -> list[dict]:
    """Every customer with orders_count, total_spend (cancelled excluded),
    first/last order time. Paged, because there can be more than the
    ~1000-row response cap."""
    sb = get_supabase()
    rows: list[dict] = []
    page_size = 1000
    start = 0
    try:
        while True:
            res = (
                sb.table("admin_customer_stats")
                .select("*")
                .order("total_spend", desc=True)
                .order("customer_id")
                .range(start, start + page_size - 1)
                .execute()
            )
            batch = res.data or []
            rows.extend(batch)
            if len(batch) < page_size:
                break
            start += page_size
    except Exception as exc:
        st.error(_MIGRATION_HINT if _is_missing_object(exc) else f"تعذر تحميل العملاء: {exc}")
        return []
    return rows


@st.cache_data(ttl="20s")
def fetch_customer_orders(customer_id: str) -> list[dict]:
    """One customer's order history, newest first."""
    sb = get_supabase()
    try:
        res = (
            sb.table("orders")
            .select(
                "id, status, subtotal, delivery_fee, total_price, delivery_address, "
                "payment_method, notes, created_at, customer_name, customer_phone, "
                "delivery_zones(name_ar)"
            )
            .eq("customer_id", customer_id)
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        st.error(f"تعذر تحميل طلبات العميل: {exc}")
        return []
    return res.data or []


# ---------------------------------------------------------------------------
# Driver location (backend supabase/010_driver_tracking.sql)
#
# Moving the driver writes order_driver_locations and the database broadcasts
# the new position to the customer's tracking map over Realtime. Only valid
# while the order is "out for delivery".
# ---------------------------------------------------------------------------
_DRIVER_MIGRATION_HINT = (
    "يبدو أن ملف الترحيل `supabase/010_driver_tracking.sql` "
    "لم يُطبَّق بعد على Supabase — شغّله من SQL Editor ثم أعد تحميل الصفحة."
)

_DRIVER_ERRORS_AR = {
    "not_out_for_delivery": "لا يمكن تحديد موقع السائق إلا عندما تكون حالة الطلب «خرج للتوصيل».",
    "invalid_location": "إحداثيات غير صحيحة — خط العرض بين -90 و90، وخط الطول بين -180 و180.",
    "order_not_found": "لم يُعثر على الطلب.",
}


def driver_error_message(exc: Exception) -> str:
    """Arabic explanation for a failed driver-location call."""
    text = str(exc)
    for code, message in _DRIVER_ERRORS_AR.items():
        if code in text:
            return message
    if _is_missing_object(exc):
        return _DRIVER_MIGRATION_HINT
    return f"تعذر تحديث موقع السائق: {exc}"


def set_driver_location(order_id: str, latitude: float, longitude: float) -> None:
    """Move the driver. Raises on failure (use :func:`driver_error_message`)."""
    sb = get_supabase()
    sb.rpc(
        "set_driver_location",
        {"p_order_id": order_id, "p_latitude": latitude, "p_longitude": longitude},
    ).execute()
    fetch_driver_location.clear()


@st.cache_data(ttl="5s")
def fetch_driver_location(order_id: str) -> dict | None:
    """The driver's last position for an order (latitude, longitude, updated_at),
    or None if none has been sent (or 010 isn't applied yet)."""
    sb = get_supabase()
    try:
        res = (
            sb.table("order_driver_locations")
            .select("latitude, longitude, updated_at")
            .eq("order_id", order_id)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        st.error(_DRIVER_MIGRATION_HINT if _is_missing_object(exc) else f"تعذر تحميل موقع السائق: {exc}")
        return None
    rows = res.data or []
    return rows[0] if rows else None


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
