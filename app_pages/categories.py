"""الأقسام — categories management."""

import pandas as pd
import streamlit as st

from utils.category_image_panel import render_category_image_panel
from utils.db import delete_category, fetch_categories, insert_category, update_category

st.caption("إضافة أقسام الكتالوج وتعديلها ورفع صورة لكل قسم (تظهر في بطاقات الأقسام بالتطبيق)")

with st.form("new_category", clear_on_submit=True, border=True):
    st.subheader("إضافة قسم جديد")
    col_a, col_b = st.columns(2)
    name_ar = col_a.text_input("الاسم بالعربية", placeholder="مثال: الألبان")
    name_en = col_b.text_input("الاسم بالإنجليزية", placeholder="e.g. Dairy")
    submitted = st.form_submit_button("حفظ القسم", type="primary", icon=":material/add:")

if submitted:
    clean_ar = (name_ar or "").strip()
    clean_en = (name_en or "").strip()
    if not clean_ar:
        st.error("الرجاء إدخال اسم القسم بالعربية.")
    else:
        try:
            insert_category(clean_en or clean_ar, clean_ar)
            st.success(f"تمت إضافة القسم «{clean_ar}».")
            st.rerun()
        except Exception as exc:
            st.error(f"تعذر حفظ القسم: {exc}")

st.divider()
st.subheader("الأقسام الحالية")
categories = fetch_categories()

if not categories:
    st.info("لا توجد أقسام بعد. أضف أول قسم من النموذج أعلاه.")
else:
    df = pd.DataFrame(
        [
            {
                "الصورة": c.get("image_url"),
                "الاسم": c.get("name_ar") or c.get("name") or "",
                "الترتيب": int(c.get("display_order") or 0),
                "مفعّل": bool(c.get("is_active")),
            }
            for c in categories
        ]
    )

    event = st.dataframe(
        df,
        hide_index=True,
        column_config={"الصورة": st.column_config.ImageColumn("الصورة", width="small")},
        on_select="rerun",
        selection_mode="single-row",
        alt="قائمة الأقسام",
        key="categories_table",
    )

    selected_rows = event.selection.rows
    if selected_rows:
        category = categories[selected_rows[0]]
        with st.container(border=True):
            st.markdown(f"**تعديل: {category.get('name_ar') or category.get('name')}**")
            edit_col1, edit_col2 = st.columns(2)
            edit_name_ar = edit_col1.text_input(
                "الاسم بالعربية", value=category.get("name_ar") or "", key=f"cat_ar_{category['id']}"
            )
            edit_name_en = edit_col2.text_input(
                "الاسم بالإنجليزية", value=category.get("name") or "", key=f"cat_en_{category['id']}"
            )
            order_col, active_col = st.columns(2)
            display_order = order_col.number_input(
                "ترتيب العرض",
                min_value=0,
                step=1,
                value=int(category.get("display_order") or 0),
                help="الأصغر يظهر أولاً في التطبيق. عند التساوي يُرتَّب بالاسم.",
                key=f"cat_order_{category['id']}",
            )
            is_active = active_col.checkbox(
                "مفعّل", value=bool(category.get("is_active")), key=f"cat_active_{category['id']}"
            )

            st.divider()
            render_category_image_panel(category)
            st.divider()

            with st.container(horizontal=True, horizontal_alignment="right"):
                if st.button(
                    "حفظ التعديلات", type="primary", icon=":material/save:", key=f"cat_save_{category['id']}"
                ):
                    try:
                        update_category(
                            category["id"],
                            {
                                "name_ar": edit_name_ar.strip(),
                                "name": edit_name_en.strip() or edit_name_ar.strip(),
                                "is_active": is_active,
                                "display_order": int(display_order),
                            },
                        )
                        st.toast("تم حفظ التعديلات.", icon=":material/check_circle:")
                        st.rerun()
                    except Exception as exc:
                        st.error(f"تعذر حفظ التعديلات: {exc}")
                if st.button("حذف القسم", icon=":material/delete:", key=f"cat_delete_{category['id']}"):
                    try:
                        delete_category(category["id"])
                        st.toast("تم حذف القسم.", icon=":material/check_circle:")
                        st.rerun()
                    except Exception as exc:
                        st.error(f"تعذر حذف القسم — تأكد من عدم وجود منتجات مرتبطة به: {exc}")
