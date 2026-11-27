"""All settings in one place.

Values come from environment variables or the .env file, with safe
development defaults below. On a real server, set them in the environment
and set QBOX_APP_ENV=production: the server then refuses to start while any
development-only setting is still switched on.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

DEV_JWT_SECRET = "qbox-dev-only-secret-change-me-before-going-live-2026"
DEV_AI_KEY = "qbox-ai-dev-only-key-change-me"
DEV_PAYMENT_KEY = "qbox-dev-only-payment-key-change-me-2026"
DEV_DB_PASSWORD = "qbox_dev_2026"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="QBOX_", extra="ignore")

    # "dev" on this PC, "production" on the real server.
    app_env: str = "dev"

    # PostgreSQL connection. pg8000 is pure Python (no DLLs), so Windows Smart App
    # Control cannot block it.
    database_url: str = f"postgresql+pg8000://qbox:{DEV_DB_PASSWORD}@localhost:5432/qbox"
    # Connections kept open, and how many more for a busy moment (per server process).
    db_pool_size: int = 10
    db_pool_extra: int = 20
    db_pool_wait_seconds: int = 10

    # Login tokens. Development key only: set QBOX_JWT_SECRET (32+ characters) when going live.
    jwt_secret: str = DEV_JWT_SECRET
    access_token_days: int = 30
    verification_token_minutes: int = 30

    # OTP rules
    otp_expiry_seconds: int = 300
    otp_resend_seconds: int = 30
    otp_max_attempts: int = 5
    otp_max_per_hour: int = 5
    # Test mode: no SMS provider yet, so the OTP is printed in the log and sent
    # back to the app. Set QBOX_OTP_EXPOSE=false once real SMS is connected.
    otp_expose: bool = True

    # Udhaar: one shop may send this many "add customer" OTPs per hour (stops SMS misuse).
    udhaar_invites_per_hour: int = 10

    # QBOX AI server (folder qbox_ai): AI4Bharat IndicConformer speech-to-text and
    # IndicTrans2 translation on our own machine. Empty URL = switched off, and the
    # app uses the phone's own free speech/translation instead.
    ai_url: str = "http://127.0.0.1:8090"
    # Shared secret: must be the same as QBOX_AI_KEY in qbox_ai/.env. Change it when going live.
    ai_key: str = DEV_AI_KEY
    # Speech + translation requests one person may make per day (protects the AI server).
    language_daily_limit: int = 600  # a spoken command may ask twice
    # Speech and translation requests at the same moment; more are refused at once (the
    # app then uses the phone's own) instead of making everything wait.
    language_at_once: int = 12

    @property
    def ai_on(self) -> bool:
        return bool(self.ai_url and self.ai_key)

    # Payments (Razorpay). Each shop connects its OWN Razorpay account, so money
    # goes straight to that shop's bank and never through QBOX.
    # For testing on this PC only: shops that have not connected their own
    # account use this one (put the test keys in .env). Refused in production:
    # one account collecting money for many shops is not allowed.
    razorpay_key_id: str = ""
    razorpay_key_secret: str = ""
    # Encrypts each shop's Razorpay secret key in the database. Change it when going live.
    payment_secret_key: str = DEV_PAYMENT_KEY
    # How long a counter QR stays valid.
    payment_qr_minutes: int = 20

    @property
    def razorpay_test_account_on(self) -> bool:
        return bool(self.razorpay_key_id and self.razorpay_key_secret) and not self.is_production

    # Push notifications (Firebase Cloud Messaging): the path of the Firebase server key
    # file (Firebase console, Project settings, Service accounts). Empty = switched off.
    # It is a secret: never upload it.
    firebase_key_file: str = ""

    # Shown in Help and on the privacy page. Set them before going live (the privacy
    # policy needs a way to complain).
    support_name: str = ""
    support_phone: str = ""
    support_email: str = ""

    # Wrong-PIN lock: every 5th wrong PIN in a row locks the account.
    # The first lock is short; later ones are long, so guessing a 4-digit PIN is not practical.
    login_max_failed_attempts: int = 5
    login_lock_minutes: int = 15
    login_long_lock_minutes: int = 24 * 60

    # Login, OTP and PIN-reset limits per 10 minutes. 0 = off. Behind a proxy, start uvicorn
    # with --proxy-headers so the real address is seen.
    # Many people on mobile data share one address, so the limit for an address is high...
    auth_requests_per_ip_10min: int = 600
    # ...but few of them type a wrong PIN or code: this is what stops trying one easy PIN on
    # thousands of numbers.
    auth_wrong_per_ip_10min: int = 60
    # New codes (each costs an SMS) asked for from one address.
    auth_codes_per_ip_10min: int = 60
    # One mobile number, from anywhere.
    auth_requests_per_mobile_10min: int = 20

    # The app: versions (build numbers) below this must update before they can be used.
    # 0 = any. The link is where the Update button goes.
    app_min_build: int = 0
    app_update_url: str = ""

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"


def check_settings(settings: Settings) -> Settings:
    if len(settings.jwt_secret.encode()) < 32:
        raise ValueError("QBOX_JWT_SECRET must be at least 32 characters")
    if settings.is_production:
        if settings.jwt_secret == DEV_JWT_SECRET:
            raise ValueError("Set a private QBOX_JWT_SECRET before running in production")
        if settings.otp_expose:
            raise ValueError("Set QBOX_OTP_EXPOSE=false in production (OTPs must only go by SMS)")
        if settings.ai_url and (settings.ai_key == DEV_AI_KEY or len(settings.ai_key) < 32):
            raise ValueError("Set a private QBOX_AI_KEY (32+ characters) in production, "
                             "the same in qbox_ai/.env")
        if settings.payment_secret_key == DEV_PAYMENT_KEY or len(settings.payment_secret_key) < 32:
            raise ValueError("Set a private QBOX_PAYMENT_SECRET_KEY (32+ characters) in production. "
                             "Keep it safe: without it, saved Razorpay keys cannot be read")
        if DEV_DB_PASSWORD in settings.database_url:
            raise ValueError("Set QBOX_DATABASE_URL with a private password in production")
        if not (settings.support_phone or settings.support_email):
            raise ValueError("Set QBOX_SUPPORT_PHONE or QBOX_SUPPORT_EMAIL in production "
                             "(the privacy policy needs a way to reach you)")
        if settings.app_update_url and not settings.app_update_url.startswith("https://"):
            raise ValueError("QBOX_APP_UPDATE_URL must start with https://")
        if min(settings.auth_requests_per_ip_10min, settings.auth_wrong_per_ip_10min,
               settings.auth_codes_per_ip_10min, settings.auth_requests_per_mobile_10min) <= 0:
            raise ValueError("The login limits (QBOX_AUTH_...) must not be switched off in production")
        if settings.razorpay_key_id or settings.razorpay_key_secret:
            raise ValueError("Remove QBOX_RAZORPAY_KEY_ID/SECRET in production: "
                             "each shop connects its own Razorpay account")
    return settings


@lru_cache
def get_settings() -> Settings:
    return check_settings(Settings())
