# POS ↔ 後台 API

iPad（StudioX POS）和每家店自己的後台（atelier-cms，開了「門市 POS」服務插件）之間的約定。
Swift 端的型別在 `Packages/POSKit/Sources/POSSync/APIModels.swift`，範例 JSON 在 `docs/samples/`（由測試產生，和程式一定一致）。

## 共通規則

- 路徑前綴：`{CMS_URL}/api/pos/v1`。登入、選店走 console：`{CONSOLE_URL}/api/pos/sites`、`/api/pos/personal-pair`。
- 認證：登入後每個請求帶 `Authorization: Bearer <token>`（`sxpos_<deviceId>.<secret>`；後台只存 SHA-256）。
- 金額：**整數「分」**（NT$60 → `6000`），和後台資料庫一樣。
- 時間：ISO 8601、UTC、毫秒（`2026-09-21T14:13:20.000Z`）。營業日 `businessDate` 是台北時間的 `YYYY-MM-DD`（凌晨 4 點前算前一天，店家可改）。
- JSON key 是 camelCase；選填欄位沒有值時**不出現**（不是 `null`）。
- 錯誤：HTTP 4xx/5xx ＋ `{ "error": "<code>", "message": "給人看的一句話" }`。
  - `401 unauthorized`：token 不對 → App 回到登入畫面
  - `401 revoked`：後台移除了這台 → App 清掉本機資料、回到登入畫面
  - `401 staff_inactive`：個人裝置綁的門市人員被停用 → **不清**本機資料，鎖起來等店長重新啟用（見「用 StudioX 帳號登入」）
  - `401 wrong_pin`：`/staff/verify-pin` 的 PIN 不對 → 只是這一次授權失敗，不是登出
  - `403 service_off`：StudioX 沒開通／店家暫停了「門市 POS」 → App 照常營業（離線模式），提示「後台暫停同步」
  - `429 rate_limited`

## 用 StudioX 帳號登入（唯一的開始方式）

每台（iPad、手機）都用 StudioX 帳號登入（和 StudioX App 同一個帳號：Apple、Email、邀請），**綁著登入的那個人**：之後打開 App 直接是他
（離開一陣子回來用 Face ID／手機密碼解鎖），不用配對碼、不用 PIN。換人＝在設定（手機是「更多」）登出，再用自己的帳號登入。
沒有配對碼、沒有店裡共用的裝置；人員 PIN 只用在主管授權（`/staff/verify-pin`）。

1. **登入 console**：OAuth 2.1＋PKCE，`{CONSOLE_URL}/api/oauth/authorize`，`client_id=studiox-pos`、`redirect_uri=studiox-pos://oauth`、`scope=pos:staff`；`POST /api/oauth/token` 換 `access`（1 小時）／`refresh`（30 天，輪替）。只拿來配對、換店，不拿來同步
2. **哪幾家店**：`GET {CONSOLE_URL}/api/pos/sites`（Bearer）→ `{ "sites": [{ "id", "name", "icon", "level", "cmsUrl" }] }`：這個人是成員、而且開通了門市 POS 的網站。只有一家就不用選
3. **這台做什麼**：iPad 選崗位——`register` 收銀台、`handheld` 前場點餐、`reception` 接待、`kitchen` 廚房、`expo` 出餐口（上次在這台選的先選好）；手機一律 `handheld`
4. **配對**：`POST {CONSOLE_URL}/api/pos/personal-pair`（Bearer）`{ "siteId", "role": "register", "device": { name, model, systemVersion, appVersion } }`
   - `role` 沒給＝`handheld`（舊版 App）；不是上面五個 → `400 invalid`。body 裡的 `mode` 不理（沒有店裡共用的裝置了）
   - console 簽一張給那個網站的一次性通行證（ES256、`typ: "pos-personal"`、`sub`＝console 的使用者、`email`、`name`、`level`、`mode: "personal"`、`role`，60 秒、`jti` 只能用一次），代轉到網站的 `POST /pair/personal`
   - ← `{ deviceId, token, deviceCode, role, storeName }`（samples/pair-response.json），另外多 `cmsUrl`、`siteName`、`personal: true`、`staff: { id, name, role }`
   - `deviceCode`：這家店還沒被使用中的裝置用掉的第一個字母（A–Z）。單號 = 字母＋當天流水號（A001）
   - `409 register_limit`：選收銀台、但方案的收銀機台數滿了（點餐、接待、廚房、出餐口不限）
5. **網站的 `POST /pair/personal`**（`Authorization: Bearer <通行證>`；網站只信通行證裡的人、職能與崗位，本文只拿裝置的型號、版本）：
   - 用 `email` 找網站的使用者 → 綁著那個使用者的門市人員（`pos_staff.user_id`）；沒有就新增一位（名字用 `name`，角色照 console 的 `level`：負責人→`owner`、管理者→`manager`、其他→`cashier`（已經有的門市人員保留店家設的角色）；PIN 隨機，店長可以在後台幫他設主管授權用的 PIN）
   - 新增一台 `role`＝通行證的崗位、`personal: true`、`staff_id` 綁那個人的裝置（後台「裝置」頁顯示「王小美・收銀台」，可以改崗位、停用）
   - 同一個人、同一個型號、同一個崗位再登入：停用舊的那台、發新的
   - 門市人員被停用（`is_active=false`）：`403 staff_inactive`
