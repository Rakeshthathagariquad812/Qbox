"""This phone gets push notifications, or stops (log out). Rules in service.py."""

from typing import Annotated

from fastapi import APIRouter, Depends, status
from pydantic import Field, field_validator
from sqlalchemy.orm import Session

from app.database import get_db
from app.deps import current_user
from app.models import User
from app.push import service
from app.schemas import CamelModel

router = APIRouter(prefix="/api/devices", tags=["Push notifications"])


class DeviceIn(CamelModel):
    token: Annotated[str, Field(min_length=20, max_length=400)]


class RegisterIn(DeviceIn):
    # The kinds of bell news this phone says aloud: "BUSINESS:PAYMENT", "CUSTOMER:UDHAAR"...
    speak: Annotated[list[Annotated[str, Field(max_length=30)]], Field(max_length=40)] = []
    # Quiet hours (silent, not said aloud), in minutes after midnight; both empty = none.
    quiet_from: Annotated[int | None, Field(ge=0, lt=24 * 60)] = None
    quiet_to: Annotated[int | None, Field(ge=0, lt=24 * 60)] = None

    @field_validator("speak", mode="before")
    @classmethod
    def _earlier_builds(cls, value):
        """Earlier test builds sent true/false or OFF/MONEY/ALL."""
        if value is True or value == "MONEY":
            return service.MONEY_SPOKEN
        if value == "ALL":
            return service.ALL_SPOKEN
        if value is False or value == "OFF" or value is None:
            return []
        return value


@router.post("", status_code=status.HTTP_204_NO_CONTENT, summary="Send my notifications to this phone")
def register(body: RegisterIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    service.register(db, user, body.token, speak=body.speak, quiet_from=body.quiet_from, quiet_to=body.quiet_to)


@router.post("/forget", status_code=status.HTTP_204_NO_CONTENT, summary="Stop notifications on this phone")
def forget(body: DeviceIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    service.forget(db, user, body.token)
