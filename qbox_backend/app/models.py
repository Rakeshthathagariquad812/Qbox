"""Database tables. One class = one table.

Tables are created and changed through Alembic migrations
(alembic/versions/), never by hand.
"""

import datetime as dt
import enum
from datetime import date, datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    Time,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class Role(str, enum.Enum):
    """Matches QboxRole in the Flutter app (business, customer, supplier)."""

    BUSINESS = "BUSINESS"
    CUSTOMER = "CUSTOMER"
    SUPPLIER = "SUPPLIER"

    def qbox_id(self, user_id: int) -> str:
        """The QBOX ID shown in the app, e.g. user 7 as a customer is QBC10007."""
        prefix = {"BUSINESS": "QBM", "CUSTOMER": "QBC", "SUPPLIER": "QBS"}[self.value]
        return f"{prefix}{10000 + user_id}"


class OtpPurpose(str, enum.Enum):
    """Why an OTP was sent. A code sent for one purpose cannot be used for another."""

    SIGNUP = "SIGNUP"
    RESET_PIN = "RESET_PIN"
    UDHAAR_ADD = "UDHAAR_ADD"  # a shop adding this mobile to its udhaar book
    SUPPLIER_ADD = "SUPPLIER_ADD"  # a shop connecting with this supplier


class EntryKind(str, enum.Enum):
    """CREDIT = the shop gave goods on udhaar (customer owes more).
    PAYMENT = the customer paid back (customer owes less)."""

    CREDIT = "CREDIT"
    PAYMENT = "PAYMENT"


class Dispute(str, enum.Enum):
    """A customer saying "this is not my number" about a shop's udhaar book.
    The customer reports; only the shop decides."""

    NONE = "NONE"
    REPORTED = "REPORTED"  # customer reported, waiting for the shop
    CONFIRMED = "CONFIRMED"  # shop says the number is right (cannot be reported again)
    UNLINKED = "UNLINKED"  # shop agrees it is the wrong number: hidden from that phone


class EventCategory(str, enum.Enum):
    """Matches EventCategory in the Flutter app; each has its own colour there."""

    SHOP = "SHOP"
    SUPPLIER = "SUPPLIER"
    PAYMENT = "PAYMENT"
    PERSONAL = "PERSONAL"
    OTHER = "OTHER"


class PaymentSource(str, enum.Enum):
    """COUNTER = a QR shown at the counter (Razorpay tells us when it is paid).
    UDHAAR = a customer paid their udhaar from their own QBOX app.
    MANUAL = paid to the shop's own UPI ID; the shop confirmed it by hand.
    DIRECT = a customer paid the shop from their own QBOX app (Pay to Shop)."""

    COUNTER = "COUNTER"
    UDHAAR = "UDHAAR"
    MANUAL = "MANUAL"
    DIRECT = "DIRECT"


class PaymentStatus(str, enum.Enum):
    WAITING = "WAITING"
    PAID = "PAID"
    EXPIRED = "EXPIRED"
    CANCELLED = "CANCELLED"


class ExpenseCategory(str, enum.Enum):
    """Where a customer's money went. Matches ExpenseCategory in the Flutter app."""

    GROCERIES = "GROCERIES"
    FOOD = "FOOD"
    TRAVEL = "TRAVEL"
    BILLS = "BILLS"
    HEALTH = "HEALTH"
    EDUCATION = "EDUCATION"
    CLOTHES = "CLOTHES"
    HOME = "HOME"
    FUN = "FUN"
    FAMILY = "FAMILY"
    OTHER = "OTHER"


class Gateway(str, enum.Enum):
    """Which Razorpay feature collects the money."""

    QR_CODE = "QR_CODE"  # a one-time UPI QR for a fixed amount
    PAYMENT_LINK = "PAYMENT_LINK"  # a payment page; its link is shown as a QR
    ORDER = "ORDER"  # Razorpay's payment screen inside the customer's QBOX app


