"""Push notifications: the bell, sent once to the right phones."""

from datetime import datetime

import pytest
from sqlalchemy import select

from app.database import SessionLocal
from app.models import PushDevice, User
from app.notices.schemas import NoticeKind, NoticeOut, NoticeType
from app.push import fcm, texts
from app.push import service as push
from app.udhaar.schemas import INDIA
from tests.test_calendar import _account
from tests.test_pay_shop import UPI, _claimed
from tests.test_udhaar import RAMESH, SHOP_A, _add_customer, _entry, _post_entry

PHONE = "phone-token-of-ramesh-0000000001"
SHOP_PHONE = "phone-token-of-the-shop-00000001"


@pytest.fixture
def sent(monkeypatch):
    out: list[fcm.Message] = []
    monkeypatch.setattr(push, "sender", out.append)
    monkeypatch.setattr(push, "_now_minute", lambda: 23 * 60)  # 11 PM
    return out


def _id(mobile):
    with SessionLocal() as db:
        return db.scalar(select(User.id).where(User.mobile == mobile))


def _deliver_after(mobile):
    """What the server does straight after this person changes something."""
    with SessionLocal() as db:
        return push.deliver(db, push.around(db, _id(mobile)))


def _register(client, who, token=PHONE):
    answer = client.post("/api/devices", json={"token": token}, headers=who)
    assert answer.status_code == 204, answer.text


def _people(client):
    shop = _account(client, SHOP_A)
    book = _add_customer(client, shop)
    return shop, book, _account(client, RAMESH, roles=("CUSTOMER",))


def test_the_customer_is_told_at_once_and_only_once(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 1250, "rice"))
    assert _deliver_after(SHOP_A) == 1
    [message] = sent
    assert (message.token, message.title, message.body) == (PHONE, "Sri Balaji Kirana wrote ₹1,250 udhaar", "rice")
    assert message.data == {"role": "CUSTOMER", "notice": message.data["notice"], "kind": "CREDIT",
                            "type": "UDHAAR"}
    assert message.channel == "qbox_alerts"
    assert _deliver_after(SHOP_A) == 0  # never twice
    with SessionLocal() as db:
        assert push.sweep(db) == 0


def test_what_was_in_the_bell_before_the_first_phone_is_not_sent(client, sent):
    shop, book, ramesh = _people(client)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    _register(client, ramesh)
    assert _deliver_after(SHOP_A) == 0 and sent == []


def test_own_doing_and_kinds_switched_off_are_not_sent(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, shop, SHOP_PHONE)
    _register(client, ramesh)
    client.put("/api/notices/off", json={"role": "CUSTOMER", "off": ["UDHAAR"]}, headers=ramesh)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert _deliver_after(SHOP_A) == 0 and sent == []


def test_the_shop_is_told_when_a_customer_says_not_me(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, shop, SHOP_PHONE)
    client.post(f"/api/udhaar/mine/{book['id']}/not-me", headers=ramesh)
    assert _deliver_after(RAMESH) == 1
    assert (sent[0].token, sent[0].title, sent[0].data["role"]) == (
        SHOP_PHONE, 'Ramesh: "This is not my number"', "BUSINESS")


def test_logging_out_stops_them(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)
    assert client.post("/api/devices/forget", json={"token": PHONE}, headers=ramesh).status_code == 204
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert _deliver_after(SHOP_A) == 0


def test_log_out_from_all_phones_stops_them(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)
    client.post("/api/me/logout-all", headers=ramesh)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert _deliver_after(SHOP_A) == 0
    with SessionLocal() as db:
        assert db.scalars(select(PushDevice)).all() == []


def test_deleting_the_account_stops_them(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)
    assert client.post("/api/me/delete", json={"pin": "4826"}, headers=ramesh).status_code == 204
    with SessionLocal() as db:
        assert db.scalars(select(PushDevice)).all() == []


def test_a_phone_moves_to_whoever_logs_in_on_it(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)
    _register(client, shop)  # same phone, now the shop
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert _deliver_after(SHOP_A) == 0  # Ramesh's news does not go to the shop's phone


def test_a_dead_phone_is_removed(client, monkeypatch):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)

    def gone(_):
        raise fcm.Gone()

    monkeypatch.setattr(push, "sender", gone)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert _deliver_after(SHOP_A) == 0
    with SessionLocal() as db:
        assert db.scalars(select(PushDevice)).all() == []


def test_no_quiet_hours_unless_chosen(client, sent):
    shop, book, ramesh = _people(client)
    _register(client, ramesh)  # it is 11 PM
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    _deliver_after(SHOP_A)
    assert sent[-1].channel == "qbox_alerts"


def test_quiet_hours_are_silent_and_not_spoken(client, sent):
    shop, book, ramesh = _people(client)
    client.post("/api/devices", headers=ramesh, json={
        "token": PHONE, "speak": ["CUSTOMER:UDHAAR"], "quietFrom": 22 * 60, "quietTo": 7 * 60})
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    _deliver_after(SHOP_A)
    assert (sent[-1].channel, sent[-1].spoken) == ("qbox_quiet", False)
    # Only one end given: no quiet hours.
    client.post("/api/devices", json={"token": PHONE, "quietFrom": 22 * 60}, headers=ramesh)
    with SessionLocal() as db:
        assert (db.get(PushDevice, PHONE).quiet_from, db.get(PushDevice, PHONE).quiet_to) == (None, None)
    bad = client.post("/api/devices", json={"token": PHONE, "quietFrom": 1440, "quietTo": 0}, headers=ramesh)
    assert bad.status_code == 400