6. **之後**：用網站發的裝置 token（`GET /bootstrap` 的 `device` 有 `personal`、`staffId`）：
   - 開 App 直接登入 `staffId` 那位；鎖定畫面是 Face ID／手機密碼
   - 裝置被停用（`401 revoked`）→ 回到登入畫面
   - 這位門市人員被停用（`401 staff_inactive`）：**不清本機資料**（還沒送出的帳要留著），顯示「你在這家店的門市人員被停用了，請找店長」；店長重新啟用後照常
   - 送出別人（`staffId` 不是綁的那位）的事件：照收（不斷鏈）但不算進帳、通知店長
   - **裝置拿不到 PIN 雜湊**：開機資料的 `staff[]` 照樣有每個人（名字、角色、職稱），但 `pinHash`、`pinSalt`、`pinIterations` 不給
     （4–6 位數的 PIN 拿到雜湊很容易離線試出來）。要主管授權（作廢已送出的、超過上限的折扣、退款…）時，App 問後台：
     `POST /staff/verify-pin { "staffId": "…"（可省略：看 PIN 對到誰）, "pin": "1234", "purpose": "void" }`
     → `{ "staff": { id, name, role } }`；錯了 `401 wrong_pin`（停用的人的 PIN 也是）；`staffId` 省略時兩個人 PIN 一樣取職能最高的。
     - 同一台（另外再算同一個人：換一台也一樣）10 分鐘錯 5 次 → 第 5 次起鎖 10 分鐘 `429 rate_limited`；**打對不會重算**；鎖著的時候對的也不驗
     - PIN 不是 4–6 位數字、`staffId` 格式不對 → `400 invalid`（不算錯一次）；`purpose` 選填（App 送權限的名字，例如 `voidTicket`），只記在鎖住的紀錄
     - 後台數不了錯幾次（Redis 不通）→ `503 unavailable`「主管授權暫時不能用」（不放行）
     - PIN 不寫進任何紀錄
     斷網時不能做主管授權（「主管授權要連線」）。
   - `invoice.qrKey`（財政部 QR Code 的金鑰）只給收銀台（`register`）：開發票的是收銀台；點餐、廚房、出餐口拿不到
   - 設定（手機是「更多」）→「登出這台」：`POST /devices/self/revoke`（網站停用這台），清掉 console 的 token

## 開機資料

### `GET /bootstrap`

`If-None-Match: <version>` 沒變就回 `304`。內容見 `samples/bootstrap.json`：

| 欄位 | 內容 |
|---|---|
| `version` | 設定的版本（菜單、桌位、人員、店家設定、號碼段任一個改了就變） |
| `device` | 這台：`id, name, code, role, stations`。`role` 是崗位（見下方「崗位」）；不認得的值 iPad 當作 `register` |
| `store` | `StoreProfile`：店名、統編、地址、服務費、營業日分界、折扣上限、找零快速鍵、`serviceModes`（開了哪些營業模式：`tableService`／`counter`／`retail`／`cafe`／`apparel`／`salon`／`fitness`）與 `defaultServiceMode`、`prepaidInvoicing`（`atTopUp` 儲值時開發票［預設］／`atRedemption` 消費時開）、`exchangeDays`（幾天內可以換貨，預設 7、0＝不限）、`bookingSlotMinutes`（預約表一格幾分，預設 15）。少給的欄位 iPad 用預設值 |
| `features` | 開了哪些功能：`seating, kitchen, reservations, invoice, members, waitlistSMS, appointments, accounts, commission`。後三個沒給＝`false`（要後台有對應的資料表才開） |
| `catalog` | `categories`（`swatch` 是色塊名稱）、`items`（只給上架的；`isAvailable=false` 是今天賣完；非餐飲的欄位見下方「品項的種類與規格」）、`modifierGroups` |
| `floor` | `areas[].tables[]`，座標是 0–100 的格子 |
| `staff` | 門市人員（只給啟用中的），含 PIN 雜湊（**個人的裝置沒有**，見「用 StudioX 帳號登入」）：`PBKDF2-HMAC-SHA256(pin, pinSalt, pinIterations, 32 bytes)` 的十六進位。後台用 Node：`crypto.pbkdf2Sync(pin, salt, iterations, 32, 'sha256').toString('hex')`。選填：`title`（職稱：設計師、教練）、`bookable`（排進預約表）、`commissionBps`（預設抽成，萬分比） |
| `invoice` | `enabled, sellerTaxId, sellerName, sellerAddress, qrKey`（財政部的 QR Code 加密金鑰，32 個十六進位字）、`rolls`（**這台**還在用的號碼段；每段帶 `usedThrough`＝後台收到這一段用到的最後一號，iPad 一定從它的下一號開始，所以本機事件刪掉了也不會重號） |
| `mesh` | 同一家店的 iPad 在區網互相同步用的金鑰（32 bytes 十六進位）與開關 |
| `printStyle` | 單據樣式（見下方「單據樣式」）；沒給＝預設 |

### 單據樣式（`printStyle`）：先畫成圖片再印

所有單據（交易明細、結帳單、廚房單、取餐號碼；號碼牌照舊用 `queue.ticket`）預設**整張畫成圖片**再送出單機（ESC/POS `GS v 0`，每 256 行一段）：
每台機器印出來一模一樣（不挑機器的字型、不會缺字），也可以疊上店家自己的圖。出單機設定裡可以改回「文字」（舊機器、藍牙很慢時）。

開機資料多一個 `printStyle`（沒給＝預設樣式）：

```json
"printStyle": {
  "mode": "image",
  "font": "sans",
  "scale": 1.0,
  "docs": {
    "receipt": {
      "header": { "url": "https://…/logo.png", "width": 0.6, "align": "center" },
      "footer": { "url": "https://…/ig-qr.png", "width": 0.45, "align": "center" },
      "background": { "url": "https://…/paper-art.png", "fit": "top", "lighten": 0.75 },
      "overlays": [{ "url": "https://…/stamp.png", "x": 0.72, "y": 0.04, "width": 0.22, "anchor": "top" }],
      "headerLines": ["黃毛丫頭・夜市滷味"],
      "footerLines": ["謝謝光臨・IG @yellowgirl"]
    },
    "kitchen": { "scale": 1.3 },
    "bill": {},
    "pickup": {}
  }
}
```

