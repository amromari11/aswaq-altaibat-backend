"""Username/password gate for the admin dashboard.

Credentials live in `.streamlit/secrets.toml` (ADMIN_USERNAME / ADMIN_PASSWORD).
This suits a single internal admin account — move to `st.login`/OIDC if more
than one admin ever needs their own login.
"""

from __future__ import annotations

import hmac
from collections.abc import Mapping

import streamlit as st


def _secret_str(secrets: Mapping[str, object], key: str) -> str:
    value = secrets.get(key)
    if value is None:
        raise KeyError(key)
    return str(value)


def _constant_time_equal(left: str, right: str) -> bool:
    left_b = left.encode("utf-8")
    right_b = right.encode("utf-8")
    if len(left_b) != len(right_b):
        hmac.compare_digest(left_b, left_b)
        return False
    return hmac.compare_digest(left_b, right_b)


def _credentials_valid(username: str, password: str) -> bool:
    try:
        expected_user = _secret_str(st.secrets, "ADMIN_USERNAME")
        expected_pass = _secret_str(st.secrets, "ADMIN_PASSWORD")
    except (KeyError, FileNotFoundError):
        st.error(
            "لم يتم العثور على بيانات تسجيل الدخول. أضف `ADMIN_USERNAME` و "
            "`ADMIN_PASSWORD` إلى `.streamlit/secrets.toml`."
        )
        return False
    user_ok = _constant_time_equal(username.strip(), expected_user.strip())
    pass_ok = _constant_time_equal(password, expected_pass)
    return user_ok and pass_ok


def require_login() -> None:
    st.session_state.setdefault("authenticated", False)
    if st.session_state.authenticated:
        return

    st.markdown(
        "<style>[data-testid='stSidebar'] { display: none; }</style>",
        unsafe_allow_html=True,
    )

    _, center, _ = st.columns([1, 1.4, 1])
    with center:
        with st.container(border=True):
            st.title("تسجيل الدخول")
            st.caption("لوحة التحكم الداخلية — أسواق الطيبات")
            with st.form("admin_login"):
                username = st.text_input("اسم المستخدم")
                password = st.text_input("كلمة المرور", type="password")
                submitted = st.form_submit_button(
                    "دخول",
                    type="primary",
                    icon=":material/login:",
                    width="stretch",
                )
            if submitted:
                if _credentials_valid(username or "", password or ""):
                    st.session_state.authenticated = True
                    st.rerun()
                st.error("اسم المستخدم أو كلمة المرور غير صحيحة.")
    st.stop()
