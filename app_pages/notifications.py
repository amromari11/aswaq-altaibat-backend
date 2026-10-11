"""الإشعارات — compose push notifications and track the send log."""

import pandas as pd
import streamlit as st

from utils.db import (
    NOTIFICATION_AUDIENCE_LABELS_AR,
    NOTIFICATION_AUDIENCES,
    NOTIFICATION_STATUS_LABELS_AR,
    fetch_notifications,
    fetch_profiles,
)
from utils.notifications import send_push_notification

st.caption("إرسال إشعارات للعملاء وتتبع سجل الإرسال")

st.info(
    "لا يوجد مزوّد إشعارات مُفعّل بعد — تطبيق الهاتف لم يُصدر بعد وجدول "
    "push_tokens فارغ، لذلك سيتم تسجيل الإشعارات هنا دون تسليم فعلي حتى "
    "يتم ربط Firebase أو OneSignal أو Expo.",
    icon=":material/info:",
)

profiles = fetch_profiles()
customer_options = {
    f"{p.get('full_name') or 'بدون اسم'} — {p.get('phone_number') or '—'}": p["id"] for p in profiles
}

with st.form("compose_notification", border=True):
    st.subheader("إشعار جديد")
    title = st.text_input("العنوان", placeholder="مثال: عروض نهاية الأسبوع بانتظارك!")
    body = st.text_area("النص", placeholder="تفاصيل العرض أو الرسالة...")
    audience = st.selectbox(
        "الجهة المستهدفة",
        options=NOTIFICATION_AUDIENCES,
        format_func=lambda a: NOTIFICATION_AUDIENCE_LABELS_AR[a],
    )
    selected_customer_label = None
    if audience == "single_user":
        if customer_options:
            selected_customer_label = st.selectbox("العميل", options=list(customer_options.keys()))
        else:
            st.warning("لا يوجد عملاء مسجلون بعد.")
    submitted = st.form_submit_button("إرسال", type="primary", icon=":material/send:")

if submitted:
    clean_title = (title or "").strip()
    clean_body = (body or "").strip()
    if not clean_title or not clean_body:
        st.error("الرجاء إدخال العنوان والنص.")
    elif audience == "single_user" and not selected_customer_label:
        st.error("الرجاء اختيار عميل.")
    else:
        target_user_id = customer_options.get(selected_customer_label) if selected_customer_label else None
        try:
            result = send_push_notification(clean_title, clean_body, audience, target_user_id)
            if result["delivered"]:
                st.success(f"تم الإرسال إلى {result['recipient_count']} جهاز.")
            else:
                st.warning("تم تسجيل الإشعار، لكن لا يوجد أي جهاز مسجل لاستقباله حالياً.")
            st.rerun()
        except Exception as exc:
            st.error(f"تعذر إرسال الإشعار: {exc}")

st.divider()
st.subheader("سجل الإشعارات")
notifications = fetch_notifications()
if not notifications:
    st.info("لم يتم إرسال أي إشعارات بعد.")
else:
    df = pd.DataFrame(
        [
            {
                "العنوان": n.get("title"),
                "الجهة": NOTIFICATION_AUDIENCE_LABELS_AR.get(n.get("audience"), n.get("audience")),
                "الحالة": NOTIFICATION_STATUS_LABELS_AR.get(n.get("status"), n.get("status")),
                "عدد المستلمين": n.get("recipient_count"),
                "التاريخ": n.get("created_at"),
            }
            for n in notifications
        ]
    )
    st.dataframe(df, hide_index=True, width="stretch", alt="سجل الإشعارات المرسلة")
