"""Opaque keyset cursors: stable order without a fixed history cutoff."""
import base64
import binascii
from datetime import datetime
import json
import uuid

from fastapi import HTTPException
from sqlalchemy import and_, or_


def encode_cursor(item) -> str:
    return base64.urlsafe_b64encode(json.dumps(
        [item.created_at.isoformat(), str(item.id)], separators=(",", ":")
    ).encode()).decode().rstrip("=")


def after_cursor(query, model, cursor: str | None):
    if not cursor:
        return query
    try:
        if len(cursor) > 300:
            raise ValueError()
        values = json.loads(base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True))
        if not isinstance(values, list) or len(values) != 2:
            raise ValueError()
        timestamp, key = datetime.fromisoformat(values[0]), uuid.UUID(values[1])
    except (ValueError, TypeError, binascii.Error, OverflowError) as error:
        raise HTTPException(422, "Неверная страница. Обновите список") from error
    return query.where(or_(model.created_at < timestamp,
                           and_(model.created_at == timestamp, model.id < key)))