- `mode`：`image`（預設）｜`text`。每台出單機自己的設定優先（`auto`＝照這裡）
- `font`：`sans`｜`serif`｜`rounded`；`scale`：字的大小（0.8–1.6），每種單據可以自己再給
- 圖（`header` 店標、`footer` 頁尾、`background` 底圖、`overlays` 貼圖）：`width`、`x`、`y` 都是紙寬的比例（0–1）；`y` 從 `anchor`（`top`｜`bottom`）算。
  iPad 開機時下載、存在本機（斷網照樣印）；熱感紙只有黑白：照片、插畫用擴散網點（Floyd–Steinberg），字用門檻（150）——字永遠是清楚的黑。
  `background.lighten`（0–1）先把底圖變淡再打網點，疊在字下面也看得清楚；`fit`：`top`（貼在上面）｜`tile`（整張重複）｜`stretch`
- `headerLines`、`footerLines`：店家自己的字（地址、電話照樣自動印）
- 電子發票證明聯格式是財政部規定的：只吃 `font`，不疊圖
- 細節（後台的預覽和 iPad 一模一樣照這個畫；範例 `samples/print-style.json`）：
  - 由上到下：取餐號碼 → `header` 圖 → 店名、地址、電話 → `headerLines`（廚房單放在最上面）→ 內容 → `footerLines` → `footer` 圖
  - 字：24 點 × `scale`（大字 2 倍），左右不留邊：58 mm 一行 16 個中文字、80 mm 24 個
  - `align`：`left`｜`center`｜`right`；`overlays` 的 `x` 是左緣、`y` 是離 `anchor` 那一邊（上或下）最近的邊，都是紙寬的比例；高度照圖的比例
  - `fit`：`top` 縮到紙寬、貼在最上面一次；`tile` 縮到紙寬、往下重複；`stretch` 撐滿整張
  - 疊的順序：底圖（先 `lighten`：灰 = 255 − (255 − g) × (1 − lighten)）→ `header`／`footer` 圖 → `overlays`，一起用 Floyd–Steinberg 打網點（門檻 128）；字另外一層、門檻 150；兩層有一層是黑就印黑。iPad 另外把字周圍 2 點的網點清掉（深色底圖上的字也看得清楚）
  - 沒給的預設：`header`／`footer` 的 `width` 0.5、置中；`fit: top`、`lighten: 0.75`；貼圖 `width` 0.25、`anchor: top`、`x`／`y` 0。範圍：`x`／`y` 0–1、`width` 0.02–1、`scale` 0.8–1.6
  - 某一種單據沒給（或 `{}`）＝不疊圖，不會沿用 `receipt` 的
  - 統編不會自動印在交易明細上（要的話寫在 `headerLines`）

## 事件（同步的核心）

POS 上每一件事都是一筆不可改的事件。iPad 斷網照樣記，連上後送到後台；後台再轉給同一家店的其他 iPad。

### 事件格式

```json
{
  "id": "uuid",            // 事件 id（重送不會重複記）
  "deviceId": "…",
  "seq": 43,               // 這台的流水號，從 1 開始不跳號
  "lamport": 1209,         // Lamport 時鐘：重播順序 = (lamport, deviceId, seq)
  "at": "2026-09-21T14:13:20.000Z",
  "staffId": "…",          // 選填
  "type": "ticket.closed",
  "data": "{…}",           // 事件內容的 JSON「字串」（原樣存、原樣轉發，不要重新排版）
  "prevHash": "…",         // 這台上一筆的 hash；第一筆是 64 個 0
  "hash": "…",
  "serverSeq": 98113       // 只有後台送出來的才有
}
```

**hash** = `sha256_hex(id + "|" + deviceId + "|" + seq + "|" + lamport + "|" + at + "|" + (staffId ?? "") + "|" + type + "|" + prevHash + "|" + data)`。
後台照這個字串驗（Node：`createHash('sha256').update(str, 'utf8').digest('hex')`），**不要**重新排版 `data`。

### `POST /events`

```json
→ { "events": [ …最多 200 筆，同一台、照 seq 排好… ] }
← { "accepted": ["…"], "duplicates": ["…"], "rejected": [{ "id": "…", "reason": "chain_gap", "expectSeq": 42 }], "serverSeq": 98113 }
```

後台對每一筆：
1. `deviceId` 必須是這個 token 的裝置，否則整批 `403`。
2. 同 `id` 已經有 → `duplicates`（不是錯誤）。
3. `hash` 驗不過 → `rejected: bad_hash`。
4. 同一台上一筆（`seq - 1`）還沒收到、或 `prevHash` 對不上 → `rejected: chain_gap`、`expectSeq` = 後台要的下一個 seq（App 從那裡重送）。`seq = 1` 的 `prevHash` 必須是 64 個 0。
5. 不認得的 `type` 照樣收（新版 App 的事件），只是不做投影。
6. 收下：存進 `pos_events`（給一個遞增的 `serverSeq`），然後做**投影**（下一節）。整批在一個交易裡、照 seq 順序處理。

### 本機只留最近兩天

資料以後台為主：iPad 的事件日誌只留「快速開機、斷網照常營業」需要的——還沒送出的、最近兩天、還開著的單與班、這一期與上一期的發票事件；
其他（已經送到後台的）會刪掉。更早的營業日用 `GET /history` 跟後台要。所以：
- 後台是歷史資料的唯一來源（報表、退款紀錄、會員帳戶）
- `invoice.rolls[].usedThrough` 一定要給（見上）

### `GET /events?after=<serverSeq>&limit=500`

