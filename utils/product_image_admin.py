"""The "صور المنتجات" page: add pictures to products one by one or in bulk.

Products without a picture show their category's picture in the app, so this is about filling in the
products that matter most first: the page lists best sellers that still have none, lets you search any
product by name or SKU, and takes a whole folder of pictures named after the SKU.
"""

from __future__ import annotations

import streamlit as st

import utils.db as db
from utils.images import MAX_UPLOAD_BYTES, MIN_SIDE, ImageRejected, prepare_product_image
from utils.insights import PERIOD_LABELS_AR, period_range
from utils.product_images import plan_uploads, sku_from_filename

BULK_LIMIT = 50  # files handled per click: each is processed and uploaded one by one


def _label(product: dict) -> str:
    name = product.get("name_ar") or product.get("name") or "—"
    return f"{name} — {product['sku']}" if product.get("sku") else name


def _status(product: dict) -> str:
    if product.get("image_path"):
        return "صورة مرفوعة من لوحة التحكم"
    if product.get("image_url"):
        return "صورة من رابط"
    return "بلا صورة — يظهر في التطبيق بصورة قسمه"


def render_product_image_panel(product: dict, key: str) -> None:
    """Upload / link / remove for one product."""
    pid, old_path, image_url = product["id"], product.get("image_path"), product.get("image_url")
    version_key = f"{key}_version"
    version = st.session_state.get(version_key, 0)

    st.markdown(f"**{_label(product)}**")
    preview_col, controls_col = st.columns([1, 2])
    with preview_col:
        if image_url:
            st.image(image_url, width=150)
        st.caption(_status(product))
    with controls_col:
        uploaded = st.file_uploader(
            f"رفع صورة (PNG أو JPG أو WebP، حتى {MAX_UPLOAD_BYTES // (1024 * 1024)} ميغابايت)",
            type=["png", "jpg", "jpeg", "webp"],
            key=f"{key}_upload_{version}",
            help=f"تظهر الصورة كاملة على خلفية بيضاء دون قص، بحجم أقصاه 600×600. الحد الأدنى {MIN_SIDE} بكسل.",
        )
        if uploaded is not None:
            try:
                prepared = prepare_product_image(uploaded.getvalue())
            except ImageRejected as exc:
                st.error(exc.message)
            else:
                st.image(prepared.data, width=150, caption=f"هكذا ستظهر ({prepared.size}×{prepared.size})")
                if st.button("حفظ الصورة", type="primary", icon=":material/cloud_upload:", key=f"{key}_save"):
                    try:
                        db.upload_product_image(pid, prepared.data, prepared.content_type, old_path)
                    except Exception as exc:
                        st.error(f"تعذر رفع الصورة: {exc}")
                    else:
                        st.session_state[version_key] = version + 1
                        st.toast("تم حفظ صورة المنتج.", icon=":material/check_circle:")
                        st.rerun()

        with st.expander("أو استخدم رابط صورة"):
            link = st.text_input("رابط الصورة (https)", placeholder="https://…", key=f"{key}_link", label_visibility="collapsed")
            if st.button("استخدام الرابط", icon=":material/link:", key=f"{key}_use_link"):
                if not db.is_valid_image_link(link):
                    st.error("الرابط غير صالح — يجب أن يبدأ بـ https:// ويشير إلى صورة.")
                else:
                    try:
                        db.set_product_image_link(pid, link, old_path)
                    except Exception as exc:
                        st.error(f"تعذر حفظ الرابط: {exc}")
                    else:
                        st.toast("تم تحديث صورة المنتج.", icon=":material/check_circle:")
                        st.rerun()

        if image_url and st.button("حذف الصورة", icon=":material/delete:", key=f"{key}_remove"):
            try:
                db.remove_product_image(pid, old_path)
            except Exception as exc:
                st.error(f"تعذر حذف الصورة: {exc}")
            else:
                st.toast("تم حذف صورة المنتج.", icon=":material/check_circle:")
                st.rerun()


def _pick_and_edit(products: list[dict], key: str) -> None:
    if not products:
        return
    by_id = {p["id"]: p for p in products}
    chosen = st.selectbox("اختر المنتج", list(by_id), format_func=lambda i: _label(by_id[i]), key=f"{key}_pick")
    with st.container(border=True):
        render_product_image_panel(by_id[chosen], key=f"{key}_{chosen}")


