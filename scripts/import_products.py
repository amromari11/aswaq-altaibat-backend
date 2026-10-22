"""Bulk-import the POS product export into Supabase.

Source: aswaq-altaibat-app/assets/names of product/طيبات.xlsx — a point-of-
sale catalog export (8 columns: tax amount, tax rate, sale price, قسم,
نوع, فئة, item description, item/barcode number). Only فئة (category),
الوصف (name), سعر البيع (price), and رقم المادة (sku) map onto our schema;
the tax columns and قسم/نوع aren't modeled and are intentionally dropped.

What this does, in order:
1. Parses every row, dropping the export's junk rows (blank/zero-price
   placeholders, an explicit "حذف" / delete marker, and the trailing
   metadata row the export tool appends).
2. Resolves each row's فئة value to a categories.id — reusing an existing
   category if one already has that exact name, creating it otherwise.
   Rows with a blank فئة go into a "غير مصنف" (Uncategorized) fallback
   category created for this purpose.
3. Upserts every product by sku (on_conflict=sku), so re-running this
   script is safe and just refreshes prices/names rather than duplicating
   rows. Rows with no usable sku always insert fresh — see NOTE below.
4. Prints a summary, and writes scripts/jod_precision_corrections.json
   listing every sku whose true price needed 3 decimal places (JOD fils)
   but got rounded, because the live `products.price` column is still
   numeric(10,2) — supabase/004_jod_precision.sql exists but was never
   actually applied (confirmed by a live test insert during this run).
   Apply that migration, then use the JSON file to correct just those
   rows' prices.

NOTE: `_clean_sku` nulls out skus that contain Arabic text (export
metadata, not a real barcode) — none of the current rows actually hit
that case (every row has a numeric-looking sku, even if it's a
placeholder like "00000"), but if a future export does, those rows would
insert as new on every run instead of upserting. Worth knowing if this
script is ever re-run on a different export.

Credentials: reads SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from
.streamlit/secrets.toml (the same file the admin dashboard uses) — never
hardcode them here, and this script never prints their values.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import openpyxl
import requests
import toml

BACKEND_ROOT = Path(__file__).resolve().parent.parent
SECRETS_PATH = BACKEND_ROOT / ".streamlit" / "secrets.toml"
XLSX_PATH = (
    BACKEND_ROOT.parent
    / "aswaq-altaibat-app"
    / "assets"
    / "names of product"
    / "طيبات.xlsx"
)
PRECISION_REPORT_PATH = BACKEND_ROOT / "scripts" / "jod_precision_corrections.json"

FALLBACK_CATEGORY_NAME = "غير مصنف"
BATCH_SIZE = 500


def load_credentials() -> tuple[str, dict]:
    secrets = toml.load(SECRETS_PATH)
    url = secrets["SUPABASE_URL"].strip()
    key = secrets["SUPABASE_SERVICE_ROLE_KEY"].strip()
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    return url, headers


def _clean_sku(raw_sku: object) -> str | None:
    if not raw_sku:
        return None
    cleaned = str(raw_sku).replace("‌", "").strip()
    if not cleaned:
        return None
    if any("؀" <= ch <= "ۿ" for ch in cleaned):
        return None  # Arabic text in this field means it's not a real barcode.
    return cleaned


def parse_rows() -> list[dict]:
    wb = openpyxl.load_workbook(XLSX_PATH, data_only=True, read_only=True)
    ws = wb["Sheet1"]
    rows = ws.iter_rows(values_only=True)
    next(rows)  # header row

    parsed = []
    for row in rows:
        if len(row) < 8:
            continue
        _tax_amount, _tax_rate, price, _qism, _naw, fiah, desc, sku = row[:8]

        desc = str(desc).strip() if desc else ""
        if not desc or desc == "حذف":
            continue

        try:
            price = float(price)
        except (TypeError, ValueError):
            continue
        if price <= 0:
            continue

        category_name = (str(fiah).strip() if fiah else "") or FALLBACK_CATEGORY_NAME

        parsed.append(
            {
                "name": desc,
                "name_ar": desc,
                "price": price,
                "sku": _clean_sku(sku),
                "category_name": category_name,
            }
        )
    return parsed


def resolve_categories(url: str, headers: dict, category_names: set[str]) -> dict[str, str]:
    existing = requests.get(
        f"{url}/rest/v1/categories?select=id,name", headers=headers, timeout=30
    ).json()
    name_to_id = {row["name"]: row["id"] for row in existing}

    missing = sorted(category_names - set(name_to_id))
    for i in range(0, len(missing), BATCH_SIZE):
        chunk = missing[i : i + BATCH_SIZE]
        payload = [{"name": name, "name_ar": name, "is_active": True} for name in chunk]
        resp = requests.post(
            f"{url}/rest/v1/categories",
            headers={**headers, "Prefer": "return=representation"},
            json=payload,
            timeout=60,
        )
        resp.raise_for_status()
        for row in resp.json():
            name_to_id[row["name"]] = row["id"]

    return name_to_id


def upsert_products(url: str, headers: dict, products: list[dict]) -> None:
    upsert_headers = {**headers, "Prefer": "resolution=merge-duplicates,return=minimal"}
    total = len(products)
    for i in range(0, total, BATCH_SIZE):
        chunk = products[i : i + BATCH_SIZE]
        resp = requests.post(
            f"{url}/rest/v1/products?on_conflict=sku",
            headers=upsert_headers,
            json=chunk,
            timeout=120,
        )
        if resp.status_code >= 300:
            print(f"Batch {i}-{i + len(chunk)} failed: {resp.status_code} {resp.text[:800]}", file=sys.stderr)
            resp.raise_for_status()
        print(f"  upserted {min(i + BATCH_SIZE, total)}/{total}")


def main() -> None:
    url, headers = load_credentials()

    print(f"Parsing {XLSX_PATH.name}...")
    parsed = parse_rows()
    print(f"Parsed {len(parsed)} valid product rows (junk/footer rows dropped).")

    precision_loss = [
        {"sku": p["sku"], "name_ar": p["name_ar"], "exact_price": p["price"]}
        for p in parsed
        if round(p["price"], 2) != round(p["price"], 3)
    ]

    category_names = {p["category_name"] for p in parsed}
    print(f"Resolving {len(category_names)} distinct category names...")
    name_to_id = resolve_categories(url, headers, category_names)
    print(f"Categories ready ({len(name_to_id)} total in DB, including pre-existing ones).")

    products_payload = [
        {
            "name": p["name"],
            "name_ar": p["name_ar"],
            "price": p["price"],
            "sku": p["sku"],
            "category_id": name_to_id[p["category_name"]],
        }
        for p in parsed
    ]

    print(f"Upserting {len(products_payload)} products in batches of {BATCH_SIZE}...")
    upsert_products(url, headers, products_payload)

    if precision_loss:
        PRECISION_REPORT_PATH.write_text(json.dumps(precision_loss, ensure_ascii=False, indent=2))
        print(
            f"\n{len(precision_loss)} products have true 3-decimal JOD pricing that the live "
            f"`products.price` column (still numeric(10,2)) rounded. Exact intended prices "
            f"saved to {PRECISION_REPORT_PATH.relative_to(BACKEND_ROOT)} — apply "
            f"supabase/004_jod_precision.sql, then re-run the correction pass from that file."
        )

    print("\nDone.")


if __name__ == "__main__":
    main()