同一家店**所有裝置**的事件（含自己的；App 用 id 去重），照 `serverSeq` 排。
```json
← { "events": [ … ], "next": 98113, "hasMore": false }
```
新裝置第一次同步：`after=0` 只給最近 2 個營業日的事件，加上還沒結帳的單的所有事件（後台用 `pos_events.ticket_id` 找）。

### 投影（後台收到事件時做的事）

後台**不重算**單子：結帳那一刻 iPad 會送出完整的 `SaleRecord`（`ticket.closed` 的 `data.sale`），後台存那一份、只檢查加起來對不對。

| type | 後台做什麼 |
|---|---|
| `ticket.closed` | 寫 `pos_sales`、`pos_sale_lines`、`pos_payments`。檢查 `Σ lines.net + serviceCharge == total`、`Σ payments.amount ≥ total + tip`，不對的話照樣存、`status='flagged'`，在後台標出來。有會員（`member.id`）就把 `total` 加到他的累積消費、重算會員等級（和網路訂單同一套）。品項有 `productId` 的扣網路商店的庫存。即時通知後台儀表板（realtime `{t:'sale'}`）。|
| `invoice.issued` | 寫 `pos_invoices`（`upload_status='pending'`），排進上傳佇列（48 小時內要上傳到財政部）。|
| `invoice.voided` | 標作廢、排作廢上傳（F0501）。|
| `sale.refunded` | 寫 `pos_refunds`；`pos_sales.refunded` 加上金額、`status` 改 `refunded`／`partially_refunded`；有折讓單（`allowance`）就排上傳（G0401）。會員累積消費扣回。|
| `ticket.voided` | 只存事件（報表從事件算作廢）。|
| `shift.closed` | 寫 `pos_shifts`（含 `data.report` 交班單）；推播給負責人：「櫃台 1 交班：營業額 NT$xx、現金短少 NT$yy」。|
| `item.availability` | 更新 `pos_items.is_available`（後台與其他 iPad 都看到賣完）。|
| `sale.exchanged` | 同款換規格（換尺寸、換顏色，同價）：每個 `swaps[]` 把 `fromSkuId` 的庫存加回、`toSkuId` 扣掉（有 `toProductVariantId` 的扣網路商店的規格）。不動錢、不動發票。|
| `member.checkedIn` | 寫 `pos_checkins`；`uses > 0` 時扣那張卡的次數（見「會員帳戶」）。|
| `member.checkInVoided` | 標取消；還回次數。|
| 其他 | 只存（新版 App 的事件也是：原樣存、原樣轉發）。|

`ticket.closed`、`sale.refunded` 另外還要做「會員帳戶」與「庫存」的投影（見下）。

## 發票號碼段

### `POST /invoice/rolls`

```json
→ { "period": "11510", "count": 50 }
← { "roll": { "id": "…", "period": "11510", "track": "AB", "start": 12345650, "end": 12345699 } }
```
後台從這一期的字軌（後台「電子發票 → 字軌」由店家輸入財政部配給的號碼）切下一段給這台，`count` 最多 250。
`409 no_numbers`：這一期沒有字軌或用完了（App 提示「請到後台新增字軌」，這段時間不能開發票）。
App 在剩不到 10 張、或下一期快開始（最後 3 天）時自動要。

## 會員

- `GET /members?phone=0912345678` → `{ "member": { id, phone, name, tierName, lifetimeSpend, visits, lastVisitAt, note, wallet, passes, accountEventIds, recentVisits, photoURL, birthday } }` 或 `{ "member": null }`
  （和網路商店同一份會員；電話正規化成 `+886…` 再找）
  - `wallet`：儲值金餘額（分）；`passes`：課程卡／會籍（`MemberPass`：`id, name, spec, remaining, startsAt, expiresAt, ticketId, unitValue, status`，含最近用完、過期的）
  - `accountEventIds`：**最近 7 天**後台已經算進 `wallet`／`passes` 的 POS 事件 id。iPad 把自己記了、但不在這份清單裡的事件補算上去（斷網時也對）
  - `recentVisits`：最近 10 次消費（門市＋網路）：`ticketId, number, at, total, items[], staffNames[], note`
  - `birthday`：`MM-DD`
- `POST /members` `{ phone, name }` → `{ member }`（現場加入會員；已存在就回原本的）
- `PATCH /members/:id` `{ name?, note?, birthday? }` → `{ member }`（美業的配方、偏好記在 note）

## 掃碼（手機用相機、iPad 用條碼機或相機）

手機不接條碼機：右下的「掃碼」用相機掃，iPad 的外接條碼機打進來的字也走同一條路。App 照內容判斷是什麼（`POSModel.handleScan`），一個鍵就好：

| 掃到的 | 怎麼認 | 做什麼 |
|---|---|---|
| 手機條碼載具 | `/` 開頭 8 碼（`/ABC+123`） | 掛在這張單的發票上（結帳櫃台照用）；沒有單就先記著，下一張單用 |
| 自然人憑證載具 | 2 個英文 + 14 個數字 | 同上 |
| 會員 | 裡面有 `09` 開頭 10 碼的手機號碼（會員卡的條碼／QR 就是手機號碼；網址 `…?phone=0912…` 也行） | `GET /members?phone=` → 掛到這張單（沒有單：打開會員） |
| 商品 | 品號、條碼、SKU（`Catalog.match`） | 加一份 |
| 折價券 | 其他（大寫英數，例如 `YG-A3B2C1`） | `GET /coupons/:code` → 套用到這張單 |

