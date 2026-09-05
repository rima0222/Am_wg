import asyncio
import ipaddress
import qrcode
import io
import base64
from pathlib import Path
from fastapi import FastAPI, Depends, HTTPException
from fastapi.responses import PlainTextResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional

from . import config, database, awg, auth

app = FastAPI(title="AmneziaWG Panel")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------- schemas ----------
class LoginRequest(BaseModel):
    username: str
    password: str


class CreatePeerRequest(BaseModel):
    name: str
    note: Optional[str] = ""
    expires_at: Optional[int] = None       # unix timestamp یا None
    data_limit_gb: Optional[float] = None  # None یعنی نامحدود


class UpdatePeerRequest(BaseModel):
    enabled: Optional[bool] = None
    note: Optional[str] = None
    expires_at: Optional[int] = None
    data_limit_gb: Optional[float] = None


# ---------- startup ----------
@app.on_event("startup")
async def startup():
    database.init_db()
    asyncio.create_task(stats_loop())
    asyncio.create_task(enforcement_loop())


# ---------- auth ----------
@app.post("/api/login")
def login(body: LoginRequest):
    if body.username != config.ADMIN_USERNAME or not auth.verify_password(
        body.password, config.ADMIN_PASSWORD_HASH
    ):
        raise HTTPException(status_code=401, detail="نام کاربری یا رمز عبور اشتباه است")
    return {"token": auth.create_token(body.username)}


# ---------- peers ----------
def _subnet_base() -> str:
    net = ipaddress.ip_network(config.SERVER_SUBNET, strict=False)
    parts = str(net.network_address).split(".")
    return ".".join(parts[:3])


@app.get("/api/peers")
def list_peers(_=Depends(auth.require_auth)):
    live = awg.dump()
    now = database.now()
    result = []
    with database.cursor() as cur:
        cur.execute(
            """SELECT p.*, s.cumulative_rx, s.cumulative_tx, s.last_handshake
               FROM peers p LEFT JOIN peer_stats s ON s.peer_id = p.id
               ORDER BY p.created_at DESC"""
        )
        for row in cur.fetchall():
            live_info = live.get(row["public_key"], {})
            last_handshake = live_info.get("latest_handshake") or row["last_handshake"] or 0
            online = bool(last_handshake) and (now - last_handshake) < config.ONLINE_THRESHOLD_SECONDS
            result.append(
                {
                    "id": row["id"],
                    "name": row["name"],
                    "ip_address": row["ip_address"],
                    "note": row["note"],
                    "enabled": bool(row["enabled"]),
                    "created_at": row["created_at"],
                    "expires_at": row["expires_at"],
                    "data_limit_bytes": row["data_limit_bytes"],
                    "used_bytes": (row["cumulative_rx"] or 0) + (row["cumulative_tx"] or 0),
                    "rx_bytes": row["cumulative_rx"] or 0,
                    "tx_bytes": row["cumulative_tx"] or 0,
                    "last_handshake": last_handshake,
                    "online": online,
                }
            )
    return result


