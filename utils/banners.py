"""Pure rules for the Banners page: what a banner may point at, and how reordering works."""

from __future__ import annotations

import re
from urllib.parse import urlparse

TARGET_LABELS: dict[str, str] = {
    "none": "بدون رابط (للعرض فقط)",
    "category": "قسم",
    "product": "منتج",
    "link": "رابط خارجي",
}

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)


def validate_target(target_type: str, target_id: str | None) -> str | None:
    """Arabic error text if the target is unusable, else None (mirrors the table's CHECK constraint)."""
    target_id = (target_id or "").strip()
    if target_type == "none":
        return None
    if target_type == "category":
        return None if _UUID.match(target_id) else "اختر القسم الذي سيفتحه البانر."
    if target_type == "product":
        return None if _UUID.match(target_id) else "ابحث عن المنتج ثم اختره من القائمة."
    if target_type == "link":
        parsed = urlparse(target_id)
        ok = parsed.scheme == "https" and bool(parsed.netloc) and not re.search(r"\s", target_id) and len(target_id) <= 2000
        return None if ok else "الرابط غير صالح — يجب أن يبدأ بـ https://"
    return "نوع الوجهة غير معروف."


def clean_target(target_type: str, target_id: str | None) -> str | None:
    """The value to store: None for 'none', otherwise the trimmed id / link."""
    return None if target_type == "none" else (target_id or "").strip()


def move(ordered_ids: list[str], banner_id: str, delta: int) -> list[tuple[str, int]]:
    """New ``(id, display_order)`` pairs after moving ``banner_id`` up (-1) or down (+1) in ``ordered_ids``.

    Every banner is renumbered 1..n so ties (all banners starting at 0) can't make a move a no-op.
    Moving past either end returns an empty list (nothing to write).
    """
    ids = list(ordered_ids)
    i = ids.index(banner_id)
    j = i + delta
    if not 0 <= j < len(ids):
        return []
    ids[i], ids[j] = ids[j], ids[i]
    return [(bid, n) for n, bid in enumerate(ids, start=1)]