**右側鍵盤打的數字**也照內容判斷（`TypedDigits`），打完**停 0.8 秒**就自動做，不用再按鍵：
1–3 碼是數量；`09` 開頭 10 碼是會員電話（查了直接掛上這張單）；結帳中 8 碼、檢查碼對是統編（掛到發票）；剛好對到菜單、而且沒有更長的品號是它開頭的是商品（加入）。
其他的按鍵盤的大鍵（或外接鍵盤的 Enter；`TypedConfirm`）：對到品號就加那個品項（3 碼以內的品號也是）；`09` 開頭 10 碼查會員；
**沒有這個品號、1–6 位數就是多少錢**：直接加一筆「其他」（菜單上沒有的臨時價錢，應稅）；`0` 開頭或 7 碼以上的不當錢（多半是打錯的條碼），提示找不到品號。
大鍵上寫按下去會怎樣（「加入 鴨胸」「加 NT$120」），鍵盤上方也寫出它會被當成什麼（「會員 0912-345-678」「品號 2001 → 鴨胸」「NT$1,500」）。
**手機**沒有一直開著的鍵盤：點餐頁下面那條旁邊的鍵盤鍵叫出來（`POSModel.askTyped`），打完按大鍵一樣照上面做（找不到品號、又不像金額的留在鍵盤上說）。

**現金模式**（iPad：設定 → 營業模式；手機：更多 → 這支手機也能收款 → 現金模式。每台自己開；有錢櫃的收銀台 iPad、
或打開「這支手機也能收款」的手機才有效：`POSModel.cashModeActive`）：全部只收現金。手機的點餐頁下面換成常駐的鍵盤（`PhoneCashPad`），
不用另外叫；手機沒有發票出單機：要印證明聯的單請到櫃台（先掃載具、捐贈就能在手機收）。
打的數字一律是金額（不對品號，品號用條碼機掃；`09` 開頭 10 碼照樣是會員）→ 大鍵「收現金 NT$120」→ 加一筆「其他」、整張單
（連同已經點的品項）應收多少收多少現金（不找零、不進結帳畫面）→ 開發票、結帳、印（`POSModel.cashCheckout`）。
沒有單時先掃載具：記著、下一張單用，所以「掃載具 → 打金額 → 收現金」發票就開到那個載具。單子的「結帳」也變成「收現金」；
結帳畫面（開不了發票才會停在那裡）只剩現金。換貨單照平常進結帳畫面。

**條碼機**（iPad 外接）：一口氣打進來、最後 Enter 的整串直接照上表做——不會灌進鍵盤、不用按任何鍵；鍵盤正在問收多少錢、數量時也一樣（問的東西不動）。
鍵盤在問會員電話、統編、愛心碼這類的一串碼時，掃到的就是答案（PIN 不行，要人打）。人用外接鍵盤一個一個打的數字照樣進鍵盤（停 90 毫秒才放進去）。

## 折價券（門市）

和網路商店同一份折價券（後台「折價券」）。`channel` 是 `in_store` 或 `both` 的才能在門市用；`free_shipping` 不能用。

- `GET /coupons/:code?subtotal=12000&memberId=…` → `{ "coupon": { code, name, description, type: "fixed"|"percentage", value, minimumOrder, expiresAt, usesLeft }, "problem": null }`
  - `value`：`fixed` 是分（NT$100＝10000），`percentage` 是基點（9 折＝1000）
  - `problem`：不能用的原因（給店員看的一句，`null`＝可以用）：「已經過期（10/1）」「已經用完了」「只能在網路商店用」「停用了」「未達最低消費 NT$500」「這張券是別的會員的」「免運券不能在門市用」
  - 沒有這張券：`404 not_found`
  - 斷線：App 不能確認，**不套用**（避免同一張券兩邊用）
- 套用：整張單的折扣（`ticket.updated` 的 `discount`）帶上 `couponCode`：`{ kind: "amount"|"percent", value, reason: "折價券 新會員 100 元", couponCode: "YG-A3B2C1", minimumOrder: 30000 }`。一張單一個整單折扣：套折價券會換掉原本的整單折扣（App 先問）
  - `minimumOrder`（選填，分）：券的最低消費，抄在單子上，每一台都看得到——改了品項、小計（整單折扣前）低於它時單子上提醒，結帳前 App 拿掉這張券（`clearDiscount`）。後台不用管
- 結帳時：`ticket.closed` 的 `sale.couponCode`（整單折扣的折價券；`sale.orderDiscount` 是整單折扣的金額，分）→ 後台記一筆使用（`coupon_usages`：`order_id` 空、`pos_sale_id`、有會員就 `user_id`；一筆單只記一次），`usesLeft` 跟著少。
  已經用完了（另一台同時用掉）也照樣收這筆帳（事件不能退），在後台把這筆單標成 `flagged`「折價券超用」
- 退款（`sale.refunded` 全額退）：還回那一次使用

範例：`samples/coupon-lookup.json`、`samples/event-ticket-updated-coupon.json`、`samples/event-ticket-closed-coupon.json`。

## 會員帳戶（儲值金、課程卡、會籍）

帳戶的變動不另外傳：iPad 與後台照**同一套規則**從事件推出來（Swift 的 `AccountRules`，`Packages/POSKit/Sources/POSCore/Accounts.swift`）。只有 `sale.member.id` 有值的單才算。

| 事件 | 帳戶變動 |
|---|---|
| `ticket.closed`，行的 `kind = storedValue` | 儲值金加 `(credit ?? unitPrice) × quantity` |
| `ticket.closed`，行的 `kind = pass` | 每一個數量發一張卡：`id` = `lineId`（數量 1）或 `lineId#1`、`lineId#2`…；`remaining` = `pass.visits`（次數卡）；`startsAt` = `passStartsAt ?? closedAt`；`expiresAt` = `startsAt` 那天（台北）00:00 加 `validDays` 天；`unitValue` = 實收 ÷ 數量 ÷ 次數（整數元、四捨五入；期間會籍＝實收 ÷ 數量） |
| `ticket.closed`，行有 `redeem` | 那張卡扣 `quantity` 次（`remaining` 到 0 → `usedUp`） |
| `ticket.closed`，付款 `tender = prepaid` | 儲值金扣 `amount` |
| `sale.refunded`，`tender = prepaid` | 儲值金加回 `refund.amount` |
| `sale.refunded`，退了儲值的行 | 儲值金扣 `(credit ?? unitPrice) × 退的數量` |
| `sale.refunded`，退了課程卡的行 | 從最後一張往前作廢（`cancelled`）退的數量 |
| `sale.refunded`，退了有 `redeem` 的行 | 那張卡還回退的數量 |
| `member.checkedIn`（`uses > 0`） | 那張卡扣 `uses` 次；`member.checkInVoided` 還回 |

