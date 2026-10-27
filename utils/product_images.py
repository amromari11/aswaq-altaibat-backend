"""Pure rules for bulk product pictures: which uploaded file belongs to which product."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePath

# status -> (Arabic label, will it be saved?)
STATUS_LABELS: dict[str, str] = {
    "save": "جديدة — ستُحفظ",
    "replace": "ستستبدل الصورة الحالية",
    "skip_has_image": "للمنتج صورة بالفعل — تُركت",
    "unknown_sku": "لا يوجد منتج بهذا الرمز",
    "duplicate": "الرمز مكرر في الملفات — تُركت",
}
SAVED_STATUSES = frozenset({"save", "replace"})


@dataclass(frozen=True)
class PlanRow:
    filename: str
    sku: str
    status: str
    product: dict | None = None

    @property
    def will_save(self) -> bool:
        return self.status in SAVED_STATUSES

    @property
    def label(self) -> str:
        return STATUS_LABELS[self.status]


def sku_from_filename(filename: str) -> str:
    """``6281001234567.jpg`` -> ``6281001234567`` (the file name without its extension, trimmed)."""
    return PurePath(filename or "").stem.strip()


def plan_uploads(filenames: list[str], products_by_sku: dict[str, dict], *, replace_existing: bool) -> list[PlanRow]:
    """Decide what to do with each uploaded file, in the order given.

    The file name (without extension) is the product's SKU. A SKU that appears twice in one batch keeps
    its first file; a product that already has a picture is left alone unless ``replace_existing``.
    """
    seen: set[str] = set()
    rows: list[PlanRow] = []
    for name in filenames:
        sku = sku_from_filename(name)
        product = products_by_sku.get(sku)
        if product is None:
            rows.append(PlanRow(name, sku, "unknown_sku"))
        elif sku in seen:
            rows.append(PlanRow(name, sku, "duplicate", product))
        else:
            seen.add(sku)
            if product.get("image_url") and not replace_existing:
                rows.append(PlanRow(name, sku, "skip_has_image", product))
            else:
                rows.append(PlanRow(name, sku, "replace" if product.get("image_url") else "save", product))
    return rows
