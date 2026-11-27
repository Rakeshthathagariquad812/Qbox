"""The words of a push notification: the same as the bell in the app
(qbox_frontend/lib/profile/notices.dart). Change both together."""

from collections.abc import Callable

from app.notices.schemas import NoticeKind, NoticeOut


def rupees(paise: int | None) -> str:
    """₹1,25,000 or ₹12.50, written the Indian way like the app."""
    paise = abs(paise or 0)
    whole, rest = divmod(paise, 100)
    digits = str(whole)
    if len(digits) > 3:
        head, last3 = digits[:-3], digits[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        digits = ",".join(parts) + "," + last3
    return f"₹{digits}" if rest == 0 else f"₹{digits}.{rest:02d}"


def _left(note: str | None) -> str:
    """"2 kg left" from "2000 KG"."""
    parts = (note or "").split(" ")
    if len(parts) != 2 or not parts[0].lstrip("-").isdigit():
        return ""
    text = f"{int(parts[0]) / 1000:.3f}".rstrip("0").rstrip(".")
    return f"{text} {parts[1].lower()} left"


_N = NoticeOut
_Words = tuple[Callable[[_N], str], Callable[[_N], str | None] | None]


def _a(n: _N) -> str:
    return rupees(n.amount_paise)


WORDS: dict[NoticeKind, _Words] = {
    NoticeKind.ADDED: (lambda n: f"{n.name} added you to its udhaar book", None),
    NoticeKind.CREDIT: (lambda n: f"{n.name} wrote {_a(n)} udhaar", None),
    NoticeKind.RECORDED: (lambda n: f"{n.name} recorded your payment of {_a(n)}", None),
    NoticeKind.DELETED: (lambda n: f"{n.name} deleted {_a(n)} from your udhaar", None),
    NoticeKind.NUMBER_KEPT: (lambda n: f"{n.name} says this number is yours", lambda n: "Talk to the shop if it is not."),
    NoticeKind.NUMBER_REMOVED: (lambda n: f"{n.name} removed your number from its book", None),
    NoticeKind.RECEIVED: (lambda n: f"{n.name} received your {_a(n)}", None),
    NoticeKind.NOT_RECEIVED: (lambda n: f"{n.name} did not receive {_a(n)}",
                              lambda n: "Check your UPI app, or talk to the shop."),
    NoticeKind.BUDGET_NEAR: (lambda n: "Most of this month's budget is used", lambda n: f"{_a(n)} spent so far"),
    NoticeKind.BUDGET_OVER: (lambda n: "You are over this month's budget", lambda n: f"It was crossed at {_a(n)}"),
    NoticeKind.PAID_ONLINE: (lambda n: f"{n.name} paid {_a(n)} online", None),
    NoticeKind.SAYS_PAID: (lambda n: f"{n.name} says they paid {_a(n)} by UPI",
                           lambda n: "Check your bank, then confirm."),
    NoticeKind.NOT_ME: (lambda n: f'{n.name}: "This is not my number"', lambda n: "Please check and decide."),
    NoticeKind.LOW_STOCK: (lambda n: f"{n.name} is running low", lambda n: _left(n.note)),
    NoticeKind.SUPPLIER_DUE: (lambda n: f"Pay {n.name}", lambda n: f"{_a(n)} is due"),
    NoticeKind.CONNECTED: (lambda n: f"{n.name} connected with you", None),
    NoticeKind.NOT_CONNECTED: (lambda n: f"{n.name} did not connect", None),
    NoticeKind.SUPPLIER_LEFT: (lambda n: f"{n.name} disconnected", None),
    NoticeKind.ORDER_ACCEPTED: (lambda n: f"{n.name} accepted your order: bill {_a(n)}", None),
    NoticeKind.ORDER_REJECTED: (lambda n: f"{n.name} rejected your order", None),
    NoticeKind.ORDER_SENT: (lambda n: f"{n.name}: your goods are on the way", None),
    NoticeKind.MONEY_CONFIRMED: (lambda n: f"{n.name} received your {_a(n)}", None),
    NoticeKind.NOT_RIGHT: (lambda n: f"{n.name} says {_a(n)} is not right", None),
    NoticeKind.THEY_GAVE: (lambda n: f"{n.name} wrote goods of {_a(n)}. Is it right?", None),
    NoticeKind.THEY_GOT: (lambda n: f"{n.name} wrote that you paid {_a(n)}", None),
    NoticeKind.THEY_DELETED: (lambda n: f"{n.name} deleted an entry of {_a(n)}", None),
    NoticeKind.WANTS_TO_CONNECT: (lambda n: f"{n.name} wants to connect", lambda n: "Check the amount and answer."),
    NoticeKind.SHOP_LEFT: (lambda n: f"{n.name} disconnected", None),
    NoticeKind.NEW_ORDER: (lambda n: f"New order from {n.name}", None),
    NoticeKind.ORDER_CANCELLED: (lambda n: f"{n.name} cancelled an order", None),
    NoticeKind.ORDER_RECEIVED: (lambda n: f"{n.name} received the goods", None),
    NoticeKind.CONFIRM_PURCHASE: (lambda n: f"{n.name} wrote goods for {_a(n)}", lambda n: n.note or "Please check it."),
    NoticeKind.CONFIRM_PAYMENT: (lambda n: f"{n.name} says they paid {_a(n)}",
                                 lambda n: "Confirm when the money came."),
    NoticeKind.ENTRY_DELETED: (lambda n: f"{n.name} deleted {_a(n)}", None),
    NoticeKind.SHOP_AGREED: (lambda n: f"{n.name} confirmed {_a(n)}", None),
    NoticeKind.SHOP_NOT_RIGHT: (lambda n: f"{n.name} says {_a(n)} is not right", None),
    NoticeKind.PRODUCT_LOW: (lambda n: f"{n.name} is running low", lambda n: _left(n.note)),
}


def words(notice: NoticeOut) -> tuple[str, str]:
    """(title, body) for the phone."""
    title, detail = WORDS[notice.kind]
    body = (detail(notice) if detail else None) or notice.note or ""
    if notice.test_mode:
        body = f"{body} (test money)".strip()
    return title(notice), body
