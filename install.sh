#!/usr/bin/env bash
#
# نصب‌کننده یک‌خطی AmneziaWG + پنل مدیریت
# استفاده:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh | sudo bash
#
set -euo pipefail

REPO_URL="${AWG_PANEL_REPO_URL:-https://github.com/rima0222/Am_wg.git}"
INSTALL_DIR="/opt/awg-panel"
ETC_DIR="/etc/awg-panel"
WG_ETC_DIR="/etc/amnezia/amneziawg"
IFACE="awg0"
CONF_PATH="${WG_ETC_DIR}/${IFACE}.conf"

# ---------- توابع کمکی ----------
log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

ask() {
  # ask "متن سوال" "مقدار پیش‌فرض"
  local prompt="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    printf '\n>> %s\n   (اگه همینو می‌خوای فقط Enter بزن) [%s]: ' "$prompt" "$default" > /dev/tty
  else
    printf '\n>> %s: ' "$prompt" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty
  echo "${answer:-$default}"
}

ask_secret() {
  local prompt="$1" answer
  printf '\n>> %s: ' "$prompt" > /dev/tty
  IFS= read -rs answer < /dev/tty
  echo "" > /dev/tty
  echo "$answer"
}

random_hex() { openssl rand -hex "${1:-16}"; }
random_int() { shuf -i "$1-$2" -n 1; }

if [ "$(id -u)" -ne 0 ]; then
  err "این اسکریپت باید با دسترسی root اجرا بشه (sudo bash install.sh)"
  exit 1
fi

if ! grep -qi ubuntu /etc/os-release; then
  warn "این اسکریپت برای اوبونتو تست شده؛ روی توزیع‌های دیگه ممکنه کار نکنه."
fi

log "شروع نصب AmneziaWG + پنل مدیریت..."

# ---------- ۱. پرسیدن تنظیمات ----------
log "تشخیص IP عمومی سرور (حداکثر ۵ ثانیه صبر می‌کنیم)..."
PUBLIC_IP="$(curl -s -4 --max-time 5 https://api.ipify.org || true)"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -s -4 --max-time 5 https://ifconfig.me || true)"
fi
if [ -z "$PUBLIC_IP" ]; then
  warn "تشخیص خودکار IP ناموفق بود؛ خودت باید واردش کنی."
fi
SERVER_ENDPOINT="$(ask 'آدرس IP یا دامنه‌ای که کلاینت‌ها باهاش وصل می‌شن' "${PUBLIC_IP}")"
echo "   -> انتخاب شد: ${SERVER_ENDPOINT}" > /dev/tty
WG_PORT="$(ask 'پورت UDP وایرگارد (برای جلوگیری از تداخل، یه پورت غیرمعمول انتخاب کن)' "$(random_int 20000 60000)")"
echo "   -> انتخاب شد: ${WG_PORT}" > /dev/tty
PANEL_PORT="$(ask 'پورت پنل مدیریت (وب)' "8787")"
echo "   -> انتخاب شد: ${PANEL_PORT}" > /dev/tty
ADMIN_USER="$(ask 'نام کاربری ادمین پنل' "admin")"
echo "   -> انتخاب شد: ${ADMIN_USER}" > /dev/tty
ADMIN_PASS="$(ask_secret 'رمز عبور ادمین پنل را وارد کن')"
if [ -z "$ADMIN_PASS" ]; then
  ADMIN_PASS="$(random_hex 8)"
  warn "رمز عبور خالی بود؛ یه رمز تصادفی ساخته شد: ${ADMIN_PASS}"
fi

# ---------- ۲. نصب پیش‌نیازها ----------
log "نصب پیش‌نیازها..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common python3-launchpadlib gnupg2 \
  linux-headers-"$(uname -r)" python3-venv python3-pip qrencode iptables \
  curl openssl git

log "افزودن مخزن AmneziaWG..."
add-apt-repository -y ppa:amnezia/ppa
apt-get update -y

