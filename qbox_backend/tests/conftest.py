"""Test setup. Tests use a separate database (qbox_test) so real data is never touched.

Create it once:
    psql -U postgres -h localhost -c "CREATE DATABASE qbox_test OWNER qbox;"
"""

import os

os.environ.setdefault(
    "QBOX_DATABASE_URL", "postgresql+pg8000://qbox:qbox_dev_2026@localhost:5432/qbox_test"
)
# All test requests come from one address; the per-device limit has its own test.
for _limit in ("REQUESTS_PER_IP", "WRONG_PER_IP", "CODES_PER_IP", "REQUESTS_PER_MOBILE"):
    os.environ.setdefault(f"QBOX_AUTH_{_limit}_10MIN", "0")
# Tests never touch a real Razorpay account (the test keys in .env are ignored);
# payment tests use a pretend Razorpay.
os.environ["QBOX_RAZORPAY_KEY_ID"] = ""
os.environ["QBOX_RAZORPAY_KEY_SECRET"] = ""
# ...and never send real push notifications (push tests use a pretend sender).
os.environ["QBOX_FIREBASE_KEY_FILE"] = ""

import pytest  # noqa: E402
from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.database import engine  # noqa: E402
from app.main import app  # noqa: E402

_ROOT = os.path.dirname(os.path.dirname(__file__))


@pytest.fixture(scope="session", autouse=True)
def _tables():
    """Builds the tables in qbox_test with the same migrations as the real database."""
    config = Config(os.path.join(_ROOT, "alembic.ini"))
    config.set_main_option("script_location", os.path.join(_ROOT, "alembic"))
    command.upgrade(config, "head")


@pytest.fixture(autouse=True)
def _empty_tables():
    with engine.begin() as connection:
        connection.execute(text("TRUNCATE otp_codes, users RESTART IDENTITY CASCADE"))


@pytest.fixture
def client():
    return TestClient(app)
