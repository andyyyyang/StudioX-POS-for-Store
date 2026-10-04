# POS ↔ 後台 API

iPad（StudioX POS）和每家店自己的後台（atelier-cms，開了「門市 POS」服務插件）之間的約定。
Swift 端的型別在 `Packages/POSKit/Sources/POSSync/APIModels.swift`，範例 JSON 在 `docs/samples/`（由測試產生，和程式一定一致）。

## 共通規則

- 路徑前綴：`{CMS_URL}/api/pos/v1`。配對碼查店家走 console：`{CONSOLE_URL}/api/pos/resolve`。
- 認證：配對後每個請求帶 `Authorization: Bearer <token>`（`sxpos_<deviceId>.<secret>`；後台只存 SHA-256）。
- 金額：**整數「分」**（NT$60 → `6000`），和後台資料庫一樣。
- 時間：ISO 8601、UTC、毫秒（`2026-09-21T14:13:20.000Z`）。營業日 `businessDate` 是台北時間的 `YYYY-MM-DD`（凌晨 4 點前算前一天，店家可改）。
- JSON key 是 camelCase；選填欄位沒有值時**不出現**（不是 `null`）。
- 錯誤：HTTP 4xx/5xx ＋ `{ "error": "<code>", "message": "給人看的一句話" }`。
  - `401 unauthorized`：token 不對 → App 回到配對畫面
  - `401 revoked`：後台移除了這台 → App 清掉本機資料、回到配對畫面
  - `403 service_off`：StudioX 沒開通／店家暫停了「門市 POS」 → App 照常營業（離線模式），提示「後台暫停同步」
  - `429 rate_limited`

## 配對

### `POST {CONSOLE_URL}/api/pos/resolve`（不用登入）

接 StudioX 的店家：iPad 上只要在右側鍵盤打 8 位數配對碼，不用打網址。

```json
→ { "code": "48213907" }
← { "cmsUrl": "https://cms.example.tw", "siteName": "晨麥手作" }
```
`404 not_found`（碼不存在或過期）。後台產生配對碼時把 `{code, cmsUrl, expiresAt}` 登記到 console（`POST {CONSOLE_URL}/api/platform/pos/pairing`，用網站的 `sxk_` 憑證）。

### `POST /pair`（不用登入）

```json
→ { "code": "48213907", "device": { "name": "櫃台 iPad", "model": "iPad16,3", "systemVersion": "26.1", "appVersion": "1.0 (2610031200)" } }
← samples/pair-response.json
```
- 配對碼 8 位數、10 分鐘有效、用一次就失效；產生時就決定角色（收銀機／點餐機／廚房螢幕）與名稱。
- `deviceCode`：這家店還沒被使用中的裝置用掉的第一個字母（A–Z）。單號 = 字母＋當天流水號（A001）。
- 錯 5 次鎖這個 IP 10 分鐘。

## 開機資料

### `GET /bootstrap`

`If-None-Match: <version>` 沒變就回 `304`。內容見 `samples/bootstrap.json`：

| 欄位 | 內容 |
|---|---|
| `version` | 設定的版本（菜單、桌位、人員、店家設定、號碼段任一個改了就變） |
| `device` | 這台：`id, name, code, role, stations` |
| `store` | `StoreProfile`：店名、統編、地址、服務費、營業日分界、折扣上限、找零快速鍵、`serviceModes`（開了哪些營業模式：`tableService`／`counter`／`retail`／`cafe`）與 `defaultServiceMode`。少給的欄位 iPad 用預設值 |
| `features` | 開了哪些功能：`seating, kitchen, reservations, invoice, members, waitlistSMS` |
| `catalog` | `categories`（`swatch` 是色塊名稱）、`items`（只給上架的；`isAvailable=false` 是今天賣完）、`modifierGroups` |
| `floor` | `areas[].tables[]`，座標是 0–100 的格子 |
| `staff` | 門市人員（只給啟用中的），含 PIN 雜湊：`PBKDF2-HMAC-SHA256(pin, pinSalt, pinIterations, 32 bytes)` 的十六進位。後台用 Node：`crypto.pbkdf2Sync(pin, salt, iterations, 32, 'sha256').toString('hex')` |
| `invoice` | `enabled, sellerTaxId, sellerName, sellerAddress, qrKey`（財政部的 QR Code 加密金鑰，32 個十六進位字）、`rolls`（**這台**還在用的號碼段） |
| `mesh` | 同一家店的 iPad 在區網互相同步用的金鑰（32 bytes 十六進位）與開關 |

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
| 其他 | 只存。|

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

- `GET /members?phone=0912345678` → `{ "member": { id, phone, name, tierName, lifetimeSpend, visits, lastVisitAt, note } }` 或 `{ "member": null }`
  （和網路商店同一份會員；電話正規化成 `+886…` 再找）
- `POST /members` `{ phone, name }` → `{ member }`（現場加入會員；已存在就回原本的）

## 訂位與候位

- `GET /reservations?date=2026-10-03` → `{ "reservations": [ … ] }`（那一天的訂位＋還在排的候位）
- `POST /reservations` → `{ reservation }`；候位（`kind: "waitlist"`）自動給 `queueNumber`（每天從 1 開始）
- `PATCH /reservations/:id`（只送要改的）→ `{ reservation }`
- `POST /reservations/:id/notify` → `{ "sent": true }`：發簡訊「您的位子好了」（要有「簡訊」服務；沒有回 `409 sms_off`）

範例：`samples/reservation.json`。

## 其他

- `PUT /floor` `{ areas, staffId }` → `{ floor, version }`：iPad 上改桌位圖（店長 PIN 授權）
- `POST /heartbeat` `{ appVersion, outbox, lastSeq, printers[], battery, openTickets, staffId }` → `{ serverTime, configVersion, serverSeq }`：每分鐘一次；後台「裝置」頁顯示在線、未送出的事件數、出單機狀態
