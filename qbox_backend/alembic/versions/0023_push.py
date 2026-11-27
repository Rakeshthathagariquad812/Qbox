"""Push notifications: the phones that get them, and what was already sent.

Revision ID: 0023
Revises: 0022
Create Date: 2026-11-27
"""

from alembic import op

revision = "0023"
down_revision = "0022"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("""
        CREATE TABLE push_devices (
            token VARCHAR(400) PRIMARY KEY,
            user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token_version INTEGER NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
    """)
    op.execute("CREATE INDEX ix_push_devices_user_id ON push_devices (user_id)")
    op.execute("""
        CREATE TABLE notice_pushes (
            user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            role VARCHAR(20) NOT NULL,
            notice VARCHAR(60) NOT NULL,
            at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (user_id, role, notice)
        )
    """)


def downgrade() -> None:
    op.execute("DROP TABLE notice_pushes")
    op.execute("DROP TABLE push_devices")