log "نصب AmneziaWG..."
apt-get install -y amneziawg amneziawg-tools

if ! command -v awg >/dev/null 2>&1; then
  err "نصب amneziawg-tools ناموفق بود. مطمئن شو کرنل‌هدرهای متناسب با کرنل فعلیت نصب شدن."
  exit 1
fi

# ---------- ۳. فعال‌سازی IP forwarding ----------
log "فعال‌سازی IP forwarding..."
cat > /etc/sysctl.d/99-awg-panel.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# تیونینگ برای تعداد کاربر بالا و اتصال پایدار بدون قطعی
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.netdev_max_backlog = 4096
net.netfilter.nf_conntrack_max = 262144
net.ipv4.udp_mem = 65536 131072 262144
EOF
sysctl --system >/dev/null

# ---------- ۴. تشخیص اینترفیس خروجی اینترنت ----------
DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
if [ -z "$DEFAULT_IFACE" ]; then
  err "نتونستم اینترفیس شبکه پیش‌فرض رو پیدا کنم."
  exit 1
fi
log "اینترفیس شبکه خروجی: ${DEFAULT_IFACE}"

# ---------- ۵. تولید کلید سرور و پارامترهای مبهم‌سازی (ضد DPI) ----------
log "تولید کلیدها و پارامترهای ضد DPI..."
mkdir -p "$WG_ETC_DIR"
chmod 700 "$WG_ETC_DIR"
SERVER_PRIVATE_KEY="$(awg genkey)"
SERVER_PUBLIC_KEY="$(echo "$SERVER_PRIVATE_KEY" | awg pubkey)"

# مقادیر H1-H4 باید سه‌تا سه‌تا متفاوت باشن و بین سرور و کلاینت یکسان بمونن
gen_unique_h() {
  local vals=()
  while [ "${#vals[@]}" -lt 4 ]; do
    local v
    v="$(random_int 100000 2000000000)"
    if [[ ! " ${vals[*]:-} " =~ " ${v} " ]]; then
      vals+=("$v")
    fi
  done
  echo "${vals[@]}"
}
read -r H1 H2 H3 H4 <<< "$(gen_unique_h)"
JC="$(random_int 3 10)"
JMIN="40"
JMAX="$(random_int 200 900)"
S1="$(random_int 15 60)"
S2="$(random_int 15 60)"

AWG_SUBNET="10.29.29.0/24"
AWG_ADDRESS="10.29.29.1/24"
AWG_DNS="1.1.1.1, 8.8.8.8"
CLIENT_MTU="1280"

# ---------- ۶. ساخت فایل کانفیگ اینترفیس سرور ----------
log "ساخت فایل کانفیگ ${CONF_PATH} ..."
cat > "$CONF_PATH" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${AWG_ADDRESS}
ListenPort = ${WG_PORT}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i ${IFACE} -j ACCEPT
PostUp = iptables -A FORWARD -o ${IFACE} -j ACCEPT
PostUp = iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${IFACE} -j ACCEPT
PostDown = iptables -D FORWARD -o ${IFACE} -j ACCEPT
PostDown = iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
chmod 600 "$CONF_PATH"

# ---------- ۷. بالا آوردن تانل ----------
log "فعال‌سازی سرویس ${IFACE}..."
systemctl enable --now "awg-quick@${IFACE}" || {
  err "بالا اومدن تانل ناموفق بود. لاگ رو با دستور زیر ببین:"
  echo "journalctl -u awg-quick@${IFACE} -n 50 --no-pager"
  exit 1
}

# ---------- ۸. کپی فایل‌های پنل ----------
log "استقرار پنل مدیریت در ${INSTALL_DIR}..."
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$INSTALL_DIR"
if [ -d "${SRC_DIR}/panel" ]; then
  cp -r "${SRC_DIR}/panel/"* "$INSTALL_DIR/"
