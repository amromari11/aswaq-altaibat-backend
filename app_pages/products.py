"""المنتجات — product catalog CRUD."""

import pandas as pd
import streamlit as st

from utils.db import (
    STOCK_STATUS_LABELS_AR,
    STOCK_STATUSES,
    delete_product,
    fetch_categories,
    fetch_products,
    insert_product,
    update_product,
)

st.caption("إضافة منتجات جديدة وتعديل الكتالوج مباشرة")

categories = fetch_categories()
if not categories:
    st.warning("أضف قسماً واحداً على الأقل من صفحة الأقسام قبل إضافة المنتجات.")
else:
    category_options = {(c.get("name_ar") or c.get("name")): c["id"] for c in categories}

    with st.form("new_product", clear_on_submit=True, border=True):
        st.subheader("إضافة منتج جديد")
        col_a, col_b = st.columns(2)
        with col_a:
            name_ar = st.text_input("اسم المنتج", placeholder="مثال: حليب كامل الدسم")
            price = st.number_input("السعر", min_value=0.0, step=0.25, format="%.2f")
            unit = st.text_input("الوحدة", placeholder="مثال: لتر، كجم، علبة")
        with col_b:
            category_name = st.selectbox("القسم", options=list(category_options.keys()))
            sku = st.text_input("رمز المنتج (SKU)", placeholder="اختياري")
            stock_quantity = st.number_input("الكمية المتوفرة", min_value=0, step=1)

        with st.container(horizontal=True):
            is_weekly = st.checkbox("عرض الأسبوع")
            is_exclusive = st.checkbox("حصري للتطبيق")

        submitted = st.form_submit_button("حفظ المنتج", type="primary", icon=":material/add:")

    if submitted:
        clean = (name_ar or "").strip()
        if not clean:
            st.error("الرجاء إدخال اسم المنتج.")
        else:
            try:
                insert_product(
                    {
                        "name": clean,
                        "name_ar": clean,
                        "price": price,
                        "unit": unit.strip() or None,
                        "sku": sku.strip() or None,
                        "category_id": category_options[category_name],
                        "stock_quantity": int(stock_quantity),
                        "is_weekly_offer": bool(is_weekly),
                        "is_app_exclusive": bool(is_exclusive),
                        "is_active": True,
                    }
                )
                st.success(f"تمت إضافة المنتج «{clean}».")
                st.rerun()
            except Exception as exc:
                st.error(f"تعذر حفظ المنتج: {exc}")

    st.divider()
    st.subheader("كل المنتجات")
    products = fetch_products()

    if not products:
        st.info("لا توجد منتجات بعد.")
    else:
        df = pd.DataFrame(
            [
                {
                    "المنتج": p.get("name_ar") or p.get("name") or "",
                    "القسم": (
                        (p.get("categories") or {}).get("name_ar")
                        or (p.get("categories") or {}).get("name")
                        or "—"
                    ),
                    "السعر": float(p["price"]) if p.get("price") is not None else None,
                    "عرض الأسبوع": bool(p.get("is_weekly_offer")),
                    "حصري للتطبيق": bool(p.get("is_app_exclusive")),
                    "مفعّل": bool(p.get("is_active")),
                    "المخزون": p.get("stock_quantity"),
                }
                for p in products
            ]
        )

        event = st.dataframe(
            df,
            hide_index=True,
            on_select="rerun",
            selection_mode="single-row",
            alt="قائمة المنتجات",
            key="products_table",
        )

        selected_rows = event.selection.rows
        if selected_rows:
            product = products[selected_rows[0]]
            category_ids = list(category_options.values())
            current_category_index = (
                category_ids.index(product["category_id"])
                if product.get("category_id") in category_ids
                else 0
            )

            with st.container(border=True):
                st.markdown(f"**تعديل: {product.get('name_ar') or product.get('name')}**")
                col1, col2 = st.columns(2)
                with col1:
                    edit_name_ar = st.text_input(
                        "اسم المنتج", value=product.get("name_ar") or "", key=f"p_name_{product['id']}"
                    )
                    edit_price = st.number_input(
                        "السعر",
                        min_value=0.0,
                        step=0.25,
                        format="%.2f",
                        value=float(product.get("price") or 0),
                        key=f"p_price_{product['id']}",
                    )
                    edit_category = st.selectbox(
                        "القسم",
                        options=list(category_options.keys()),
                        index=current_category_index,
                        key=f"p_cat_{product['id']}",
                    )
                with col2:
                    edit_stock_qty = st.number_input(
                        "الكمية",
                        min_value=0,
                        step=1,
                        value=int(product.get("stock_quantity") or 0),
                        key=f"p_qty_{product['id']}",
                    )
                    edit_stock_status = st.selectbox(
                        "حالة المخزون",
                        options=STOCK_STATUSES,
                        format_func=lambda s: STOCK_STATUS_LABELS_AR[s],
                        index=STOCK_STATUSES.index(product.get("stock_status") or "in_stock"),
                        key=f"p_stock_status_{product['id']}",
                    )
                    edit_active = st.checkbox(
                        "مفعّل", value=bool(product.get("is_active")), key=f"p_active_{product['id']}"
                    )

                with st.container(horizontal=True):
                    edit_weekly = st.checkbox(
                        "عرض الأسبوع",
                        value=bool(product.get("is_weekly_offer")),
                        key=f"p_weekly_{product['id']}",
                    )
                    edit_exclusive = st.checkbox(
                        "حصري للتطبيق",
                        value=bool(product.get("is_app_exclusive")),
                        key=f"p_exclusive_{product['id']}",
                    )

                with st.container(horizontal=True, horizontal_alignment="right"):
                    if st.button(
                        "حفظ التعديلات",
                        type="primary",
                        icon=":material/save:",
                        key=f"p_save_{product['id']}",
                    ):
                        try:
                            update_product(
                                product["id"],
                                {
                                    "name_ar": edit_name_ar.strip(),
                                    "price": edit_price,
                                    "category_id": category_options[edit_category],
                                    "stock_quantity": int(edit_stock_qty),
                                    "stock_status": edit_stock_status,
                                    "is_active": edit_active,
                                    "is_weekly_offer": edit_weekly,
                                    "is_app_exclusive": edit_exclusive,
                                },
                            )
                            st.toast("تم حفظ التعديلات.", icon=":material/check_circle:")
                            st.rerun()
                        except Exception as exc:
                            st.error(f"تعذر حفظ التعديلات: {exc}")
                    if st.button(
                        "حذف المنتج", icon=":material/delete:", key=f"p_delete_{product['id']}"
                    ):
                        try:
                            delete_product(product["id"])
                            st.toast("تم حذف المنتج.", icon=":material/check_circle:")
                            st.rerun()
                        except Exception as exc:
                            st.error(f"تعذر حذف المنتج: {exc}")
