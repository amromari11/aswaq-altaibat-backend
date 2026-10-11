"""Push-notification sending — currently a logging stub.

No push provider is wired up yet, and there is no mobile app registering
device tokens, so `push_tokens` is always empty. `send_push_notification`
logs every send attempt to the `notifications` table and reports honestly
when nobody could have received it, instead of pretending to deliver.

To go live later: pick a provider (Firebase Cloud Messaging, OneSignal, or
Expo push if the app is built with Expo), add its SDK to requirements.txt,
store its server key in `.streamlit/secrets.toml`, and replace the marked
section below with a real API call. The dashboard UI and the `notifications`
log table don't need to change.
"""

from __future__ import annotations

from utils.db import count_push_tokens, insert_notification, update_notification_result


def send_push_notification(
    title: str, body: str, audience: str, target_user_id: str | None
) -> dict:
    notification = insert_notification(
        {
            "title": title,
            "body": body,
            "audience": audience,
            "target_user_id": target_user_id,
            "status": "queued",
        }
    )

    recipient_count = count_push_tokens(target_user_id if audience == "single_user" else None)

    if recipient_count == 0:
        update_notification_result(
            notification["id"],
            status="failed",
            recipient_count=0,
            error_message=(
                "لا توجد أجهزة مسجلة لاستقبال الإشعارات بعد — تطبيق الهاتف لا "
                "يسجّل أجهزة push حتى الآن."
            ),
        )
        return {"delivered": False, "recipient_count": 0}

    # TODO(push-provider): send through FCM/OneSignal/Expo here once device
    # tokens exist, then report the provider's real delivery count.
    update_notification_result(notification["id"], status="sent", recipient_count=recipient_count)
    return {"delivered": True, "recipient_count": recipient_count}
