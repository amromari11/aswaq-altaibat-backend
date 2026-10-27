"""The Banners page: list, add, edit, reorder, show/hide and delete Home-carousel banners.

Kept out of ``app_pages/banners.py`` so it can be run headlessly in tests. Pictures go through
``utils.images.prepare_banner_image`` (wide crop, WebP) and are previewed before saving.
"""

from __future__ import annotations

import streamlit as st

import utils.db as db
from utils.banners import TARGET_LABELS, clean_target, move, validate_target
from utils.images import MAX_UPLOAD_BYTES, ImageRejected, prepare_banner_image


def _target_text(banner: dict, categories: dict[str, str]) -> str:
    kind, target = banner.get("target_type") or "none", banner.get("target_id")
    if kind == "category":
        return f"قسم: {categories.get(target, 'غير موجود')}"
    if kind == "product":
        return "منتج محدد"
    if kind == "link":
        return f"رابط: {target}"
    return "بدون رابط"


def _target_inputs(key: str, banner: dict | None, categories: dict[str, str]) -> tuple[str, str | None]:
    """The target-type picker and the matching id/link input; returns (type, value)."""
    banner = banner or {}
    current_type = banner.get("target_type") or "none"
    kinds = list(TARGET_LABELS)
    kind = st.selectbox(
        "عند الضغط على البانر",
        kinds,
        index=kinds.index(current_type) if current_type in kinds else 0,
        format_func=TARGET_LABELS.get,
        key=f"{key}_type",
    )
    current_id = banner.get("target_id") if current_type == kind else None

    if kind == "category":
        ids = list(categories)
        if not ids:
            st.warning("لا توجد أقسام مفعّلة.")
            return kind, None
        return kind, st.selectbox(
            "القسم",
            ids,
            index=ids.index(current_id) if current_id in ids else 0,
            format_func=categories.get,
            key=f"{key}_category",
        )
    if kind == "product":
        term = st.text_input("ابحث عن المنتج بالاسم", key=f"{key}_product_search")
        matches = db.search_products(term) if term else []
        labels = {p["id"]: p.get("name_ar") or p.get("name") or p["id"] for p in matches}
        if current_id and current_id not in labels:
            labels = {current_id: "المنتج الحالي (ابحث لتغييره)", **labels}
        if not labels:
            st.caption("اكتب حرفين على الأقل من اسم المنتج.")
            return kind, None
        ids = list(labels)
        return kind, st.selectbox("المنتج", ids, format_func=labels.get, key=f"{key}_product")
    if kind == "link":
        return kind, st.text_input("الرابط (https)", value=current_id or "", placeholder="https://…", key=f"{key}_link")
    return kind, None


def _banner_form(banner: dict | None, categories: dict[str, str], next_order: int) -> None:
    """Add (``banner`` is None) or edit form."""
    is_new = banner is None
    banner_id = None if is_new else banner["id"]
    key = f"banner_{banner_id or 'new'}"
    version_key = f"{key}_version"
    version = st.session_state.get(version_key, 0)

    title = st.text_input("العنوان (يظهر فوق الصورة)", value="" if is_new else banner.get("title") or "", key=f"{key}_title")
    uploaded = st.file_uploader(
        f"صورة البانر (PNG أو JPG أو WebP، حتى {MAX_UPLOAD_BYTES // (1024 * 1024)} ميغابايت)"
        + ("" if is_new else " — اتركها فارغة للإبقاء على الصورة الحالية"),
        type=["png", "jpg", "jpeg", "webp"],
        key=f"{key}_upload_{version}",
        help="تُقصّ الصورة تلقائياً بنسبة عريضة (حوالي 2.3:1) وتُحوَّل إلى WebP. يُفضَّل عرض 1200 بكسل أو أكثر.",
    )
    prepared = None
    if uploaded is not None:
        try:
            prepared = prepare_banner_image(uploaded.getvalue())
        except ImageRejected as exc:
            st.error(exc.message)
        else:
            st.image(prepared.data, caption=f"هكذا ستظهر ({prepared.size}×{prepared.height})")
    elif not is_new and banner.get("image_url"):
        st.image(banner["image_url"], width=320, caption="الصورة الحالية")

    kind, target = _target_inputs(key, banner, categories)
    active = st.checkbox("مفعّل (يظهر في التطبيق)", value=True if is_new else bool(banner.get("is_active")), key=f"{key}_active")

    if not st.button("إضافة البانر" if is_new else "حفظ التعديلات", type="primary", icon=":material/save:", key=f"{key}_save"):
        return
    if uploaded is not None and prepared is None:
        return  # the upload error is already on screen
    if is_new and prepared is None:
        st.error("الرجاء رفع صورة للبانر.")
        return
    problem = validate_target(kind, target)
    if problem:
        st.error(problem)
        return

    fields = {
        "title": title.strip() or None,
        "target_type": kind,
        "target_id": clean_target(kind, target),
        "is_active": active,
    }
    if is_new:
        fields["display_order"] = next_order
    try:
        db.save_banner(banner_id, fields, prepared.data if prepared else None, None if is_new else banner.get("image_path"))
    except Exception as exc:
        st.error(f"تعذر حفظ البانر: {exc}")
        return
    st.session_state[version_key] = version + 1
    st.toast("تم حفظ البانر.", icon=":material/check_circle:")
    st.rerun()


