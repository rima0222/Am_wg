# AmneziaWG Panel

.

## نصب سریع

```bash
curl -fsSL https://raw.githubusercontent.com/rima0222/Am_wg/main/install.sh | sudo bash
```


در حین نصب ازت این‌ها پرسیده می‌شه: آی‌پی/دامنه‌ی سرور، پورت وایرگارد، پورت پنل، نام کاربری و رمز ادمین. در پایان لینک پنل رو بهت نشون می‌ده.

> نکته: اگه اسکریپت رو با `curl | sudo bash` اجرا می‌کنی و می‌خوای سوالات رو جواب بدی، سوالات از `/dev/tty` خونده می‌شن پس مشکلی نیست.

## بعد از نصب

- ورود به پنل: `http://IP_SERVER:PANEL_PORT`
- افزودن کاربر → دانلود فایل کانفیگ یا اسکن QR با اپ WireGuard/AmneziaWG روی گوشی یا کامپیوتر
- مشاهده‌ی مصرف، وضعیت آنلاین، تنظیم سقف حجم و تاریخ انقضا برای هر کاربر

⚠️ کلاینت‌ها باید از اپ **AmneziaWG** (نه وایرگارد معمولی) استفاده کنن چون پارامترهای ضدDPI (Jc, Jmin, Jmax, H1-H4, S1, S2) فقط توسط AmneziaWG پشتیبانی می‌شن. اپ رسمی: https://amnezia.org/downloads

## دستورات مفید

```bash
# وضعیت زنده‌ی تانل
awg show awg0

# لاگ پنل
journalctl -u awg-panel -f

# لاگ تانل
journalctl -u awg-quick@awg0 -f

# ری‌استارت پنل
systemctl restart awg-panel
```

## حذف کامل

```bash
sudo bash uninstall.sh
```

##

## هشدار امنیتی / قانونی

این ابزار صرفاً یک نرم‌افزار متن‌باز مدیریت VPN است. مسئولیت استفاده از آن مطابق قوانین محل زندگی‌تان بر عهده‌ی خودتان است.
