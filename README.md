# litespeed-fix-issue

Scripts สำหรับแก้ปัญหา LiteSpeed Cache บน WHM/cPanel Server

---

## 1. `fix-missing-object-cache-lib-line-403.sh`

แก้ปัญหา `object-cache.cls.php line 403` — ไฟล์ `lib/object-cache.php` หายไปจาก LiteSpeed Cache plugin
โดย Deactivate → Delete → Reinstall plugin อัตโนมัติทุกเว็บที่พบปัญหา

```bash
bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/litespeed-fix-issue/refs/heads/main/fix-missing-object-cache-lib-line-403.sh)
```

---

## 2. `verify-fix-missing-object-cache-lib-line-403.sh`

ตรวจสอบว่าทุกเว็บมีไฟล์ `lib/object-cache.php` ครบหรือยัง
แสดงรายชื่อเว็บที่ยังพบปัญหาเพื่อนำไป Fix อีกครั้ง

```bash
bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/litespeed-fix-issue/refs/heads/main/verify-fix-missing-object-cache-lib-line-403.sh)
```

---

## 3. `save-change-bulk.sh`

Trigger LiteSpeed Cache Save Changes ทุกเว็บพร้อมกัน — เหมือนกดปุ่ม Save Changes ในหน้า LiteSpeed Settings
และ Purge Cache ทุกเว็บในทีเดียว

```bash
bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/litespeed-fix-issue/refs/heads/main/save-change-bulk.sh)
```

---

## ลำดับการรัน

```
1. fix-missing-object-cache-lib-line-403.sh        ← แก้ไข
2. verify-fix-missing-object-cache-lib-line-403.sh ← ตรวจสอบ
3. save-change-bulk.sh                             ← บันทึก + Purge Cache
```

## Log Files

| Script | Log |
|--------|-----|
| fix | `/var/log/lscwp-fix-objcache-lib.log` |
| verify | `/var/log/lscwp-verify-objcache-lib.log` |
| save-change | `/var/log/lscwp-save-changes-bulk.log` |