def _banner_row(banner: dict, index: int, ordered_ids: list[str], categories: dict[str, str]) -> None:
    bid = banner["id"]
    with st.container(border=True):
        thumb, info, controls = st.columns([2, 4, 3], vertical_alignment="center")
        with thumb:
            if banner.get("image_url"):
                st.image(banner["image_url"], width=180)
        with info:
            st.markdown(f"**{banner.get('title') or 'بدون عنوان'}**")
            st.caption(_target_text(banner, categories))
            st.caption("مفعّل ✅" if banner.get("is_active") else "مخفي ⏸")
        with controls:
            up, down, toggle, delete = st.columns(4)
            if up.button("", icon=":material/arrow_upward:", key=f"banner_up_{bid}", disabled=index == 0, help="تحريك للأعلى"):
                db.set_banner_orders(move(ordered_ids, bid, -1))
                st.rerun()
            if down.button(
                "", icon=":material/arrow_downward:", key=f"banner_down_{bid}", disabled=index == len(ordered_ids) - 1, help="تحريك للأسفل"
            ):
                db.set_banner_orders(move(ordered_ids, bid, +1))
                st.rerun()
            if toggle.button(
                "", icon=":material/visibility_off:" if banner.get("is_active") else ":material/visibility:",
                key=f"banner_toggle_{bid}", help="إخفاء" if banner.get("is_active") else "إظهار",
            ):
                db.set_banner_active(bid, not banner.get("is_active"))
                st.rerun()
            if delete.button("", icon=":material/delete:", key=f"banner_delete_{bid}", help="حذف"):
                st.session_state[f"banner_confirm_delete_{bid}"] = True
                st.rerun()

        if st.session_state.get(f"banner_confirm_delete_{bid}"):
            st.warning("حذف هذا البانر نهائياً؟")
            yes, no = st.columns(2)
            if yes.button("نعم، احذف", type="primary", key=f"banner_delete_yes_{bid}"):
                try:
                    db.delete_banner(bid, banner.get("image_path"))
                except Exception as exc:
                    st.error(f"تعذر حذف البانر: {exc}")
                else:
                    st.session_state.pop(f"banner_confirm_delete_{bid}", None)
                    st.toast("تم حذف البانر.", icon=":material/check_circle:")
                    st.rerun()
            if no.button("إلغاء", key=f"banner_delete_no_{bid}"):
                st.session_state.pop(f"banner_confirm_delete_{bid}", None)
                st.rerun()

        with st.expander("تعديل"):
            _banner_form(banner, categories, next_order=0)


def render_banners_page() -> None:
    st.caption("بانرات الشاشة الرئيسية في التطبيق: ارفع صورة، اختر ما يفتحه البانر، ورتّبها كما تريد.")
    banners = db.fetch_banners()
    categories = {c["id"]: c.get("name_ar") or c.get("name") or "" for c in db.fetch_categories() if c.get("is_active")}
    next_order = max((b.get("display_order") or 0 for b in banners), default=0) + 1

    with st.expander("إضافة بانر جديد", expanded=not banners, icon=":material/add_photo_alternate:"):
        _banner_form(None, categories, next_order)

    if not banners:
        st.info("لا توجد بانرات بعد — لن يظهر شريط العروض في التطبيق حتى تضيف واحداً.")
        return

    st.subheader(f"البانرات ({len(banners)})")
    ordered_ids = [b["id"] for b in banners]
    for i, banner in enumerate(banners):
        _banner_row(banner, i, ordered_ids, categories)
