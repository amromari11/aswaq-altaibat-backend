"""Push notifications: pick the devices, send through FCM, and log what happened.

Every send is written to the ``notifications`` table first (queued) and updated with the
real outcome: how many devices FCM accepted, how many failed, and why. Devices whose token
FCM reports as dead are removed so they are not retried forever.
"""

from __future__ import annotations

from collections.abc import Callable

import streamlit as st

from utils.db import (
    delete_push_tokens,
    fetch_push_tokens,
    insert_notification,
    update_notification_result,
)
from utils.fcm import FcmClient, FcmConfigError, client_from_secrets

NO_DEVICES_MESSAGE = "لا توجد أجهزة مسجلة لاستقبال هذا الإشعار بعد — تظهر الأجهزة هنا بعد فتح التطبيق وقبول الإشعارات."
NOT_CONFIGURED_MESSAGE = "لم يتم ضبط FCM_SERVICE_ACCOUNT في إعدادات التطبيق، لذلك لم يُرسل أي إشعار."


def fcm_status() -> tuple[FcmClient | None, str | None]:
    """(client, problem). ``problem`` is an Arabic explanation when no client could be built."""
    try:
        client = client_from_secrets(st.secrets)
    except FcmConfigError as exc:
        return None, str(exc)
    except Exception as exc:  # a missing secrets file raises its own error type
        return None, f"تعذر قراءة الإعدادات: {exc}"
    return (client, None) if client else (None, NOT_CONFIGURED_MESSAGE)


def send_push_notification(
    title: str,
    body: str,
    audience: str,
    target_user_id: str | None,
    *,
    client: FcmClient | None = None,
    client_factory: Callable[[], tuple[FcmClient | None, str | None]] = fcm_status,
) -> dict:
    """Send and log. Returns ``{"delivered", "recipient_count", "failed_count", "error"}``.

    ``recipient_count`` is the number of devices FCM accepted the message for.
    """
    notification = insert_notification(
        {"title": title, "body": body, "audience": audience, "target_user_id": target_user_id, "status": "queued"}
    )
    notification_id = notification["id"]

    def finish(status: str, sent: int = 0, failed: int = 0, error: str | None = None) -> dict:
        update_notification_result(
            notification_id, status=status, recipient_count=sent, failed_count=failed, error_message=error
        )
        return {"delivered": sent > 0, "recipient_count": sent, "failed_count": failed, "error": error}

    try:
        tokens = fetch_push_tokens(audience, target_user_id)
        if not tokens:
            return finish("failed", error=NO_DEVICES_MESSAGE)

        problem = None
        if client is None:
            client, problem = client_factory()
        if client is None:
            return finish("failed", error=problem or NOT_CONFIGURED_MESSAGE)

        outcome = client.send_all(tokens, title, body, {"type": "promo", "notification_id": str(notification_id)})
        if outcome.dead:
            delete_push_tokens(outcome.dead)
    except Exception as exc:  # whatever went wrong, the log must not stay "queued"
        finish("failed", error=f"{type(exc).__name__}: {exc}"[:300])
        raise

    failed = outcome.failed + len(outcome.dead)
    notes = list(outcome.errors)
    if outcome.dead:
        notes.append(f"{len(outcome.dead)} جهاز لم يعد مسجلاً وتمت إزالته")
    if outcome.sent == 0:
        return finish("failed", failed=failed, error="؛ ".join(notes) or "لم يصل الإشعار إلى أي جهاز")
    return finish("sent", sent=outcome.sent, failed=failed, error="؛ ".join(notes) or None)
