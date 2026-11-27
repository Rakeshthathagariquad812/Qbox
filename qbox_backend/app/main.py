"""QBOX backend entry point.

Run (from the qbox_backend folder):
    .venv\\Scripts\\python -m uvicorn app.main:app --reload --port 8080

API docs with "Try it out" buttons: http://localhost:8080/docs
(switched off when QBOX_APP_ENV=production, so outsiders cannot browse the API)
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.auth.router import router as auth_router
from app.calendar.router import router as calendar_router
from app.config import get_settings
from app.customer.router import router as customer_router
from app.database import engine
from app.errors import ApiError, register_error_handlers
from app.language.router import router as language_router
from app.legal.router import router as legal_router
from app.notices.router import router as notices_router
from app.payments.router import router as payments_router
from app.push import service as push
from app.push.router import router as push_router
from app.security import read_access
from app.stock.router import router as stock_router
from app.suppliers.router import router as suppliers_router
from app.supply.router import router as supply_router
from app.udhaar.router import router as udhaar_router
from app.users.router import router as users_router

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("qbox")

_docs = not get_settings().is_production


@asynccontextmanager
async def _lifespan(_: FastAPI):
    push.start()  # push notifications, when the Firebase key is set
    yield


app = FastAPI(
    lifespan=_lifespan,
    title="QBOX API",
    description="Accounts, login and business data for the QBOX app.",
    version="0.4.0",
    docs_url="/docs" if _docs else None,
    redoc_url="/redoc" if _docs else None,
    openapi_url="/openapi.json" if _docs else None,
)
register_error_handlers(app)

# The biggest real request is a voice recording (under 3 MB). Anything larger is
# refused before it is read, so nobody can fill the server's memory.
MAX_BODY_BYTES = 4 * 1024 * 1024


@app.middleware("http")
async def limit_body_size(request: Request, call_next):
    length = request.headers.get("content-length")
    if length is not None and (not length.isdigit() or int(length) > MAX_BODY_BYTES):
        return JSONResponse(status_code=413, content={"code": "TOO_LARGE", "message": "This request is too large"})
    if length is None and "chunked" in request.headers.get("transfer-encoding", "").lower():
        # A body of unknown size (the QBOX app always gives the size): refused.
        return JSONResponse(status_code=411, content={"code": "LENGTH_REQUIRED", "message": "Request size missing"})
    return await call_next(request)


WRITES = {"POST", "PUT", "PATCH", "DELETE"}


@app.middleware("http")
async def push_after_changes(request: Request, call_next):
    """A change that worked: its people get their push notifications straight away."""
    response = await call_next(request)
    auth = request.headers.get("authorization", "")
    if request.method in WRITES and response.status_code < 400 and auth.startswith("Bearer ") and push.is_on():
        try:
            user_id, _ = read_access(auth.removeprefix("Bearer ").strip())
            push.poke(user_id)
        except ApiError:
            pass
    return response


app.include_router(auth_router)
app.include_router(users_router)
app.include_router(calendar_router)
app.include_router(udhaar_router)
app.include_router(language_router)
app.include_router(payments_router)
app.include_router(stock_router)
app.include_router(suppliers_router)
app.include_router(supply_router)
app.include_router(customer_router)
app.include_router(notices_router)
app.include_router(legal_router)
app.include_router(push_router)


@app.get("/health", tags=["Health"], summary="Is the server (and database) up?")
def health():
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError:
        log.warning("Health check: database is not reachable")
        return JSONResponse(status_code=503, content={"status": "DOWN"})
    return {"status": "UP"}