「退了哪些行」：`refund.lines` 有列就照列的；沒列而且 `refund.amount ≥ sale.total`＝全部；只退一部分金額（沒列品項）不動帳戶。
扣成負的（兩台都斷網、各扣一次）照記，標出來給店長處理。

## 品項的種類與規格（服飾、美業、健身）

`catalog.items[]` 選填的欄位（沒有＝一般商品、沒有規格）：

| 欄位 | |
|---|---|
| `kind` | `goods`（預設）、`service`（剪髮、私人教練一堂）、`pass`（課程卡、會籍）、`storedValue`（儲值） |
| `optionNames` | 規格的維度：`["顏色","尺寸"]` |
| `variants[]` | `id, options[]（照 optionNames 排：["黑","M"]）, sku, barcode, price（沒有＝品項價）, stock, isAvailable, productVariantId（網路商店的規格，扣同一份庫存）` |
| `durationMinutes` | 服務多久（排預約） |
| `pass` | `PassSpec`：`kind`（`visits` 次數卡／`period` 期間會籍）, `visits`, `validDays`, `itemIds[]`／`categoryIds[]`（能抵哪些服務）, `checkIn`（健身房入場用） |
| `credit` | 儲值進去的金額（儲 10,000 送 1,000 → 1,100,000 分） |
| `commissionBps` | 抽成（萬分比；沒有用服務人員的） |

單子上的行（`lines.added` 的 `TicketLine`、`ticket.closed` 的 `SaleLine`）對應帶：`kind, skuId（門市規格 id）, variantName（「黑・M」）, staffId（業績算給誰：SaleLine 上已經決定好）, assistantId, durationMinutes, pass, passStartsAt, credit, redeem{passId,name,value}, commissionBps`。
`ticket.opened` 選填：`serviceMode, member, salespersonId, exchange{ticketId, number, lines[], amount}, appointmentId`。

**庫存**：`ticket.closed` 每一行有 `skuId` 的扣門市規格的庫存、有 `variantId`（網路商店規格）的扣網路商店的；退款反過來。

**付款方式**多了 `prepaid`（儲值金）與 `exchange`（換貨抵用：退回的商品抵掉新買的；`change` > 0＝退差額，從錢櫃拿現金）。實收不算這兩種。

**換貨**：結帳時同一批事件裡有原單的 `sale.refunded`（`tender = exchange`，照規則作廢或開折讓）與新單的 `ticket.closed`（`payments` 有一筆 `exchange`、`exchange` 欄位指向原單）。

**發票與儲值**：`prepaidInvoicing = atTopUp` 時，用儲值金付的部分 iPad 已經從發票扣掉（發票上有一行「儲值金扣抵」）；`atRedemption` 時賣儲值那一行不開。課程卡抵用的行金額是 0，不列。

## 崗位

`device.role`（配對時決定，店長也可以在 iPad 上改；改了會在心跳的 `workstation` 回報）：

| role | 名稱 | 側欄 | 收錢 | 錢櫃 |
|---|---|---|---|---|
| `register` | 結帳櫃台 | 全部 | ✓ | ✓ |
| `handheld` | 前場點餐 | 點餐、桌位、預約、報到、訂單、會員、訂位 | 刷卡、電子支付 | |
| `reception` | 報到接待 | 桌位（帶位）、預約、報到、叫號、會員、訂位、訂單 | | |
| `kitchen` | 後廚 | 廚房、訂單 | | |
| `expo` | 出餐口 | 廚房（所有出單站）、叫號、訂單 | | |

會收錢的崗位（`register`、`handheld`）才要號碼段：`POST /invoice/rolls` 照裝置**目前**的崗位（心跳回報的 `workstation`，沒有就用配對時的）判斷，不是配對時的。

**iPhone**：同一個 App 裝在 iPhone 上是店員手上的點餐機，崗位一律是 `handheld`（後台設成 `kitchen`、`expo` 的照舊），心跳也這樣回報。
手機預設**不收錢**（不要號碼段）：點好的單「送到結帳櫃台」，客人到櫃台一起結；店長在手機上打開「這支手機也能收款」才會結帳（刷卡、電子支付）、才要號碼段。

**送到結帳櫃台**（統一結帳）：不收錢的裝置（手機、報到接待）把單交給櫃台，記一筆 `bill.printed`，`data` 多一個 `sentFrom`（從哪裡送來：「手機」「報到接待」）：
`{"sentFrom":"手機","ticketId":"…"}`。沒有 `sentFrom` 的就是真的印了結帳單（舊的資料不變）。兩種都是「待結帳」；後台照樣只存、原樣轉發，舊版 App 也當成待結帳。

**刪掉品項不留紀錄**：還沒送出的品項用 `lines.removed`（`{ "ticketId", "lineIds": [] }`）直接從單子拿掉；已經送出的照樣用 `lines.voided`
（廚房要印作廢單），但 iPad 的單子上不再留一行劃掉的。

**叫號的號碼**：`ticket.updated` 多一個 `queueNumber`（外帶結帳自動取的、排隊入座叫到的；`0`＝拿掉），交易紀錄（`sale`）也帶著。

