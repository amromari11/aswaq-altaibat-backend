"""Firebase Cloud Messaging (HTTP v1) client for the admin dashboard.

Authenticates with a Firebase service account (kept in ``.streamlit/secrets.toml`` as
``FCM_SERVICE_ACCOUNT``, never in the repo) and sends one message per device token.
FCM v1 has no multi-token endpoint, so a small thread pool does the fan-out.

Tokens FCM reports as dead (app uninstalled, token rotated) come back in
``SendOutcome.dead`` so the caller can delete them; every other failure is counted and
its reason kept, so the notification log says what actually happened.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable, Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

import httpx

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
ANDROID_CHANNEL = "promotions"

_REQUIRED_FIELDS = ("type", "project_id", "client_email", "private_key")


class FcmConfigError(ValueError):
    """The service-account secret is missing or malformed."""


@dataclass
class SendOutcome:
    sent: int = 0
    dead: list[str] = field(default_factory=list)  # tokens FCM says no longer exist
    failed: int = 0  # everything else that was not delivered (dead tokens excluded)
    errors: list[str] = field(default_factory=list)  # distinct reasons, for the log


def load_service_account(raw: object) -> dict:
    """Accept the secret as a TOML table or as the downloaded JSON text; validate it."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise FcmConfigError("FCM_SERVICE_ACCOUNT ليس JSON صالحاً") from exc
    if not isinstance(raw, Mapping):
        raise FcmConfigError("FCM_SERVICE_ACCOUNT غير مضبوط")
    info = dict(raw)
    missing = [k for k in _REQUIRED_FIELDS if not info.get(k)]
    if missing or info.get("type") != "service_account":
        raise FcmConfigError("FCM_SERVICE_ACCOUNT ناقص: " + ", ".join(missing or ["type"]))
    return info


def build_message(token: str, title: str, body: str, data: Mapping[str, str] | None = None) -> dict:
    """One FCM v1 message: a visible notification on both platforms, plus string-only data."""
    message: dict = {
        "token": token,
        "notification": {"title": title, "body": body},
        "android": {"priority": "HIGH", "notification": {"channel_id": ANDROID_CHANNEL}},
        "apns": {"headers": {"apns-priority": "10"}, "payload": {"aps": {"sound": "default"}}},
    }
    if data:
        message["data"] = {str(k): str(v) for k, v in data.items()}  # FCM data values must be strings
    return {"message": message}


def _google_access_token(info: dict) -> Callable[[], str]:
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_info(info, scopes=[FCM_SCOPE])

    def token() -> str:
        if not credentials.valid:
            credentials.refresh(Request())
        return credentials.token

    return token


def _error_code(response: httpx.Response) -> tuple[str, str]:
    """(FCM errorCode or status, human message) from an error response."""
    try:
        error = response.json().get("error", {})
    except ValueError:
        return str(response.status_code), response.text[:200]
    for detail in error.get("details", []):
        if detail.get("errorCode"):
            return detail["errorCode"], error.get("message", "")
    return error.get("status", str(response.status_code)), error.get("message", "")


def _token_is_dead(response: httpx.Response, code: str, message: str) -> bool:
    if code == "UNREGISTERED" or response.status_code == 404:
        return True
    # A malformed token is refused as INVALID_ARGUMENT naming the token field.
    return code == "INVALID_ARGUMENT" and "registration token" in message.lower()


class FcmClient:
    def __init__(
        self,
        service_account: dict,
        *,
        http: httpx.Client | None = None,
        access_token: Callable[[], str] | None = None,
        workers: int = 8,
        retries: int = 1,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.project_id = service_account["project_id"]
        self._http = http or httpx.Client(timeout=15.0)
        self._access_token = access_token or _google_access_token(service_account)
        self._workers = max(1, workers)
        self._retries = retries
        self._sleep = sleep

    def send_all(self, tokens: list[str], title: str, body: str, data: Mapping[str, str] | None = None) -> SendOutcome:
        outcome = SendOutcome()
        if not tokens:
            return outcome
        bearer = self._access_token()  # one OAuth token for the whole batch

        def one(token: str) -> tuple[str, str | None]:
            return token, self._send_one(bearer, token, title, body, data)

        with ThreadPoolExecutor(max_workers=self._workers) as pool:
            results = list(pool.map(one, tokens))

        reasons: dict[str, None] = {}
        for token, status in results:
            if status is None:
                outcome.sent += 1
            elif status == "DEAD":
                outcome.dead.append(token)
            else:
                outcome.failed += 1
                reasons[status] = None
        outcome.errors = list(reasons)
        return outcome

    def _send_one(self, bearer: str, token: str, title: str, body: str, data) -> str | None:
        """None = delivered to FCM, "DEAD" = token is gone, anything else = the failure reason."""
        url = SEND_URL.format(project=self.project_id)
        payload = build_message(token, title, body, data)
        last = "تعذر الاتصال بـ FCM"
        for attempt in range(self._retries + 1):
            try:
                response = self._http.post(url, json=payload, headers={"Authorization": f"Bearer {bearer}"})
            except httpx.HTTPError as exc:
                last = f"تعذر الاتصال بـ FCM: {type(exc).__name__}"
            else:
                if response.status_code == 200:
                    return None
                code, message = _error_code(response)
                if _token_is_dead(response, code, message):
                    return "DEAD"
                last = f"{code}: {message}".strip(": ")[:200]
                if response.status_code not in (429, 500, 502, 503, 504):
                    return last  # a retry would get the same answer (bad credentials, bad payload...)
            if attempt < self._retries:
                self._sleep(1.0)
        return last


def client_from_secrets(secrets: Mapping) -> FcmClient | None:
    """The configured client, or None when the secret is absent. A broken secret raises FcmConfigError."""
    raw = secrets.get("FCM_SERVICE_ACCOUNT") if hasattr(secrets, "get") else None
    if not raw:
        return None
    return FcmClient(load_service_account(raw))