@app.post("/api/peers")
def create_peer(body: CreatePeerRequest, _=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT ip_address FROM peers")
        used_ips = {r["ip_address"] for r in cur.fetchall()}

    ip_address = database.next_free_ip(_subnet_base(), used_ips)
    private_key = awg.genkey()
    public_key = awg.pubkey(private_key)
    preshared_key = awg.genpsk()
    data_limit_bytes = int(body.data_limit_gb * 1024**3) if body.data_limit_gb else None

    with database.cursor() as cur:
        cur.execute(
            """INSERT INTO peers
               (name, public_key, private_key, preshared_key, ip_address, note,
                enabled, created_at, expires_at, data_limit_bytes)
               VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)""",
            (
                body.name,
                public_key,
                private_key,
                preshared_key,
                ip_address,
                body.note or "",
                database.now(),
                body.expires_at,
                data_limit_bytes,
            ),
        )
        peer_id = cur.lastrowid
        cur.execute("INSERT INTO peer_stats (peer_id) VALUES (?)", (peer_id,))

    awg.add_peer_live(public_key, preshared_key, ip_address)
    awg.append_peer_to_conf(public_key, preshared_key, ip_address, body.name)

    client_conf = awg.build_client_config(private_key, ip_address, preshared_key)
    return {"id": peer_id, "ip_address": ip_address, "config": client_conf}


@app.put("/api/peers/{peer_id}")
def update_peer(peer_id: int, body: UpdatePeerRequest, _=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT * FROM peers WHERE id=?", (peer_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "کاربر پیدا نشد")

        new_enabled = row["enabled"] if body.enabled is None else int(body.enabled)
        new_note = row["note"] if body.note is None else body.note
        new_expires = row["expires_at"] if body.expires_at is None else body.expires_at
        new_limit = (
            row["data_limit_bytes"]
            if body.data_limit_gb is None
            else int(body.data_limit_gb * 1024**3)
        )

        cur.execute(
            """UPDATE peers SET enabled=?, note=?, expires_at=?, data_limit_bytes=? WHERE id=?""",
            (new_enabled, new_note, new_expires, new_limit, peer_id),
        )

    if body.enabled is True:
        awg.add_peer_live(row["public_key"], row["preshared_key"], row["ip_address"])
    elif body.enabled is False:
        awg.remove_peer_live(row["public_key"])

    return {"ok": True}


@app.delete("/api/peers/{peer_id}")
def delete_peer(peer_id: int, _=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT * FROM peers WHERE id=?", (peer_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "کاربر پیدا نشد")
        cur.execute("DELETE FROM peers WHERE id=?", (peer_id,))
        cur.execute("DELETE FROM peer_stats WHERE peer_id=?", (peer_id,))

    awg.remove_peer_live(row["public_key"])
    awg.remove_peer_from_conf(row["public_key"])
    return {"ok": True}


@app.get("/api/peers/{peer_id}/config", response_class=PlainTextResponse)
def get_peer_config(peer_id: int, _=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT * FROM peers WHERE id=?", (peer_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "کاربر پیدا نشد")
    return awg.build_client_config(row["private_key"], row["ip_address"], row["preshared_key"])


@app.get("/api/peers/{peer_id}/qr")
def get_peer_qr(peer_id: int, _=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT * FROM peers WHERE id=?", (peer_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "کاربر پیدا نشد")
    conf = awg.build_client_config(row["private_key"], row["ip_address"], row["preshared_key"])
    img = qrcode.make(conf)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/png")


@app.get("/api/system")
def system_info(_=Depends(auth.require_auth)):
    with database.cursor() as cur:
        cur.execute("SELECT COUNT(*) c FROM peers")
        total = cur.fetchone()["c"]
        cur.execute(
            "SELECT COALESCE(SUM(cumulative_rx+cumulative_tx),0) t FROM peer_stats"
        )
        total_traffic = cur.fetchone()["t"]
    live = awg.dump()
    now = database.now()
    online = sum(
        1
        for v in live.values()
        if v.get("latest_handshake") and (now - v["latest_handshake"]) < config.ONLINE_THRESHOLD_SECONDS
    )
    return {
        "endpoint": config.SERVER_ENDPOINT,
        "port": config.SERVER_PORT,
        "interface": config.INTERFACE,
        "total_peers": total,
        "online_peers": online,
        "total_traffic_bytes": total_traffic,
    }


# ---------- background loops ----------
async def stats_loop():
    while True:
        try:
            live = awg.dump()
            with database.cursor() as cur:
                cur.execute("SELECT id, public_key FROM peers")
                peer_map = {r["public_key"]: r["id"] for r in cur.fetchall()}

                for pubkey, info in live.items():
                    peer_id = peer_map.get(pubkey)
                    if not peer_id:
                        continue
                    cur.execute(
                        "SELECT * FROM peer_stats WHERE peer_id=?", (peer_id,)
                    )
                    stat = cur.fetchone()
                    if not stat:
                        continue

                    new_rx, new_tx = info["rx"], info["tx"]
                    # اگه اینترفیس ری‌استارت شده باشه، شمارنده صفر می‌شه؛ این حالت رو تشخیص می‌دیم
                    delta_rx = new_rx if new_rx < stat["last_rx"] else new_rx - stat["last_rx"]
                    delta_tx = new_tx if new_tx < stat["last_tx"] else new_tx - stat["last_tx"]

                    cur.execute(
                        """UPDATE peer_stats SET
                           cumulative_rx = cumulative_rx + ?,
                           cumulative_tx = cumulative_tx + ?,
                           last_rx = ?, last_tx = ?,
                           last_handshake = ?, updated_at = ?
                           WHERE peer_id = ?""",
                        (
                            max(delta_rx, 0),
                            max(delta_tx, 0),
                            new_rx,
                            new_tx,
                            info["latest_handshake"],
                            database.now(),
                            peer_id,
                        ),
                    )
        except Exception as e:
            print(f"[stats_loop] error: {e}")
        await asyncio.sleep(config.STATS_POLL_INTERVAL)


async def enforcement_loop():
    """peer هایی که منقضی شدن یا سقف مصرفشون تموم شده رو از اینترفیس زنده حذف می‌کنه"""
    while True:
        try:
            now = database.now()
            with database.cursor() as cur:
                cur.execute(
                    """SELECT p.*, s.cumulative_rx, s.cumulative_tx
                       FROM peers p JOIN peer_stats s ON s.peer_id = p.id
                       WHERE p.enabled = 1"""
                )
                for row in cur.fetchall():
                    expired = row["expires_at"] and now > row["expires_at"]
                    used = (row["cumulative_rx"] or 0) + (row["cumulative_tx"] or 0)
                    over_limit = row["data_limit_bytes"] and used > row["data_limit_bytes"]
                    if expired or over_limit:
                        awg.remove_peer_live(row["public_key"])
                        cur.execute(
                            "UPDATE peers SET enabled=0 WHERE id=?", (row["id"],)
                        )
        except Exception as e:
            print(f"[enforcement_loop] error: {e}")
        await asyncio.sleep(30)


# ---------- static frontend ----------
# app/main.py -> app/ -> نصب اصلی -> static/  (پوشه‌ی static کنار app کپی می‌شه)
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