**手機送單的廚房單**：沒有設定廚房出單機的裝置（前場的手機）送單時，`lines.sent` 的 `data` 多一個 `relayPrint`（`new` 第一次送、`add` 加點、`fire` 催菜），自己不印；
櫃台的 iPad（設定「幫手機出廚房單」，預設開；有好幾台櫃台時只留一台）收到後照同一個樣式印到負責那一站的出單機。同一個事件只印一次、只印 10 分鐘內送的。
沒有這個欄位＝送單的那台自己印了（或不用印）。
櫃台的 iPad 收到別台送來的會跳出那張單（大鍵「去結帳」）。

## 訂位與候位

- `GET /reservations?date=2026-10-03` → `{ "reservations": [ … ] }`（那一天的訂位＋還在排的候位）
- `POST /reservations` → `{ reservation }`；候位（`kind: "waitlist"`）自動給 `queueNumber`（每天從 1 開始）
- `PATCH /reservations/:id`（只送要改的）→ `{ reservation }`
- `POST /reservations/:id/notify` → `{ "sent": true }`：發簡訊「您的位子好了」（要有「簡訊」服務；沒有回 `409 sms_off`）

範例：`samples/reservation.json`。

預約服務（美業、私人教練）與團體課報名也走這組 API：
- `kind`：`reservation`（訂位）、`waitlist`（候位）、`appointment`（預約服務）、`classBooking`（團體課報名）
- 選填：`staffId`（指定的設計師、教練；`PATCH` 時送 `""`＝改回不指定）、`services[]`（`itemId, name, durationMinutes, staffId?, price?`）、`memberId`、`sessionId`（團體課）、`ticketId`（到店後開的單）
- `GET /classes?date=2026-10-04` → `{ "classes": [ { id, name, staffId, startsAt, durationMinutes, capacity, booked, room, itemId, dropInPrice, note } ] }`（後台「課表」排的；`booked` 不含取消）

## 叫號（號碼牌）

店裡的號碼牌：取號 → 出單 → 叫號 → 過號。黃毛丫頭原本的叫號系統（`yellowgirl-queue-system`：Railway 的 Flask 伺服器、
樹莓派出單與叫號螢幕）整合進來，iPad 的「叫號」頁取代原本的 TicketSystem App。後台設定（`queue`）決定號碼存在哪裡：

| `mode` | 號碼存在 | 樹莓派、叫號螢幕、客人的 QR |
|---|---|---|
| `legacy` | 原本的叫號伺服器（`queue.legacyUrl`，例：`https://yellowgirl.up.railway.app`）；後台代轉，iPad 不直接連 | 照舊，不用改 |
| `native` | 後台自己的資料庫（一次一筆、鎖住再改，不會互相覆蓋；每天 `resetHour` 點後第一次用到時歸零） | 樹莓派 `server_url.txt` 改成 `{CMS_URL}/api/pos/queue/status`；號碼牌的 QR 預設 `{CMS_URL}/q?no={number}&waiting={waiting}` |

**叫號是獨立的服務插件**（後台的 `queue` 模組，可以單獨開、不一定要有 POS）：沒有 POS 的店用後台「叫號」頁的按鈕取號、叫號；
有 POS 時 iPad 的「叫號」頁、右欄與結帳流程接上同一份號碼。`queue.usage` 決定用在哪裡（可以兩個都開）：

| usage | 情境 | POS 怎麼用 |
|---|---|---|
| `takeout` | 全外帶（夜市攤、手搖飲；黃毛丫頭） | **一張單一個號碼**：外帶單**一進結帳就取號**（`take` 帶 `ticketId`，`requestId` 固定是 `take-<ticketId>`：重送、結完再取都拿回同一個號碼）、印號碼牌、單子掛上號碼（`ticket.updated` 的 `queueNumber`）。這個號碼就是單號：結帳畫面、收據（取餐號碼＋QR）、廚房、叫號都寫它，A036 這種單號只留在訂單、交易序號（查帳、退貨）。取號時連不上：照樣結帳，結完再取一次。單子作廢、改成內用：`cancel` 放回號碼。做好了在右欄叫號（`call` 指定號碼：先做好的先叫） |
| `dineIn` | 排隊等內用 | 取號時打人數（`take` 帶 `guests`）；叫到號時選桌入座（開內用單、掛上號碼） |
| 都沒開 | 只有「叫號」頁 | 店員自己取號、叫號（和原本的 TicketSystem App 一樣） |

開機資料：`features.queue`（沒開就沒有這一頁）、`queue: { mode, customerUrl, ticket, usage }`：
- `customerUrl`：印在號碼牌、收據 QR 的網址樣板，`{number}`、`{waiting}`、`{date}`（營業日 `20261005`：號碼每天從 1 開始，舊的號碼牌掃了知道是哪一天的）會被換掉。黃毛丫頭：`https://yellowgirl.tw/q/{number}?d={date}`（叫到幾號、前面幾位、大約還要等多久）。`native` 預設是後台的 `/q`；`legacy` 沒有預設，要在後台貼上樹莓派原本 `qr_url.txt` 的網址（沒填就不印 QR）
- `ticket`：號碼牌的版面（**iPad 直接印**，不用樹莓派）。座標都以 58 mm 的 384 點寬為準（80 mm 的機器等比放大），預設值和樹莓派原本印的一模一樣：

```json
{ "backgroundUrl": "https://…/queue-ticket-bg.jpg", "height": 640, "copies": 1,
  "number": { "y": 140, "size": 90, "color": "white" },
  "waiting": { "y": 290, "size": 20, "color": "black", "text": "目前 {waiting} 人等候中" },
  "qr": { "size": 0.45, "bottom": 100 } }
```
  背景圖照比例裁滿 384×`height`（cover、置中）；號碼、等候人數水平置中；QR 寬度＝`size`×384、離底部 `bottom` 點。沒有背景圖時 iPad 用自己的預設版面。

