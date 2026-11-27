"""Push notifications: which kinds of bell news each phone says aloud, and its quiet hours.

Revision ID: 0024
Revises: 0023
Create Date: 2026-11-27
"""

from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE push_devices ADD COLUMN speak JSONB NOT NULL DEFAULT '[]'")
    op.execute("ALTER TABLE push_devices ADD COLUMN quiet_from INTEGER")
    op.execute("ALTER TABLE push_devices ADD COLUMN quiet_to INTEGER")
    op.execute("ALTER TABLE push_devices ADD CONSTRAINT push_devices_quiet_check CHECK ("
               "(quiet_from IS NULL AND quiet_to IS NULL) OR "
               "(quiet_from BETWEEN 0 AND 1439 AND quiet_to BETWEEN 0 AND 1439))")


def downgrade() -> None:
    op.execute("ALTER TABLE push_devices DROP COLUMN IF EXISTS quiet_to")
    op.execute("ALTER TABLE push_devices DROP COLUMN IF EXISTS quiet_from")
    op.execute("ALTER TABLE push_devices DROP COLUMN speak")
