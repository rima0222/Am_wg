#!/usr/bin/env bash
set -euo pipefail

IFACE="awg0"

if [ "$(id -u)" -ne 0 ]; then
  echo "با sudo اجرا کن." >&2
  exit 1
fi

echo "[+] متوقف کردن سرویس‌ها..."
systemctl disable --now awg-panel 2>/dev/null || true
systemctl disable --now "awg-quick@${IFACE}" 2>/dev/null || true

echo "[+] حذف فایل‌ها..."
rm -f /etc/systemd/system/awg-panel.service
rm -rf /opt/awg-panel
rm -rf /etc/awg-panel
rm -f "/etc/amnezia/amneziawg/${IFACE}.conf"
rm -f /etc/sysctl.d/99-awg-panel.conf

systemctl daemon-reload

read -rp "آیا بسته‌های amneziawg هم حذف بشن؟ (y/N): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  apt-get remove -y amneziawg amneziawg-tools || true
fi

echo "[+] حذف کامل شد."