def test_what_counts_as_quiet_hours():
    night, lunch = (22 * 60, 7 * 60), (13 * 60, 14 * 60 + 30)
    assert [push.in_quiet_hours(h * 60, *night) for h in (6, 7, 21, 22, 23)] == [True, False, False, True, True]
    assert [push.in_quiet_hours(m, *lunch) for m in (779, 780, 869, 870)] == [False, True, True, False]
    assert not push.in_quiet_hours(600, None, None) and not push.in_quiet_hours(600, 600, 600)


def test_a_change_pokes_the_worker(client, monkeypatch):
    poked = []
    monkeypatch.setattr(push, "is_on", lambda: True)
    monkeypatch.setattr(push, "poke", poked.append)
    shop, book, _ = _people(client)
    poked.clear()
    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))
    assert poked == [_id(SHOP_A)]
    client.get("/api/udhaar/customers", headers=shop)  # only reading
    assert poked == [_id(SHOP_A)]


def test_money_coming_in_is_spoken_on_phones_that_want_it(client, sent):
    shop = _account(client, SHOP_A)
    client.put("/api/payments/settings/upi", json={"upiId": UPI, "upiName": "Lakshmi"}, headers=shop)
    book = _add_customer(client, shop)
    ramesh = _account(client, RAMESH, roles=("CUSTOMER",))
    client.post("/api/devices", json={"token": SHOP_PHONE, "speak": True}, headers=shop)
    _register(client, ramesh)
    _claimed(client, ramesh)  # "I paid by UPI"
    _deliver_after(RAMESH)
    [says] = sent
    assert (says.token, says.spoken, says.name, says.amount_paise) == (SHOP_PHONE, True, "Ramu", 15000)
    payload = fcm._payload(says)
    assert "notification" not in payload  # the app shows it and speaks it
    assert payload["data"]["speak"] == "1" and payload["data"]["amount"] == "15000"
    assert payload["data"]["title"] == "Ramu says they paid ₹150 by UPI"

    _post_entry(client, shop, book["id"], _entry("CREDIT", 250))  # not money coming in
    _deliver_after(SHOP_A)
    assert sent[-1].token == PHONE and sent[-1].spoken is False
    assert "notification" in fcm._payload(sent[-1])


def test_speaking_is_off_unless_the_phone_asks(client, sent):
    shop = _account(client, SHOP_A)
    client.put("/api/payments/settings/upi", json={"upiId": UPI, "upiName": "Lakshmi"}, headers=shop)
    ramesh = _account(client, RAMESH, roles=("CUSTOMER",))
    _register(client, shop, SHOP_PHONE)
    _claimed(client, ramesh)
    _deliver_after(RAMESH)
    assert [m.spoken for m in sent] == [False]


def test_each_kind_is_spoken_only_when_chosen(client, sent):
    shop, book, ramesh = _people(client)
    client.post("/api/devices", json={"token": PHONE, "speak": ["CUSTOMER:PAYMENT"]}, headers=ramesh)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 100))
    _deliver_after(SHOP_A)
    assert sent[-1].spoken is False  # udhaar was not chosen
    client.post("/api/devices", json={"token": PHONE, "speak": ["CUSTOMER:UDHAAR", "NOT:A_KIND"]}, headers=ramesh)
    _post_entry(client, shop, book["id"], _entry("CREDIT", 200))
    _deliver_after(SHOP_A)
    assert (sent[-1].spoken, sent[-1].title) == (True, "Sri Balaji Kirana wrote ₹200 udhaar")
    data = fcm._payload(sent[-1])["data"]
    assert (data["kind"], data["type"], data["role"]) == ("CREDIT", "UDHAAR", "CUSTOMER")
    with SessionLocal() as db:
        assert db.get(PushDevice, PHONE).speak == ["CUSTOMER:UDHAAR"]  # an unknown kind is not kept


def test_earlier_test_builds_still_register(client, sent):
    shop, _, _ = _people(client)
    for said, kept in ((True, push.MONEY_SPOKEN), ("MONEY", push.MONEY_SPOKEN), ("ALL", push.ALL_SPOKEN),
                       (False, []), ("OFF", [])):
        assert client.post("/api/devices", json={"token": SHOP_PHONE, "speak": said}, headers=shop).status_code == 204
        with SessionLocal() as db:
            assert db.get(PushDevice, SHOP_PHONE).speak == kept
    assert client.post("/api/devices", json={"token": SHOP_PHONE, "speak": "LOUD"}, headers=shop).status_code == 400


def test_every_bell_item_has_words():
    for kind in NoticeKind:
        notice = NoticeOut(id="x", kind=kind, type=NoticeType.UDHAAR, name="Ravi", amount_paise=12345678,
                           note="2500 KG", test_mode=False, at=datetime.now(INDIA), unread=True)
        title, _ = texts.words(notice)
        assert title


def test_rupees_like_the_app():
    assert [texts.rupees(p) for p in (0, 5000, 125000, 12345678, 1050)] == [
        "₹0", "₹50", "₹1,250", "₹1,23,456.78", "₹10.50"]
    assert texts._left("2500 KG") == "2.5 kg left"
