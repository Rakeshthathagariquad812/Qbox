"""Sending one push notification through Firebase Cloud Messaging (HTTP v1).

Done with httpx and PyJWT instead of Google's firebase-admin package: that one
brings native files that Windows Smart App Control may block.

The key file (QBOX_FIREBASE_KEY_FILE) is read here and never logged.
"""

import json
import logging
import threading
import time
from dataclasses import dataclass
from functools import lru_cache

import httpx
import jwt

from app.config import get_settings

log = logging.getLogger("qbox.push")

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
TIMEOUT = 10


class Gone(Exception):
    """This phone's token no longer works (app removed, logged out, data cleared)."""


@dataclass(frozen=True)
class Message:
    token: str
    title: str
    body: str
    channel: str  # Android notification channel: "qbox_alerts" or "qbox_quiet"
    data: dict[str, str]
    tag: str  # the same tag replaces an older notification on the phone
    # Said aloud: sent as data only, so the app wakes up, shows it and speaks it
    # (in the phone's voice language, from the name and amount).
    spoken: bool = False
    name: str = ""
    amount_paise: int | None = None


@dataclass(frozen=True)
class _Key:
    project_id: str
    client_email: str
    private_key: str
    token_uri: str


@lru_cache
def _key() -> _Key | None:
    path = get_settings().firebase_key_file
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as file:
            raw = json.load(file)
        return _Key(raw["project_id"], raw["client_email"], raw["private_key"],
                    raw.get("token_uri", "https://oauth2.googleapis.com/token"))
    except (OSError, ValueError, KeyError):
        log.error("Push notifications are off: the Firebase key file could not be read")
        return None


def is_on() -> bool:
    return _key() is not None


_lock = threading.Lock()
_access: tuple[str, float] | None = None  # (token, good until)


def _access_token(key: _Key) -> str:
    global _access
    with _lock:
        if _access and _access[1] > time.time() + 60:
            return _access[0]
        now = int(time.time())
        assertion = jwt.encode(
            {"iss": key.client_email, "scope": SCOPE, "aud": key.token_uri, "iat": now, "exp": now + 3600},
            key.private_key, algorithm="RS256",
        )
        answer = httpx.post(key.token_uri, timeout=TIMEOUT, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
        answer.raise_for_status()
        body = answer.json()
        _access = (body["access_token"], time.time() + int(body.get("expires_in", 3600)))
        return _access[0]


def _payload(message: Message) -> dict:
    if message.spoken:
        return {
            "token": message.token,
            "data": {**message.data, "speak": "1", "title": message.title, "body": message.body,
                     "channel": message.channel, "tag": message.tag, "name": message.name,
                     "amount": str(message.amount_paise or 0)},
            "android": {"priority": "high"},
        }
    return {
        "token": message.token,
        "notification": {"title": message.title, "body": message.body},
        "data": message.data,
        "android": {
            "priority": "high",
            "notification": {"channel_id": message.channel, "tag": message.tag},
        },
    }


def send(message: Message) -> None:
    """Raises Gone when the phone's token is dead; other failures are logged and dropped
    (the bell still has it)."""
    key = _key()
    if key is None:
        return
    payload = {"message": _payload(message)}
    try:
        answer = httpx.post(
            f"https://fcm.googleapis.com/v1/projects/{key.project_id}/messages:send",
            json=payload, timeout=TIMEOUT, headers={"Authorization": f"Bearer {_access_token(key)}"},
        )
    except httpx.HTTPError as e:
        log.warning("Push not sent: %s", type(e).__name__)
        return
    if answer.status_code == 200:
        return
    if answer.status_code == 404 or "UNREGISTERED" in answer.text or (
            answer.status_code == 400 and "registration token" in answer.text.lower()):
        raise Gone()
    log.warning("Push not sent: Firebase answered %s", answer.status_code)