class StockUnit(str, enum.Enum):
    """How an item is counted. Quantities are stored in thousandths of the unit
    (1.5 kg = 1500), so loose goods never drift by rounding."""

    KG = "KG"
    G = "G"
    L = "L"
    ML = "ML"
    PIECE = "PIECE"
    PACKET = "PACKET"
    BOX = "BOX"
    DOZEN = "DOZEN"
    BAG = "BAG"


class StockMoveKind(str, enum.Enum):
    """IN = stock came in (bought). OUT = sold or used.
    ADJUST = the count was corrected (damaged, expired, counted wrong): + or -, with a reason."""

    IN = "IN"
    OUT = "OUT"
    ADJUST = "ADJUST"


class SupplierEntryKind(str, enum.Enum):
    """PURCHASE = goods bought from the supplier (the shop owes more).
    PAYMENT = the shop paid the supplier (owes less)."""

    PURCHASE = "PURCHASE"
    PAYMENT = "PAYMENT"


class PayMethod(str, enum.Enum):
    CASH = "CASH"
    UPI = "UPI"
    BANK = "BANK"
    OTHER = "OTHER"


class OrderStatus(str, enum.Enum):
    SENT = "SENT"  # sent to the supplier, waiting for the goods
    # Only with a connected supplier:
    ACCEPTED = "ACCEPTED"  # they will give it, with prices
    REJECTED = "REJECTED"
    DISPATCHED = "DISPATCHED"  # on the way
    RECEIVED = "RECEIVED"  # goods came: recorded as a purchase, stock went up
    CANCELLED = "CANCELLED"


class PayPlan(str, enum.Enum):
    """How the shop will pay for an order to a connected supplier."""

    LATER = "LATER"  # added to what it owes when the goods come
    CASH = "CASH"  # when the goods come
    UPI = "UPI"  # after the supplier accepts


class LinkStatus(str, enum.Enum):
    """A shop's supplier connected with a QBOX Supplier account."""

    ASKED = "ASKED"  # the shop asked
    ON = "ON"  # the supplier said yes
    DECLINED = "DECLINED"
    CANCELLED = "CANCELLED"  # the shop took the question back
    ENDED = "ENDED"


class Confirm(str, enum.Enum):
    """The supplier's answer about an entry written while connected."""

    WAITING = "WAITING"
    CONFIRMED = "CONFIRMED"
    DISPUTED = "DISPUTED"
    CLOSED = "CLOSED"  # disconnected before it was agreed


class Repeat(str, enum.Enum):
    NONE = "NONE"
    DAILY = "DAILY"
    WEEKLY = "WEEKLY"
    MONTHLY = "MONTHLY"
    YEARLY = "YEARLY"


class User(Base):
    """One person = one mobile number = one user, holding any mix of roles."""

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    mobile: Mapped[str] = mapped_column(String(10), unique=True)
    pin_hash: Mapped[str] = mapped_column(String(100))
    failed_login_attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Written into every access token; raising it logs out every phone (done on PIN reset).
    token_version: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    # They deleted their account: only the row is left, so other people's records stay right.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    roles: Mapped[list["UserRole"]] = relationship(cascade="all, delete-orphan", lazy="selectin")
    shop: Mapped["ShopProfile | None"] = relationship(cascade="all, delete-orphan", lazy="selectin")
    customer: Mapped["CustomerProfile | None"] = relationship(cascade="all, delete-orphan", lazy="selectin")
    supplier: Mapped["SupplierProfile | None"] = relationship(cascade="all, delete-orphan", lazy="selectin")


class UserRole(Base):
    __tablename__ = "user_roles"
    __table_args__ = (
        CheckConstraint("role IN ('BUSINESS', 'CUSTOMER', 'SUPPLIER')", name="user_roles_role_check"),
    )

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String(20), primary_key=True)


