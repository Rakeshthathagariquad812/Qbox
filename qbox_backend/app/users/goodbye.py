"""Deleting one's own account.

- Everything private goes: details, photos, PIN, calendar, notes, expenses, stock,
  products, UPI IDs and payment keys, the bell, push notifications, codes.
- What is also someone else's record stays, without the private details: a shop's
  udhaar lines (the customer can still see what they owe or paid), payments, and
  what a shop and a supplier shared.
- The number is free again: signing up later makes a new, empty account.
- It cannot be undone. Payments still on the way must be finished first.
"""

from datetime import UTC, datetime

from sqlalchemy import delete, or_, select, update
from sqlalchemy.orm import Session

from app.auth import service as auth
from app.errors import ApiError
from app.models import (
    CalendarEvent,
    CustomerPage,
    CustomerProfile,
    CustomerRecord,
    ExpenseBudget,
    ExpenseMark,
    NoticeRead,
    NoticeSettings,
    OtpCode,
    Payment,
    PaymentStatus,
    ProfilePhoto,
    Role,
    ShopPaymentSettings,
    ShopProfile,
    StockItem,
    Supplier,
    SupplierEntry,
    SupplierOrder,
    SupplierProfile,
    SupplyLink,
    SupplyPay,
    SupplyProduct,
    UdhaarCustomer,
    UdhaarEntry,
    User,
    UserRole,
)
from app.push import service as push
from app.suppliers import service as suppliers
from app.supply import links
from app.supply import service as supply
from app.udhaar import service as udhaar
from app.users.schemas import DeleteCheckOut


def check(db: Session, user: User) -> DeleteCheckOut:
    """What the user should know before deleting."""
    roles = {r.role for r in user.roles}
    out = DeleteCheckOut(you_owe_paise=0, owed_to_you_paise=0, payments_open=_payments_open(db, user))
    if Role.CUSTOMER.value in roles:
        out.you_owe_paise += sum(b.balance_paise for b in udhaar.my_books(db, user) if b.balance_paise > 0)
    if Role.BUSINESS.value in roles:
        out.owed_to_you_paise += sum(c.balance_paise for c in udhaar.get_book(db, user).customers if c.balance_paise > 0)
        out.you_owe_paise += suppliers.get_suppliers(db, user).total_due_paise
    if Role.SUPPLIER.value in roles:
        out.owed_to_you_paise += supply.home(db, user).total_due_paise
    return out


def delete_account(db: Session, user: User, pin: str) -> None:
    db.refresh(user, with_for_update=True)
    auth.check_pin(db, user, pin, ApiError(400, "WRONG_PIN", "The PIN is not right"))
    if _payments_open(db, user):
        db.rollback()
        raise ApiError(409, "PAYMENTS_OPEN", "A payment to your shop is not finished. Answer it first, then delete")
    now = datetime.now(UTC)
    me, mobile = user.id, user.mobile
    _leave_shops_and_suppliers(db, me, now)

    for table, column in (
        (ProfilePhoto, ProfilePhoto.user_id), (CalendarEvent, CalendarEvent.user_id),
        (CustomerRecord, CustomerRecord.user_id), (ExpenseMark, ExpenseMark.user_id),
        (ExpenseBudget, ExpenseBudget.user_id), (CustomerPage, CustomerPage.user_id),
        (NoticeSettings, NoticeSettings.user_id), (NoticeRead, NoticeRead.user_id),
        (StockItem, StockItem.shop_user_id), (SupplyProduct, SupplyProduct.supplier_user_id),
        (SupplyPay, SupplyPay.user_id), (ShopPaymentSettings, ShopPaymentSettings.shop_user_id),
        (CustomerProfile, CustomerProfile.user_id), (SupplierProfile, SupplierProfile.user_id),
        (UserRole, UserRole.user_id),
    ):
        db.execute(delete(table).where(column == me))
    db.execute(delete(OtpCode).where(or_(OtpCode.mobile == mobile, OtpCode.requested_by == me)))
    push.forget_all(db, me)

    # A shop's book: only lines its customers can still look at.
    db.execute(delete(UdhaarCustomer).where(
        UdhaarCustomer.shop_user_id == me,
        ~select(UdhaarEntry.id).where(UdhaarEntry.customer_id == UdhaarCustomer.id).exists()))
    db.execute(update(UdhaarCustomer).where(UdhaarCustomer.shop_user_id == me).values(credit_limit_paise=None))
    # The shop's name stays, so people know whose record it is.
    db.execute(update(ShopProfile).where(ShopProfile.user_id == me).values(
        qbox_id=f"DEL{me}", business_type="", business_type_detail=None, shop_category="",
        shop_category_detail=None, address="", contact_number=""))
    db.execute(update(Payment).where(Payment.payer_user_id == me).values(payer_vpa=None))

    db.execute(update(User).where(User.id == me).values(
        mobile=f"D{me:09d}", pin_hash="", deleted_at=now, token_version=User.token_version + 1,
        failed_login_attempts=0, locked_until=None))
    db.commit()
    db.expire_all()


def _leave_shops_and_suppliers(db: Session, me: int, now: datetime) -> None:
    """Disconnects everyone. What was shared stays readable for the other side."""
    for link in db.scalars(select(SupplyLink).where(SupplyLink.supplier_user_id == me,
                                                    SupplyLink.status.in_(links.LIVE))).all():
        links.end(db, link.supplier_id, by_shop=False)
    mine = db.scalars(select(Supplier).where(Supplier.shop_user_id == me)).all()
    shared = set(db.scalars(select(SupplyLink.supplier_id).where(SupplyLink.shop_user_id == me,
                                                                 SupplyLink.opening_paise.is_not(None))))
    for supplier in mine:
        links.end(db, supplier.id, by_shop=True)
        if supplier.id not in shared:
            db.execute(delete(Supplier).where(Supplier.id == supplier.id))
            continue
        db.execute(delete(SupplierEntry).where(SupplierEntry.supplier_id == supplier.id, SupplierEntry.link_id.is_(None)))
        db.execute(delete(SupplierOrder).where(SupplierOrder.supplier_id == supplier.id, SupplierOrder.link_id.is_(None)))
        db.execute(update(Supplier).where(Supplier.id == supplier.id).values(
            name=f"Supplier {supplier.id}", mobile=None, supplies=None, note=None, verified_at=None, archived_at=now))
    db.flush()


def _payments_open(db: Session, user: User) -> bool:
    """Money may be on its way to this shop."""
    return db.scalars(
        select(Payment.id).where(
            Payment.shop_user_id == user.id, Payment.status == PaymentStatus.WAITING.value,
            or_(Payment.claimed_at.is_not(None), Payment.expires_at > datetime.now(UTC)))
    ).first() is not None