else
  # اگه اسکریپت به‌تنهایی (curl | bash) اجرا شده، کل ریپو رو کلون کن
  TMP_CLONE="$(mktemp -d)"
  git clone --depth 1 "$REPO_URL" "$TMP_CLONE"
  cp -r "${TMP_CLONE}/panel/"* "$INSTALL_DIR/"
  rm -rf "$TMP_CLONE"
fi

log "ساخت محیط مجازی پایتون و نصب وابستگی‌ها..."
python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip -q
"${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" -q

# ---------- ۹. ساخت هش رمز عبور و فایل تنظیمات پنل ----------
log "ساخت فایل تنظیمات پنل..."
mkdir -p "$ETC_DIR"
chmod 700 "$ETC_DIR"

PASSWORD_HASH="$("${INSTALL_DIR}/venv/bin/python3" - "$ADMIN_PASS" <<'PYEOF'
import sys, hashlib, os
password = sys.argv[1]
salt = os.urandom(16).hex()
digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
print(f"{salt}${digest.hex()}")
PYEOF
)"

JWT_SECRET="$(random_hex 32)"

cat > "${ETC_DIR}/panel.env" <<EOF
AWG_INTERFACE=${IFACE}
AWG_CONF_PATH=${CONF_PATH}
AWG_SUBNET=${AWG_SUBNET}
AWG_ADDRESS=${AWG_ADDRESS}
AWG_ENDPOINT=${SERVER_ENDPOINT}
AWG_PORT=${WG_PORT}
AWG_SERVER_PUBLIC_KEY=${SERVER_PUBLIC_KEY}
AWG_DNS=${AWG_DNS}
AWG_JC=${JC}
AWG_JMIN=${JMIN}
AWG_JMAX=${JMAX}
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H1}
AWG_H2=${H2}
AWG_H3=${H3}
AWG_H4=${H4}
AWG_CLIENT_MTU=${CLIENT_MTU}
PANEL_DB_PATH=${ETC_DIR}/panel.db
PANEL_JWT_SECRET=${JWT_SECRET}
PANEL_PORT=${PANEL_PORT}
PANEL_ADMIN_USER=${ADMIN_USER}
PANEL_ADMIN_PASSWORD_HASH=${PASSWORD_HASH}
PANEL_STATS_INTERVAL=2
PANEL_ONLINE_THRESHOLD=150
EOF
chmod 600 "${ETC_DIR}/panel.env"

# ---------- ۱۰. نصب سرویس systemd پنل ----------
log "نصب سرویس پنل..."
if [ -f "${SRC_DIR}/systemd/awg-panel.service" ]; then
  cp "${SRC_DIR}/systemd/awg-panel.service" /etc/systemd/system/awg-panel.service
else
  cat > /etc/systemd/system/awg-panel.service <<EOF
[Unit]
Description=AmneziaWG Management Panel
After=network.target awg-quick@${IFACE}.service
Wants=awg-quick@${IFACE}.service

[Service]
Type=simple
EnvironmentFile=${ETC_DIR}/panel.env
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port \${PANEL_PORT} --app-dir ${INSTALL_DIR}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now awg-panel

# ---------- ۱۱. فایروال پورت‌های لازم ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${WG_PORT}/udp" >/dev/null
  ufw allow "${PANEL_PORT}/tcp" >/dev/null
fi

echo ""
echo "=================================================================="
echo -e "\033[1;32m✔ نصب با موفقیت کامل شد!\033[0m"
echo "=================================================================="
echo "پنل مدیریت:      http://${SERVER_ENDPOINT}:${PANEL_PORT}"
echo "نام کاربری ادمین: ${ADMIN_USER}"
echo "رمز عبور ادمین:   ${ADMIN_PASS}"
echo "------------------------------------------------------------------"
echo "اینترفیس وایرگارد: ${IFACE}   |   پورت: ${WG_PORT}"
echo "برای دیدن وضعیت تانل: awg show ${IFACE}"
echo "برای دیدن لاگ پنل:    journalctl -u awg-panel -f"
echo "=================================================================="