def _tab_top_sellers() -> None:
    labels = {k: v for k, v in PERIOD_LABELS_AR.items() if k != "custom"}
    chosen = st.segmented_control("الفترة", list(labels.values()), default=labels["month"], key="pimg_period")
    period = next((k for k, v in labels.items() if v == chosen), "month")
    start, end = period_range(period)
    top = db.fetch_top_products(start.isoformat(), end.isoformat(), 100)
    if not top:
        st.info("لا توجد مبيعات في هذه الفترة بعد — استخدم تبويب «بحث» لاختيار المنتجات التي تريدها.")
        return
    products = {p["id"]: p for p in db.fetch_products_by_ids([t["product_id"] for t in top])}
    missing = [(t, products[t["product_id"]]) for t in top if t["product_id"] in products and not products[t["product_id"]].get("image_url")]
    st.caption(f"{len(missing)} من أصل {len(top)} منتجاً من الأكثر مبيعاً بلا صورة (الأكثر مبيعاً أولاً).")
    if not missing:
        st.success("كل المنتجات الأكثر مبيعاً لها صور.")
        return
    st.dataframe(
        [{"المنتج": _label(p), "الوحدات المباعة": int(t["units_sold"]), "عدد الطلبات": int(t["orders_count"])} for t, p in missing],
        hide_index=True,
    )
    _pick_and_edit([p for _, p in missing], "pimg_top")


def _tab_search() -> None:
    term = st.text_input("ابحث بالاسم أو برمز المنتج (SKU)", key="pimg_search")
    if len((term or "").strip()) < 2:
        st.caption("اكتب حرفين على الأقل.")
        return
    results = db.find_products(term)
    if not results:
        st.info("لا توجد نتائج.")
        return
    st.caption(f"{len(results)} نتيجة" + (" (أول 30)" if len(results) >= 30 else ""))
    _pick_and_edit(results, "pimg_search_res")


def _tab_bulk() -> None:
    st.markdown(
        "ارفع عدة صور دفعة واحدة، **وليكن اسم كل ملف هو رمز المنتج (SKU)** — مثال: `6281001234567.jpg`. "
        f"تُعالَج حتى {BULK_LIMIT} صورة في كل مرة."
    )
    version = st.session_state.get("pimg_bulk_version", 0)
    files = st.file_uploader(
        "الصور", type=["png", "jpg", "jpeg", "webp"], accept_multiple_files=True, key=f"pimg_bulk_upload_{version}"
    )
    replace = st.checkbox("استبدال صور المنتجات التي لها صورة بالفعل", key="pimg_bulk_replace")
    if not files:
        return

    batch = files[:BULK_LIMIT]
    if len(files) > BULK_LIMIT:
        st.warning(f"اخترت {len(files)} ملفاً — سيُعالَج أول {BULK_LIMIT} فقط الآن، ثم ارفع الباقي.")
    skus = sorted({sku_from_filename(f.name) for f in batch} - {""})
    products_by_sku = {p["sku"]: p for p in db.fetch_products_by_skus(skus) if p.get("sku")}
    plan = plan_uploads([f.name for f in batch], products_by_sku, replace_existing=replace)
    data_by_name = {f.name: f for f in batch}

    st.dataframe(
        [{"الملف": r.filename, "المنتج": _label(r.product) if r.product else "—", "الحالة": r.label} for r in plan],
        hide_index=True,
    )
    to_save = [r for r in plan if r.will_save]
    st.caption(f"{len(to_save)} صورة ستُحفظ، و{len(plan) - len(to_save)} ستُترك.")
    if not to_save or not st.button(f"حفظ {len(to_save)} صورة", type="primary", icon=":material/cloud_upload:", key="pimg_bulk_save"):
        return

    saved, failed = 0, []
    progress = st.progress(0.0)
    for n, row in enumerate(to_save, start=1):
        try:
            prepared = prepare_product_image(data_by_name[row.filename].getvalue())
            db.upload_product_image(row.product["id"], prepared.data, prepared.content_type, row.product.get("image_path"))
            saved += 1
        except ImageRejected as exc:
            failed.append((row.filename, exc.message))
        except Exception as exc:
            failed.append((row.filename, f"تعذر الرفع: {exc}"))
        progress.progress(n / len(to_save))
    st.session_state["pimg_bulk_version"] = version + 1
    st.session_state["pimg_bulk_result"] = (saved, failed)
    st.rerun()


def render_product_images_page() -> None:
    st.caption("المنتجات التي لا صورة لها تظهر في التطبيق بصورة قسمها. أضف صوراً للمنتجات الأكثر مبيعاً أولاً.")

    total, with_image = db.count_products(), db.count_products_with_image()
    with st.container(horizontal=True):
        st.metric("المنتجات", f"{total:,}", border=True)
        st.metric("لها صورة", f"{with_image:,}", f"{(with_image / total * 100 if total else 0):.1f}%", border=True)
        st.metric("بلا صورة", f"{max(total - with_image, 0):,}", border=True)

    result = st.session_state.pop("pimg_bulk_result", None)
    if result:
        saved, failed = result
        if saved:
            st.success(f"تم حفظ {saved} صورة.")
        for name, why in failed:
            st.error(f"{name}: {why}")

    top, search, bulk = st.tabs(["الأكثر مبيعاً بلا صور", "بحث ورفع", "رفع جماعي"])
    with top:
        _tab_top_sellers()
    with search:
        _tab_search()
    with bulk:
        _tab_bulk()
