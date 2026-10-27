"""Admin panel for a category's picture: upload, use a link, or remove.

Shown inside the category editor on the Categories page. An upload is validated and
re-encoded by ``utils.images`` (square, 600 px, WebP), previewed *before* saving, and
stored in the public ``category-images`` bucket; the customer app picks it up on its
next load. Categories ship with placeholder photos (migration 011) that this replaces.
"""

from __future__ import annotations

import streamlit as st

import utils.db as db
from utils.images import MAX_UPLOAD_BYTES, MIN_SIDE, ImageRejected, prepare_category_image


def _source_label(category: dict) -> str:
    if category.get("image_path"):
        return "صورة مرفوعة من لوحة التحكم"
    if category.get("image_url"):
        return "صورة مؤقتة أو رابط خارجي"
    return "لا توجد صورة — يظهر رمز افتراضي في التطبيق"


def render_category_image_panel(category: dict) -> None:
    category_id = category["id"]
    old_path = category.get("image_path")
    image_url = category.get("image_url")

    # Bumping this resets the file picker after a save (a file_uploader keeps its file across reruns).
    version_key = f"cat_img_version_{category_id}"
    version = st.session_state.get(version_key, 0)

    st.markdown("**صورة القسم**")
    preview_col, controls_col = st.columns([1, 2])

    with preview_col:
        if image_url:
            st.image(image_url, width=150)
        st.caption(_source_label(category))

    with controls_col:
        uploaded = st.file_uploader(
            f"رفع صورة جديدة (PNG أو JPG أو WebP، حتى {MAX_UPLOAD_BYTES // (1024 * 1024)} ميغابايت)",
            type=["png", "jpg", "jpeg", "webp"],
            key=f"cat_img_upload_{category_id}_{version}",
            help=f"تُقصّ الصورة تلقائياً إلى مربع وتُحوَّل إلى WebP بحجم 600×600. الحد الأدنى {MIN_SIDE}×{MIN_SIDE} بكسل.",
        )

        if uploaded is not None:
            try:
                prepared = prepare_category_image(uploaded.getvalue())
            except ImageRejected as exc:
                st.error(exc.message)
            else:
                st.image(
                    prepared.data,
                    width=150,
                    caption=f"هكذا ستظهر ({prepared.size}×{prepared.size}، {len(prepared.data) // 1024} ك.ب)",
                )
                if st.button("حفظ الصورة", type="primary", icon=":material/cloud_upload:", key=f"cat_img_save_{category_id}"):
                    try:
                        db.upload_category_image(category_id, prepared.data, prepared.content_type, old_path)
                    except Exception as exc:
                        st.error(f"تعذر رفع الصورة: {exc}")
                    else:
                        st.session_state[version_key] = version + 1
                        st.toast("تم حفظ صورة القسم.", icon=":material/check_circle:")
                        st.rerun()

        with st.expander("أو استخدم رابط صورة"):
            link = st.text_input(
                "رابط الصورة (https)", placeholder="https://…", key=f"cat_img_link_{category_id}", label_visibility="collapsed"
            )
            if st.button("استخدام الرابط", icon=":material/link:", key=f"cat_img_use_link_{category_id}"):
                if not db.is_valid_image_link(link):
                    st.error("الرابط غير صالح — يجب أن يبدأ بـ https:// ويشير إلى صورة.")
                else:
                    try:
                        db.set_category_image_link(category_id, link, old_path)
                    except Exception as exc:
                        st.error(f"تعذر حفظ الرابط: {exc}")
                    else:
                        st.toast("تم تحديث صورة القسم.", icon=":material/check_circle:")
                        st.rerun()

        if image_url and st.button("حذف الصورة", icon=":material/delete:", key=f"cat_img_remove_{category_id}"):
            try:
                db.remove_category_image(category_id, old_path)
            except Exception as exc:
                st.error(f"تعذر حذف الصورة: {exc}")
            else:
                st.toast("تم حذف صورة القسم.", icon=":material/check_circle:")
                st.rerun()
