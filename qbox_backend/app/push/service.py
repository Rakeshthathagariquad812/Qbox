"""Push notifications: the bell, sent to the phone the moment it happens.

What is sent is exactly what the bell shows (app/notices), so the same rules hold:
who may see what, kinds switched off in the bell, and someone's own action is never
news to them. Each bell item is sent once.

When it is sent:
- Straight after any change someone makes (a POST, PUT or DELETE that worked), the
  people it can concern are checked: the one who made it, and the shops, customers
  and suppliers connected to them that had something new in the last few minutes.
- Every few minutes everyone with a phone is checked too, for what nobody's action
  caused (a supplier due today).

Quiet hours, if the person chose them for that phone (for example 10 PM to 7 AM, Indian
time): notifications still come at once, but silently and not said aloud.

Done in one background worker, so a request never waits for Firebase.
"""

import logging
import queue
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.database import SessionLocal
from app.models import (
    NoticePush,
    Payment,
    PushDevice,
    Role,
    SupplyLink,
    UdhaarCustomer,
    UdhaarEntry,
    User,
)
from app.notices import service as bell
from app.notices.schemas import TYPES, NoticeOut, NoticeType
from app.push import fcm, texts
from app.udhaar.schemas import INDIA

log = logging.getLogger("qbox.push")

RECENT = timedelta(minutes=10)  # "had something new" for the people around someone
FRESH = timedelta(days=2)  # older bell items are never pushed
FORGET_AFTER = timedelta(days=100)  # what was sent is remembered for longer than the bell keeps it
SWEEP_SECONDS = 300
MAX_DEVICES = 5  # per person; the oldest is dropped
DAY_MINUTES = 24 * 60


@dataclass(frozen=True)
class _Phone:
    token: str
    speak: frozenset[str]
    quiet_from: int | None  # minutes after midnight; None = no quiet hours
    quiet_to: int | None


def in_quiet_hours(minute: int, start: int | None, end: int | None) -> bool:
    """[start, end) in minutes after midnight; it may cross midnight (22:00 to 07:00)."""
    if start is None or end is None or start == end:
        return False
    return start <= minute < end if start < end else minute >= start or minute < end


def _now_minute() -> int:
    now = datetime.now(INDIA)
    return now.hour * 60 + now.minute


def speak_key(role: Role, group: NoticeType) -> str:
    """How a phone names one kind of bell news it says aloud: "BUSINESS:PAYMENT"."""
    return f"{role.value}:{group.value}"


# Every kind there is, and "money coming in" (what an earlier app build's on/off meant).
ALL_SPOKEN = [speak_key(role, group) for role, groups in TYPES.items() for group in groups]
MONEY_SPOKEN = [speak_key(Role.BUSINESS, NoticeType.PAYMENT), speak_key(Role.SUPPLIER, NoticeType.LEDGER)]

# Replaced in tests.
sender: Callable[[fcm.Message], None] = fcm.send


def is_on() -> bool:
    return fcm.is_on()


# ---------- phones ----------


def register(db: Session, user: User, token: str, speak: list[str] | None = None,
             quiet_from: int | None = None, quiet_to: int | None = None) -> None:
    """This phone gets this user's notifications (it is moved from anyone else).
    The first phone starts from now: what is already in the bell is not sent.
    [speak]: the kinds it says aloud, as speak_key(); [quiet_from]/[quiet_to]: its quiet
    hours in minutes after midnight, or none. Sent again whenever they change."""
    had_phone = _devices(db, user) != []
    db.execute(delete(PushDevice).where(PushDevice.token == token))
    quiet = quiet_from is not None and quiet_to is not None
    db.add(PushDevice(token=token, user_id=user.id, token_version=user.token_version,
                      speak=[k for k in ALL_SPOKEN if k in set(speak or [])],
                      quiet_from=quiet_from if quiet else None, quiet_to=quiet_to if quiet else None))
    db.flush()
    extra = db.scalars(select(PushDevice.token).where(PushDevice.user_id == user.id)
                       .order_by(PushDevice.created_at.desc()).offset(MAX_DEVICES)).all()
    if extra:
        db.execute(delete(PushDevice).where(PushDevice.token.in_(extra)))
    if not had_phone:
        _mark_all_sent(db, user)
    db.commit()


def forget(db: Session, user: User, token: str) -> None:
    """Log out on this phone."""
    db.execute(delete(PushDevice).where(PushDevice.token == token, PushDevice.user_id == user.id))
    db.commit()


def forget_all(db: Session, user_id: int) -> None:
    """Account deleted (not committed here)."""
    db.execute(delete(PushDevice).where(PushDevice.user_id == user_id))
    db.execute(delete(NoticePush).where(NoticePush.user_id == user_id))


def _devices(db: Session, user: User) -> list[PushDevice]:
    """Phones still logged in with a valid login; the rest are removed."""
    rows = db.scalars(select(PushDevice).where(PushDevice.user_id == user.id)).all()
    stale = [d.token for d in rows if d.token_version != user.token_version or user.deleted_at is not None]
    if stale:
        db.execute(delete(PushDevice).where(PushDevice.token.in_(stale)))
    return [d for d in rows if d.token not in stale]


def _mark_all_sent(db: Session, user: User) -> None:
    for role in _roles(user):
        for n in bell.notices(db, user, role).notices:
            _claim(db, user, role, n)


# ---------- who to check ----------


