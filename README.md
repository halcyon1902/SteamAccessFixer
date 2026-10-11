<div align="center">

# 🎮 SteamAccessFixer

**Steam connectivity diagnostic and optional hosts override utility for Windows**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](CHANGELOG.md)

*Resolve Steam hostnames over DNS-over-HTTPS, verify TCP/443 reachability, and optionally pin verified IPs into the Windows hosts file.*

</div>

---

## 📖 Mục lục

- [Giới thiệu](#-giới-thiệu)
- [Tính năng](#-tính-năng)
- [Cài đặt](#-cài-đặt)
- [Cách sử dụng](#-cách-sử-dụng)
- [Cách hoạt động](#-cách-hoạt-động)
- [Gỡ cài đặt](#-gỡ-cài-đặt)
- [Cảnh báo quan trọng](#️-cảnh-báo-quan-trọng)
- [Khắc phục sự cố](#-khắc-phục-sự-cố)
- [License](#-license)

---

## 🎯 Giới thiệu

`SteamAccessFixer` là một script PowerShell giúp **chẩn đoán và khắc phục** các vấn đề kết nối tới Steam — thường gặp khi ISP DNS bị chậm, bị poison, hoặc không phân giải được các domain của Steam/CDN.

Script sẽ:

1. **Phân giải** danh sách hostname Steam qua **DNS-over-HTTPS** (Cloudflare & Google)
2. **Kiểm tra** khả năng kết nối TCP/443 tới từng IP tìm được
3. **Tùy chọn** ghi các IP đã xác minh vào file `hosts` của Windows
4. **Tự động backup** và có thể **khôi phục** về trạng thái ban đầu bất cứ lúc nào

> ⚠️ Đây **không phải** là VPN hay proxy. Script chỉ ghi đè DNS resolution ở tầng hệ điều hành.

---

## ✨ Tính năng

| | Tính năng | Mô tả |
|---|---|---|
| 🔍 | **DNS-over-HTTPS** | Truy vấn song song Cloudflare + Google DoH, không phụ thuộc DNS nhà mạng |
| 🌐 | **System DNS fallback** | Nếu DoH bị chặn, tự động fallback về `System.Net.Dns` |
| ⚡ | **TCP/443 probe** | Kiểm tra port 443 async trước khi ghi vào hosts — tránh pin IP chết |
| 🛡️ | **Atomic hosts write** | Ghi qua file tạm + `File.Replace` — không sợ hỏng hosts nếu crash giữa chừng |
| 💾 | **Backup tự động** | Backup hosts vào `hosts.bak_steam` trước khi sửa |
| ♻️ | **Restore 1 lệnh** | Khôi phục từ backup hoặc strip managed entries tại chỗ |
| 🎨 | **CLI có màu** | Menu tương tác, progress bar, màu trạng thái rõ ràng |
| ⏰ | **Scheduled task** | Đăng ký task SYSTEM chạy hàng tuần (Chủ nhật 03:00) để refresh IP |
| 🔒 | **Không cần secret** | Không API key, không token, không telemetry |
| 🧪 | **Non-interactive mode** | Chạy được từ scheduled task, CI, hoặc pipe |

---

## 📥 Cài đặt

### Cách 1 — Tải trực tiếp

```powershell
# Tải script về Desktop
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/halcyon1902/SteamAccessFixer/main/SteamAccessFixer.ps1' `
    -OutFile "$env:USERPROFILE\Desktop\SteamAccessFixer.ps1"
```

### Cách 2 — Clone repo

```powershell
git clone https://github.com/halcyon1902/SteamAccessFixer.git
cd SteamAccessFixer
```

### Cách 3 — Tải từ Releases

Vào [Releases](https://github.com/halcyon1902/SteamAccessFixer/releases) → tải file `.ps1` mới nhất.

### Bỏ chặn script (nếu cần)

Nếu PowerShell báo *"cannot be loaded because running scripts is disabled"*:

```powershell
Unblock-File .\SteamAccessFixer.ps1
```

Hoặc chạy với:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\SteamAccessFixer.ps1
```

---

## 🚀 Cách sử dụng

### Chạy menu tương tác (khuyến nghị cho người mới)

```powershell
# Mở PowerShell với quyền Administrator, rồi:
.\SteamAccessFixer.ps1
```

Menu sẽ hiện ra:

```
  steam-access-fixer  v1.0.0  ·  Halcyon  ·  2026-10-10
  --------------------------------------------------------------

  commands

    1  diagnose    resolve hostnames and probe tcp/443
    2  apply       scan and write validated entries to hosts    (admin)
    3  restore     restore backup / remove managed entries      (admin)
    4  schedule    register a weekly scheduled task             (admin)
    5  exit        quit

  status: administrator

  command
```

### Chạy trực tiếp theo mode

```powershell
# 1. Chỉ chẩn đoán (không cần admin)
.\SteamAccessFixer.ps1 -Mode Diagnose

# 2. Quét và ghi vào hosts (cần admin)
.\SteamAccessFixer.ps1 -Mode Apply

# 3. Khôi phục hosts về trạng thái ban đầu (cần admin)
.\SteamAccessFixer.ps1 -Mode Restore

# 4. Đăng ký scheduled task chạy hàng tuần (cần admin)
.\SteamAccessFixer.ps1 -Mode Schedule
```

### Bật chế độ debug

```powershell
$env:STEAMFIX_DEBUG = '1'
.\SteamAccessFixer.ps1 -Mode Diagnose
```

Sẽ in ra chi tiết lỗi của từng DoH provider — hữu ích khi troubleshoot.

### Ví dụ output

```
  steam-access-fixer  v1.0.0  ·  Halcyon  ·  2026-10-10
  --------------------------------------------------------------

  scanning 6 hosts

    store.steampowered.com                 23.45.67.89        ok
    steamcommunity.com                     23.45.67.90        ok
    api.steampowered.com                   23.45.67.91        ok
    checkout.steampowered.com              23.45.67.92        ok
    login.steampowered.com                 23.45.67.93        ok
    cdn.cloudflare.steamstatic.com         104.16.xxx.xxx     ok

  6 hosts  ·  6 ok  ·  0 warn  ·  0 fail  ·  4.2s
```

---

## ⚙️ Cách hoạt động

```
┌──────────────────────────────────────────────────────────────┐
│  1. Resolve via DoH                                          │
│     ├─ Cloudflare DoH  ──┐                                   │
│     └─ Google DoH       ──┴─►  A records                     │
│                                                              │
│  2. Fallback (nếu DoH fail)                                  │
│     └─ System.Net.Dns.GetHostAddresses()                     │
│                                                              │
│  3. TCP/443 probe (async, timeout 3s)                        │
│     └─ Chỉ giữ IP connect được                               │
│                                                              │
│  4. Ghi vào hosts (chỉ mode Apply)                           │
│     └─ Atomic write + backup tự động                         │
└──────────────────────────────────────────────────────────────┘
```

### Các hostname được quản lý

| Hostname | Mục đích |
|---|---|
| `store.steampowered.com` | Cửa hàng Steam |
| `steamcommunity.com` | Cộng đồng, profile, workshop |
| `api.steampowered.com` | API backend |
| `checkout.steampowered.com` | Thanh toán |
| `login.steampowered.com` | Đăng nhập |
| `cdn.cloudflare.steamstatic.com` | CDN nội dung tĩnh |

### Cấu trúc block trong hosts

```
# BEGIN SteamAccessFix managed entries
23.45.67.89	store.steampowered.com
23.45.67.90	steamcommunity.com
...
# END SteamAccessFix managed entries
```

Script **chỉ sửa** phần nằm giữa 2 marker này — mọi entry khác của bạn được giữ nguyên.

---

## 🗑️ Gỡ cài đặt

### Bước 1 — Khôi phục hosts

```powershell
.\SteamAccessFixer.ps1 -Mode Restore
```

### Bước 2 — Xóa scheduled task (nếu đã đăng ký)

```powershell
Unregister-ScheduledTask -TaskName 'SteamAccessFixer' -Confirm:$false
```

### Bước 3 — Xóa file (tùy chọn)

```powershell
Remove-Item .\SteamAccessFixer.ps1
Remove-Item "$env:SystemRoot\System32\drivers\etc\hosts.bak_steam" -ErrorAction SilentlyContinue
```

### Bước 4 — Flush DNS

```powershell
ipconfig /flushdns
```

---

## ⚠️ Cảnh báo quan trọng

> ### 🔴 Đọc kỹ trước khi dùng mode `Apply`

1. **IP của CDN thay đổi liên tục.** Steam dùng nhiều CDN (Akamai, Cloudflare, Valve tự vận hành). IP hôm nay có thể không còn dùng được vào tuần sau.

2. **TCP/443 mở ≠ Steam hoạt động đúng.** Một IP có thể accept TCP nhưng trả về nội dung sai (do SNI mismatch), khiến Steam hiển thị lỗi khó hiểu.

3. **Không nên pin hosts lâu dài.** Chỉ dùng khi:
   - DNS nhà mạng của bạn thực sự có vấn đề
   - Bạn hiểu rõ rủi ro
   - Bạn có cách khôi phục nhanh (`-Mode Restore`)

4. **Không thay thế VPN/proxy.** Nếu Steam bị chặn ở tầng quốc gia, hosts override **không giúp được gì**.

5. **Có thể làm hỏng kết nối Steam tạm thời.** Nếu sau khi Apply mà Steam lỗi, chạy ngay:
   ```powershell
   .\SteamAccessFixer.ps1 -Mode Restore
   ipconfig /flushdns
   ```

---

## 🔧 Khắc phục sự cố

<details>
<summary><b>❌ "administrator privileges required"</b></summary>

Bạn đang chạy PowerShell ở quyền user thường. Đóng cửa sổ, mở lại bằng:
- Chuột phải **PowerShell** → **Run as administrator**
- Hoặc: `Win + X` → **Terminal (Admin)**

</details>

<details>
<summary><b>❌ "dns error" cho tất cả hostname</b></summary>

Có thể do:
- Firewall/proxy chặn `cloudflare-dns.com` và `dns.google`
- TLS 1.2 bị tắt ở tầng hệ thống
- Antivirus can thiệp HTTPS

Thử bật debug để xem chi tiết:
```powershell
$env:STEAMFIX_DEBUG = '1'
.\SteamAccessFixer.ps1 -Mode Diagnose
```

</details>

<details>
<summary><b>❌ "could not update hosts file"</b></summary>

Nguyên nhân thường gặp:
- **Antivirus** đang lock file hosts (Bitdefender, Kaspersky, Avast…)
- **Windows Defender Tamper Protection** đang bật
- **Group Policy** khoá quyền ghi hosts

Khắc phục:
1. Tạm tắt "Hosts file protection" trong AV
2. Hoặc tắt Tamper Protection tạm thời
3. Chạy lại script

</details>

<details>
<summary><b>❌ Steam vẫn lỗi sau khi Apply</b></summary>

```powershell
# 1. Khôi phục hosts
.\SteamAccessFixer.ps1 -Mode Restore

# 2. Flush DNS
ipconfig /flushdns

# 3. Xoá cache Steam
# Vào Steam → Settings → Downloads → Clear Download Cache
```

</details>

<details>
<summary><b>❌ Scheduled task không chạy</b></summary>

```powershell
# Kiểm tra lịch sử chạy
Get-ScheduledTask -TaskName 'SteamAccessFixer' | Get-ScheduledTaskInfo

# Chạy thủ công để test
Start-ScheduledTask -TaskName 'SteamAccessFixer'

# Xem log sự kiện
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 20 |
    Where-Object { $_.Message -like '*SteamAccessFixer*' }
```

</details>

---

## 📜 License

Phát hành theo [MIT License](LICENSE).

Copyright © 2026 [Halcyon1902](https://github.com/halcyon1902).

<div align="center">

**Nếu script hữu ích, hãy ⭐ star repo để ủng hộ tác giả!**

</div>
