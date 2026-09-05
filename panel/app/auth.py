import hashlib
import hmac
import os
import time
import jwt
from fastapi import HTTPException, Header
from . import config


def hash_password(password: str, salt: str = None) -> str:
    salt = salt or os.urandom(16).hex()
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
    return f"{salt}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        salt, digest_hex = stored.split("$", 1)
    except ValueError:
        return False
    check = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
    return hmac.compare_digest(check.hex(), digest_hex)


def create_token(username: str) -> str:
    payload = {"sub": username, "iat": int(time.time()), "exp": int(time.time()) + 60 * 60 * 24 * 7}
    return jwt.encode(payload, config.JWT_SECRET, algorithm="HS256")


def verify_token(token: str) -> str:
    try:
        payload = jwt.decode(token, config.JWT_SECRET, algorithms=["HS256"])
        return payload["sub"]
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="توکن نامعتبر یا منقضی شده")


def require_auth(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="نیاز به ورود")
    token = authorization.split(" ", 1)[1]
    return verify_token(token)