def around(db: Session, user_id: int) -> set[int]:
    """The person who made a change, and the people it can concern."""
    since = datetime.now(UTC) - RECENT
    user = db.get(User, user_id)
    if user is None:
        return set()
    out = {user_id}
    # As a shop: customers whose book changed, and payers it answered.
    recent_line = select(UdhaarEntry.id).where(
        UdhaarEntry.customer_id == UdhaarCustomer.id,
        or_(UdhaarEntry.created_at >= since, UdhaarEntry.deleted_at >= since)).exists()
    mobiles = select(UdhaarCustomer.mobile).where(
        UdhaarCustomer.shop_user_id == user_id,
        or_(UdhaarCustomer.verified_at >= since, UdhaarCustomer.dispute_resolved_at >= since, recent_line))
    out |= set(db.scalars(select(User.id).where(User.mobile.in_(mobiles))))
    out |= {p for p in db.scalars(select(Payment.payer_user_id).distinct().where(
        Payment.shop_user_id == user_id, Payment.answered_at >= since)) if p}
    # As a customer: the shops whose books they are in, and shops they paid.
    out |= set(db.scalars(select(UdhaarCustomer.shop_user_id).distinct().where(UdhaarCustomer.mobile == user.mobile)))
    out |= set(db.scalars(select(Payment.shop_user_id).distinct().where(
        Payment.payer_user_id == user_id,
        or_(Payment.created_at >= since, Payment.claimed_at >= since, Payment.paid_at >= since,
            Payment.checked_at >= since))))
    # Shops and suppliers connected to each other.
    out |= set(db.scalars(select(SupplyLink.supplier_user_id).where(SupplyLink.shop_user_id == user_id)))
    out |= set(db.scalars(select(SupplyLink.shop_user_id).where(SupplyLink.supplier_user_id == user_id)))
    return out


# ---------- sending ----------


def deliver(db: Session, user_ids: set[int]) -> int:
    """Sends what is new in these people's bells to their phones. Returns how many
    notifications were sent."""
    with_phone = set(db.scalars(select(PushDevice.user_id).distinct().where(PushDevice.user_id.in_(user_ids))))
    sent = 0
    for user_id in sorted(with_phone):
        user = db.get(User, user_id)
        if user is None:
            continue
        phones = [_Phone(d.token, frozenset(d.speak or []), d.quiet_from, d.quiet_to) for d in _devices(db, user)]
        db.commit()
        if not phones:
            continue
        fresh_from = datetime.now(UTC) - FRESH
        for role in _roles(user):
            for n in reversed(bell.notices(db, user, role).notices):  # oldest first
                if not n.unread or n.at < fresh_from or not _claim(db, user, role, n):
                    continue
                db.commit()
                sent += _send(db, role, n, phones)
    return sent


def _claim(db: Session, user: User, role: Role, notice: NoticeOut) -> bool:
    """True the first time only (also when two servers try at once)."""
    done = db.execute(insert(NoticePush).values(user_id=user.id, role=role.value, notice=notice.id)
                      .on_conflict_do_nothing().returning(NoticePush.notice)).first()
    return done is not None


def _send(db: Session, role: Role, notice: NoticeOut, phones: list[_Phone]) -> int:
    title, body = texts.words(notice)
    data = {"role": role.value, "notice": notice.id, "kind": notice.kind.value, "type": notice.type.value}
    key = speak_key(role, notice.type)
    minute = _now_minute()
    sent = 0
    for phone in phones:
        quiet = in_quiet_hours(minute, phone.quiet_from, phone.quiet_to)
        message = fcm.Message(
            token=phone.token, title=title, body=body, channel="qbox_quiet" if quiet else "qbox_alerts",
            data=data, tag=f"{role.value}:{notice.id}",
            # The app shows it itself and says it aloud.
            spoken=key in phone.speak and not quiet,
            name=notice.name, amount_paise=notice.amount_paise,
        )
        try:
            sender(message)
            sent += 1
        except fcm.Gone:
            db.execute(delete(PushDevice).where(PushDevice.token == phone.token))
            db.commit()
    return sent


def _roles(user: User) -> list[Role]:
    return [Role(r.role) for r in user.roles]


def sweep(db: Session) -> int:
    """Everyone with a phone; and old send records are forgotten."""
    db.execute(delete(NoticePush).where(NoticePush.at < datetime.now(UTC) - FORGET_AFTER))
    db.commit()
    return deliver(db, set(db.scalars(select(PushDevice.user_id).distinct())))


# ---------- the background worker ----------

_queue: "queue.Queue[int]" = queue.Queue()
_started = False
_start_lock = threading.Lock()


def poke(user_id: int) -> None:
    """Someone changed something: check them and the people around them soon."""
    if is_on():
        _queue.put(user_id)


def start() -> None:
    """Called when the server starts. Does nothing when push is switched off."""
    global _started
    with _start_lock:
        if _started or not is_on():
            return
        _started = True
    threading.Thread(target=_work, name="qbox-push", daemon=True).start()
    log.info("Push notifications are on")


def _work() -> None:
    next_sweep = time.monotonic() + 30
    while True:
        try:
            first = _queue.get(timeout=max(1.0, next_sweep - time.monotonic()))
        except queue.Empty:
            first = None
        actors = set() if first is None else {first}
        time.sleep(0.2 if actors else 0)  # one change often comes as a few requests
        while True:
            try:
                actors.add(_queue.get_nowait())
            except queue.Empty:
                break
        try:
            with SessionLocal() as db:
                if actors:
                    people: set[int] = set()
                    for actor in actors:
                        people |= around(db, actor)
                    deliver(db, people)
                if time.monotonic() >= next_sweep:
                    next_sweep = time.monotonic() + SWEEP_SECONDS
                    sweep(db)
        except Exception:  # never let one problem stop notifications for good
            log.exception("Push notifications: a round failed")