class ShopProfile(Base):
    __tablename__ = "shop_profiles"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    qbox_id: Mapped[str] = mapped_column(String(20), unique=True)
    shop_name: Mapped[str] = mapped_column(String(120))
    business_type: Mapped[str] = mapped_column(String(60))
    business_type_detail: Mapped[str | None] = mapped_column(String(120))
    shop_category: Mapped[str] = mapped_column(String(60))
    shop_category_detail: Mapped[str | None] = mapped_column(String(120))
    address: Mapped[str] = mapped_column(String(300))
    contact_number: Mapped[str] = mapped_column(String(10))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class CustomerProfile(Base):
    __tablename__ = "customer_profiles"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    qbox_id: Mapped[str] = mapped_column(String(20), unique=True)
    full_name: Mapped[str] = mapped_column(String(120))
    mobile_number: Mapped[str] = mapped_column(String(10))
    email: Mapped[str | None] = mapped_column(String(160))
    address: Mapped[str | None] = mapped_column(String(300))
    aadhaar_link_requested: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SupplierProfile(Base):
    __tablename__ = "supplier_profiles"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    qbox_id: Mapped[str] = mapped_column(String(20), unique=True)
    supplier_name: Mapped[str] = mapped_column(String(120))
    business_type: Mapped[str] = mapped_column(String(60))
    business_type_detail: Mapped[str | None] = mapped_column(String(120))
    products_supplied: Mapped[str] = mapped_column(String(300))
    contact_number: Mapped[str] = mapped_column(String(10))
    address: Mapped[str] = mapped_column(String(300))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ProfilePhoto(Base):
    """A user's photo in one role. [ref] is random and new for every photo."""

    __tablename__ = "profile_photos"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String(20), primary_key=True)
    ref: Mapped[str] = mapped_column(String(32), unique=True)
    jpeg: Mapped[bytes] = mapped_column(LargeBinary, deferred=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class OtpCode(Base):
    """One row per OTP sent. Only a hash of the code is stored."""

    __tablename__ = "otp_codes"
    __table_args__ = (
        CheckConstraint("purpose IN ('SIGNUP', 'RESET_PIN', 'UDHAAR_ADD', 'SUPPLIER_ADD')", name="otp_codes_purpose_check"),
        Index("idx_otp_codes_lookup", "mobile", "purpose", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    mobile: Mapped[str] = mapped_column(String(10))
    purpose: Mapped[str] = mapped_column(String(20))
    code_hash: Mapped[str] = mapped_column(String(100))
    attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # When the verification token made from this OTP was used (it works only once).
    token_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # For UDHAAR_ADD and SUPPLIER_ADD: the shop that asked. Only that shop can use the code.
    requested_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    # What the message said the code is for; it works for nothing else.
    detail: Mapped[str | None] = mapped_column(String(60))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class CalendarEvent(Base):
    """One event or reminder in a user's calendar. Each role has its own
    calendar (the Shop calendar and the Customer calendar never mix)."""

    __tablename__ = "calendar_events"
    __table_args__ = (
        Index("idx_calendar_events_owner", "user_id", "role", "event_date"),
        Index("uq_calendar_events_ref", "user_id", "client_ref", unique=True),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(20))
    title: Mapped[str] = mapped_column(String(120))
    note: Mapped[str | None] = mapped_column(String(500))
    category: Mapped[str] = mapped_column(String(20))
    day: Mapped[date] = mapped_column("event_date", Date)
    time: Mapped[dt.time | None] = mapped_column("event_time", Time)
    repeat: Mapped[str] = mapped_column(String(10), default="NONE", server_default="NONE")
    remind_minutes: Mapped[int | None] = mapped_column(Integer)
    # Made by the phone: the same event sent twice (added offline) is kept once.
    client_ref: Mapped[str | None] = mapped_column(String(40))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Festival(Base):
    """Built-in festivals and holidays, shared by everyone (read-only for users)."""

    __tablename__ = "festivals"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    day: Mapped[date] = mapped_column(Date)
    name: Mapped[str] = mapped_column(String(80))
    region: Mapped[str] = mapped_column(String(10))


class UdhaarCustomer(Base):
    """One customer in one shop's udhaar book. The same person can be in many
    shops' books; each shop sees only its own. Added only after OTP check."""

    __tablename__ = "udhaar_customers"
    __table_args__ = (
        UniqueConstraint("shop_user_id", "mobile", name="udhaar_customers_shop_mobile_key"),
        Index("idx_udhaar_customers_mobile", "mobile"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    mobile: Mapped[str] = mapped_column(String(10))
    credit_limit_paise: Mapped[int | None] = mapped_column(BigInteger)
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # "This is not me": the customer reports, the shop decides (see Dispute).
    dispute_status: Mapped[str] = mapped_column(String(10), default="NONE", server_default="NONE")
    disputed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    dispute_resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class UdhaarEntry(Base):
    """One credit or payment. Never erased: deleting sets deleted_at and a reason."""

    __tablename__ = "udhaar_entries"
    __table_args__ = (
        UniqueConstraint("customer_id", "client_ref", name="udhaar_entries_client_ref_key"),
        Index("idx_udhaar_entries_customer", "customer_id", "entry_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("udhaar_customers.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(10))
    amount_paise: Mapped[int] = mapped_column(BigInteger)
    note: Mapped[str | None] = mapped_column(String(200))
    entry_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    client_ref: Mapped[str] = mapped_column(String(40))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    delete_reason: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class StockItem(Base):
    """One item a shop keeps in stock. Its quantity is always calculated from
    its moves, so it can never go out of step with the history."""

    __tablename__ = "stock_items"
    __table_args__ = (
        UniqueConstraint("shop_user_id", "client_ref", name="stock_items_client_ref_key"),
        Index("idx_stock_items_shop", "shop_user_id"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    # The built-in item it came from (names in 5 languages live in the app).
    catalog_code: Mapped[str | None] = mapped_column(String(40))
    unit: Mapped[str] = mapped_column(String(10))
    cost_paise: Mapped[int | None] = mapped_column(BigInteger)  # buying price per unit
    price_paise: Mapped[int | None] = mapped_column(BigInteger)  # selling price per unit
    alert_milli: Mapped[int | None] = mapped_column(BigInteger)  # "running low" at or below this
    client_ref: Mapped[str] = mapped_column(String(40))
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class StockMove(Base):
    """Stock in, out or corrected. Never erased: a mistake is fixed with a correction."""

    __tablename__ = "stock_moves"
    __table_args__ = (
        UniqueConstraint("item_id", "client_ref", name="stock_moves_client_ref_key"),
        Index("idx_stock_moves_item", "item_id", "move_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    item_id: Mapped[int] = mapped_column(ForeignKey("stock_items.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(10))
    # IN and OUT: always positive. ADJUST: + or - (the change to the count).
    qty_milli: Mapped[int] = mapped_column(BigInteger)
    note: Mapped[str | None] = mapped_column(String(200))
    move_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    client_ref: Mapped[str] = mapped_column(String(40))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Supplier(Base):
    """Someone the shop buys from. The shop's own record; [verified_at] = the
    number was checked with a code the supplier read out."""

    __tablename__ = "suppliers"
    __table_args__ = (
        UniqueConstraint("shop_user_id", "client_ref", name="suppliers_client_ref_key"),
        Index("idx_suppliers_shop", "shop_user_id"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    mobile: Mapped[str | None] = mapped_column(String(10))
    supplies: Mapped[str | None] = mapped_column(String(200))  # "Rice, dal, oil"
    note: Mapped[str | None] = mapped_column(String(300))
    client_ref: Mapped[str] = mapped_column(String(40))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SupplyProduct(Base):
    """Something a supplier sells. Shops connected with them see it."""

    __tablename__ = "supply_products"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    supplier_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    catalog_code: Mapped[str | None] = mapped_column(String(40))
    unit: Mapped[str] = mapped_column(String(10))
    price_paise: Mapped[int | None] = mapped_column(BigInteger)  # per unit
    available: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    # The supplier counts it: at 0, shops see it as not available.
    counted: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    alert_milli: Mapped[int | None] = mapped_column(BigInteger)  # "running low" at or below this
    client_ref: Mapped[str] = mapped_column(String(40))
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SupplyMove(Base):
    """A supplier's own stock in, out or corrected. Never erased."""

    __tablename__ = "supply_moves"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("supply_products.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(10))
    # IN and OUT: always positive. ADJUST: + or - (the change to the count).
    qty_milli: Mapped[int] = mapped_column(BigInteger)
    note: Mapped[str | None] = mapped_column(String(200))
    move_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    client_ref: Mapped[str] = mapped_column(String(40))


class SupplyPay(Base):
    """A supplier's own UPI ID, for shops connected with them."""

    __tablename__ = "supply_pay"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    upi_id: Mapped[str | None] = mapped_column(String(60))
    upi_name: Mapped[str | None] = mapped_column(String(60))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SupplyLink(Base):
    """A supplier in a shop's list connected with a QBOX Supplier account. The
    account between them starts at [opening_paise], agreed when connecting."""

    __tablename__ = "supply_links"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id", ondelete="CASCADE"))
    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    supplier_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    status: Mapped[str] = mapped_column(String(10))
    asked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decline_reason: Mapped[str | None] = mapped_column(String(200))
    opening_paise: Mapped[int | None] = mapped_column(BigInteger)
    opening_entry_id: Mapped[int | None] = mapped_column(BigInteger)  # the last entry before connecting
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_by_shop: Mapped[bool | None] = mapped_column(Boolean)


class SupplierEntry(Base):
    """A purchase or a payment in the shop's account with a supplier.
    Never erased: deleting sets deleted_at and a reason."""

    __tablename__ = "supplier_entries"
    __table_args__ = (
        UniqueConstraint("supplier_id", "client_ref", name="supplier_entries_client_ref_key"),
        Index("idx_supplier_entries_supplier", "supplier_id", "entry_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(10))
    amount_paise: Mapped[int] = mapped_column(BigInteger)
    note: Mapped[str | None] = mapped_column(String(200))
    entry_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    due_date: Mapped[date | None] = mapped_column(Date)  # purchases on credit: pay by
    method: Mapped[str | None] = mapped_column(String(10))  # payments: cash / UPI / bank
    order_id: Mapped[int | None] = mapped_column(ForeignKey("supplier_orders.id", ondelete="SET NULL"))
    client_ref: Mapped[str] = mapped_column(String(40))
    # Written while connected: shared with the other side, who answers (see Confirm).
    by_supplier: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    link_id: Mapped[int | None] = mapped_column(ForeignKey("supply_links.id", ondelete="SET NULL"))
    confirm: Mapped[str | None] = mapped_column(String(10))
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    dispute_reason: Mapped[str | None] = mapped_column(String(200))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    delete_reason: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SupplierEntryLine(Base):
    """An item bought in a purchase. Each line added a stock move (stock in)."""

    __tablename__ = "supplier_entry_lines"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    entry_id: Mapped[int] = mapped_column(ForeignKey("supplier_entries.id", ondelete="CASCADE"), index=True)
    item_id: Mapped[int | None] = mapped_column(ForeignKey("stock_items.id", ondelete="SET NULL"))
    name: Mapped[str] = mapped_column(String(80))  # the item's name at the time
    unit: Mapped[str] = mapped_column(String(10))
    qty_milli: Mapped[int] = mapped_column(BigInteger)
    cost_paise: Mapped[int | None] = mapped_column(BigInteger)  # per unit
    catalog_code: Mapped[str | None] = mapped_column(String(40))


class SupplierOrder(Base):
    """An order sent to a supplier (on WhatsApp, or in QBOX when connected).
    Received = a purchase."""

    __tablename__ = "supplier_orders"
    __table_args__ = (
        UniqueConstraint("supplier_id", "client_ref", name="supplier_orders_client_ref_key"),
        Index("idx_supplier_orders_supplier", "supplier_id", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id", ondelete="CASCADE"))
    status: Mapped[str] = mapped_column(String(10))
    note: Mapped[str | None] = mapped_column(String(200))
    client_ref: Mapped[str] = mapped_column(String(40))
    link_id: Mapped[int | None] = mapped_column(ForeignKey("supply_links.id", ondelete="SET NULL"))
    pay_plan: Mapped[str | None] = mapped_column(String(10))
    pay_by: Mapped[date | None] = mapped_column(Date)
    total_paise: Mapped[int | None] = mapped_column(BigInteger)  # the supplier's bill
    answer_note: Mapped[str | None] = mapped_column(String(200))
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    dispatched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SupplierOrderLine(Base):
    __tablename__ = "supplier_order_lines"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    catalog_code: Mapped[str | None] = mapped_column(String(40))
    order_id: Mapped[int] = mapped_column(ForeignKey("supplier_orders.id", ondelete="CASCADE"), index=True)
    item_id: Mapped[int | None] = mapped_column(ForeignKey("stock_items.id", ondelete="SET NULL"))
    name: Mapped[str] = mapped_column(String(80))
    unit: Mapped[str] = mapped_column(String(10))
    qty_milli: Mapped[int] = mapped_column(BigInteger)
    cost_paise: Mapped[int | None] = mapped_column(BigInteger)  # the supplier's price per unit
    # Chosen from the supplier's products.
    product_id: Mapped[int | None] = mapped_column(ForeignKey("supply_products.id", ondelete="SET NULL"))
    available: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")


class ShopPaymentSettings(Base):
    """How a shop takes payments: its own UPI ID, and/or its own Razorpay account.
    The Razorpay secret key is stored encrypted and never sent to any phone."""

    __tablename__ = "shop_payment_settings"

    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    upi_id: Mapped[str | None] = mapped_column(String(60))
    upi_name: Mapped[str | None] = mapped_column(String(60))
    razorpay_key_id: Mapped[str | None] = mapped_column(String(40))
    razorpay_secret: Mapped[str | None] = mapped_column(String(500))  # encrypted
    razorpay_connected_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # In the shop's QBOX QR: random (cannot be guessed), not the phone number.
    pay_code: Mapped[str | None] = mapped_column(String(16), unique=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Payment(Base):
    """One payment to a shop: asked for (WAITING), then PAID, EXPIRED or CANCELLED.
    A Razorpay payment is counted only once (gateway_payment_id is unique)."""

    __tablename__ = "payments"
    __table_args__ = (
        UniqueConstraint("shop_user_id", "client_ref", name="payments_shop_client_ref_key"),
        Index("idx_payments_shop", "shop_user_id", "status", "paid_at"),
        CheckConstraint("source IN ('COUNTER', 'UDHAAR', 'MANUAL', 'DIRECT')", name="payments_source_check"),
        CheckConstraint("status IN ('WAITING', 'PAID', 'EXPIRED', 'CANCELLED')", name="payments_status_check"),
        CheckConstraint("amount_paise > 0", name="payments_amount_check"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    shop_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source: Mapped[str] = mapped_column(String(10))
    status: Mapped[str] = mapped_column(String(10))
    amount_paise: Mapped[int] = mapped_column(BigInteger)
    note: Mapped[str | None] = mapped_column(String(100))
    # Set when the payment is for udhaar: a PAYMENT entry is added there once paid.
    udhaar_customer_id: Mapped[int | None] = mapped_column(ForeignKey("udhaar_customers.id", ondelete="SET NULL"))
    udhaar_entry_id: Mapped[int | None] = mapped_column(ForeignKey("udhaar_entries.id", ondelete="SET NULL"))
    # The customer who paid from their own QBOX app (UDHAAR and DIRECT payments).
    payer_user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    gateway: Mapped[str | None] = mapped_column(String(15))
    gateway_ref: Mapped[str | None] = mapped_column(String(40), unique=True)  # qr_..., plink_..., order_...
    gateway_key_id: Mapped[str | None] = mapped_column(String(40))  # which Razorpay account
    qr_image_url: Mapped[str | None] = mapped_column(String(300))
    pay_url: Mapped[str | None] = mapped_column(String(300))
    gateway_payment_id: Mapped[str | None] = mapped_column(String(40), unique=True)  # pay_...
    payer_vpa: Mapped[str | None] = mapped_column(String(100))
    method: Mapped[str | None] = mapped_column(String(20))
    client_ref: Mapped[str] = mapped_column(String(40))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # DIRECT by UPI: when the customer said they paid (the shop then confirms).
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # ... and the shop answered
    checked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class CustomerRecord(Base):
    """A payment the customer added themselves (cash, another app, or a QR they
    scanned in QBOX). Private to them; QBOX cannot confirm it."""

    __tablename__ = "customer_records"
    __table_args__ = (
        UniqueConstraint("user_id", "client_ref", name="customer_records_client_ref_key"),
        Index("idx_customer_records_user", "user_id", "spent_at"),
        CheckConstraint("amount_paise > 0", name="customer_records_amount_check"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    scanned: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    title: Mapped[str] = mapped_column(String(80))
    upi_id: Mapped[str | None] = mapped_column(String(330))
    amount_paise: Mapped[int] = mapped_column(BigInteger)
    category: Mapped[str] = mapped_column(String(20))
    spent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    note: Mapped[str | None] = mapped_column(String(200))
    # They said it is not the same payment as another one of that day.
    not_same: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    # They said it is: kept in the history, not counted.
    same: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    client_ref: Mapped[str] = mapped_column(String(40))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ExpenseMark(Base):
    """The customer's choice about an automatic expense ("entry-12", "payment-5"):
    its category, or left out. The udhaar line or payment itself is not changed."""

    __tablename__ = "expense_marks"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    item: Mapped[str] = mapped_column(String(40), primary_key=True)
    category: Mapped[str | None] = mapped_column(String(20))
    hidden: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")


class ExpenseBudget(Base):
    """How much the customer wants to spend in a month."""

    __tablename__ = "expense_budgets"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    month_paise: Mapped[int] = mapped_column(BigInteger)


class NoticeSettings(Base):
    """The bell of one role: everything up to [read_to] is read; kinds switched off."""

    __tablename__ = "notice_settings"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String(20), primary_key=True)
    read_to: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    off: Mapped[list] = mapped_column(JSONB, default=list, server_default="[]")


class NoticeRead(Base):
    """One thing in the bell that was opened."""

    __tablename__ = "notice_reads"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String(20), primary_key=True)
    notice: Mapped[str] = mapped_column(String(60), primary_key=True)
    read_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class PushDevice(Base):
    """A phone that gets push notifications for this user (Firebase Cloud Messaging).
    Made with the login that was valid then: after "log out from all phones" or a PIN
    reset it gets nothing more."""

    __tablename__ = "push_devices"

    token: Mapped[str] = mapped_column(String(400), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_version: Mapped[int] = mapped_column(Integer)
    # "Speak aloud" on this phone: the kinds of bell news said aloud, as "ROLE:TYPE"
    # ("BUSINESS:PAYMENT"). Those alerts come as data the app shows and speaks.
    speak: Mapped[list] = mapped_column(JSONB, default=list, server_default="[]")
    # Quiet hours on this phone, in minutes after midnight (Indian time); none = never quiet.
    quiet_from: Mapped[int | None] = mapped_column(Integer)
    quiet_to: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class NoticePush(Base):
    """One thing in the bell that was sent to the phones, so it is sent only once."""

    __tablename__ = "notice_pushes"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String(20), primary_key=True)
    notice: Mapped[str] = mapped_column(String(60), primary_key=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class PageKind(str, enum.Enum):
    LIST = "LIST"  # a checklist
    NOTE = "NOTE"


class CustomerPage(Base):
    """One of the customer's lists or notes. Private to them. A deleted one keeps
    only its id, so an old retry cannot bring it back."""

    __tablename__ = "customer_pages"
    __table_args__ = (
        UniqueConstraint("user_id", "client_ref", name="customer_pages_client_ref_key"),
        CheckConstraint("kind IN ('LIST', 'NOTE')", name="customer_pages_kind_check"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    client_ref: Mapped[str] = mapped_column(String(40))
    kind: Mapped[str] = mapped_column(String(10))
    title: Mapped[str] = mapped_column(String(80), default="", server_default="")
    text: Mapped[str] = mapped_column(Text, default="", server_default="")
    items: Mapped[list] = mapped_column(JSONB, default=list, server_default="[]")  # [{ref, text, qty, done}]
    pinned: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    version: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    save_ref: Mapped[str] = mapped_column(String(40))  # the last save (a retry of it counts once)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