**誰印**：出單機的用途勾「號碼牌」的那台 iPad。在這台取號＝馬上印；另外可以打開「也印別台取的號碼」（取代樹莓派的出單：看到 `waiting` 多了沒印過的號碼就印，同一個營業日不重複，號碼從 1 重新開始時清掉紀錄）——一家店只開一台。

### `GET /queue` → 現在的狀態

```json
{ "mode": "native", "current": 23, "waiting": [24, 25, 26], "missed": [19], "marked": [25],
  "nextNo": 27, "calledAt": "2026-10-04T07:12:00.000Z", "updatedAt": "2026-10-04T07:12:00.000Z",
  "takenAt": { "24": "2026-10-04T07:01:10.000Z", "25": "…", "26": "…" }, "servedToday": 22 }
```
- `current`：現在叫到的號碼（沒有就不出現）；`waiting`：照順序；`missed`：過號；`marked`：標記（店員自己看的星號）
- `calledAt`、`takenAt`、`servedToday`：只有 `native` 才有（舊伺服器沒記）
- `entries`：號碼的附帶資料（`native`）：`{ "24": { "guests": 4 }, "25": { "ticketId": "…", "label": "A012・3 項" } }`

### 動作：`POST /queue/<action>` → 改完的狀態（和 `GET /queue` 一樣）

| 動作 | body | 做什麼 |
|---|---|---|
| `take` | `{ "count": 1–20, "requestId": "<uuid>", "guests"?, "ticketId"?, "label"? }` | 取號：`nextNo` 起連續 `count` 張加到 `waiting` 最後。回應多一個 `"numbers": [27, 28]`。同一個 `requestId` 十分鐘內重送不會再取（`native`）。`count` 是 1 時可以帶附帶資料（存進 `entries`；`legacy` 略過） |
| `call` | `{ "number": 25, "requestId" }` | 叫指定的號碼：等候中的那一號變成 `current`（原本的算服務完了）。外帶先做好的先叫。只有 `native`（`legacy` 回 `409 unsupported`：只能照順序「下一號」） |
| `next` | `{ "requestId" }` | 叫下一號：`waiting` 第一個變成 `current`（原本的 `current` 算服務完了，順便取消它的標記）；`waiting` 空的＝`current` 清掉 |
| `miss` | `{ "requestId" }` | 過號：`current` 移到 `missed`，自動叫下一號 |
| `previous` | | 返回前一號：`current` 放回 `waiting` 最前面。沒有在叫的回 `400 nothing_called` |
| `recall` | `{ "number": 19 }` | 再叫一次過號的：從 `missed` 拿出來變成 `current`。只有 `native`（舊伺服器沒有這個動作，回 `409 unsupported`） |
| `unmiss` | `{ "number": 19 }` | 從過號清單刪掉（同時取消標記） |
| `mark`／`unmark` | `{ "number": 25 }` | 標記／取消標記 |
| `reset` | `{ "staffId": "…" }` | 全部歸零（iPad 先要店長 PIN） |
| `cancel` | `{ "number": 33, "requestId" }` | 放回號碼（外帶單作廢、改成內用）：從 `waiting`／`missed`／`marked` 拿掉，正在叫的就停（不算服務完）；已經不在了也回 200（重送不出錯）。`requestId` 是 `cancel-<ticketId>`。只有 `native` |

錯誤：`409 queue_off`（後台沒開叫號）、`502 upstream`（`legacy` 模式連不到原本的伺服器；iPad 顯示「叫號伺服器連不上」，不要重試動作類的請求）。
iPad 在叫號頁每 2 秒 `GET /queue`；動作的回應直接拿來更新畫面。叫號要網路（和原本的 App 一樣），斷線時這一頁只能看不能按。

### 公開的（不用登入，只有 `native`）

- `GET /api/pos/queue/status`（同一份也在 `GET /api/queue/status`）→ `{ "current": 23, "waiting": [24, 25], "missed": [19], "marked": [], "next_no": 27 }`：
  和原本叫號伺服器的 `/status` **一模一樣的格式**（樹莓派只要換網址）；允許跨網域、不快取。
  這兩個網址、`/q`、後台的叫號頁屬於 `queue` 模組：只開叫號（`CMS_MODULES=content,queue`）也有；開了 `pos` 一定有 `queue`
- `GET /q?no=24` → 給客人看的頁面：現在叫到幾號、你前面還有幾位，每 5 秒更新

範例：`samples/queue-state.json`。

## 歷史

`GET /history?date=2026-10-01` → 那一個營業日所有裝置的資料（iPad 只留最近兩天，更早的跟後台要）：

```json
{ "businessDate": "2026-10-01",
  "sales": [ …ticket.closed 的 data.sale 原樣… ],
  "refunds": [ { "ticketId": "…", "refund": { …sale.refunded 的 data.refund… } } ],
  "voidedTickets": [ { "ticketId": "…", "number": "A012", "items": 3, "amount": 27000, "reason": "客人走了" } ],
  "invoiceNumbers": ["AB12345650", "…"], "voidedInvoiceNumbers": ["…"], "checkIns": 42 }
```
報表在 iPad 上用同一套 `SalesSummary` 算（後台不必重寫報表算法）。

## 其他

- `PUT /floor` `{ areas, staffId }` → `{ floor, version }`：iPad 上改桌位圖（店長 PIN 授權）
- `POST /heartbeat` `{ appVersion, outbox, lastSeq, printers[], battery, openTickets, staffId, workstation }` → `{ serverTime, configVersion, serverSeq }`：每分鐘一次；後台「裝置」頁顯示在線、未送出的事件數、出單機狀態、目前的崗位
