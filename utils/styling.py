"""Shared page config and RTL/Arabic styling, applied once from the entry point."""

from __future__ import annotations

import streamlit as st


def apply_page_style() -> None:
    st.markdown(
        """
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&display=swap" rel="stylesheet">
        <style>
          html, body, [class*="st-"]:not([data-testid*="Icon"]), .stApp,
          .stMarkdown, .stTextInput, .stNumberInput, .stSelectbox, .stCheckbox,
          .stButton, .stDataFrame {
            font-family: "Tajawal", "Segoe UI", sans-serif !important;
          }
          html, body, .stApp { direction: rtl; text-align: right; }
          [data-testid="stSidebar"] { direction: rtl; text-align: right; }
          h1, h2, h3 { font-weight: 800 !important; }
          .block-container { padding-top: 1.5rem; }
          div[data-testid="stMetricValue"] { direction: ltr; text-align: right; }
          .stButton > button { width: 100%; font-weight: 700; }
        </style>
        """,
        unsafe_allow_html=True,
    )
