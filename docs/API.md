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
| `device` | 這台：`id, name, code, role, stations`。`role` 是崗位（見下方「崗位」）；不認得的值 iPad 當作 `register` |
| `store` | `StoreProfile`：店名、統編、地址、服務費、營業日分界、折扣上限、找零快速鍵、`serviceModes`（開了哪些營業模式：`tableService`／`counter`／`retail`／`cafe`／`apparel`／`salon`／`fitness`）與 `defaultServiceMode`、`prepaidInvoicing`（`atTopUp` 儲值時開發票［預設］／`atRedemption` 消費時開）、`exchangeDays`（幾天內可以換貨，預設 7、0＝不限）、`bookingSlotMinutes`（預約表一格幾分，預設 15）。少給的欄位 iPad 用預設值 |
| `features` | 開了哪些功能：`seating, kitchen, reservations, invoice, members, waitlistSMS, appointments, accounts, commission`。後三個沒給＝`false`（要後台有對應的資料表才開） |
| `catalog` | `categories`（`swatch` 是色塊名稱）、`items`（只給上架的；`isAvailable=false` 是今天賣完；非餐飲的欄位見下方「品項的種類與規格」）、`modifierGroups` |
| `floor` | `areas[].tables[]`，座標是 0–100 的格子 |
| `staff` | 門市人員（只給啟用中的），含 PIN 雜湊：`PBKDF2-HMAC-SHA256(pin, pinSalt, pinIterations, 32 bytes)` 的十六進位。後台用 Node：`crypto.pbkdf2Sync(pin, salt, iterations, 32, 'sha256').toString('hex')`。選填：`title`（職稱：設計師、教練）、`bookable`（排進預約表）、`commissionBps`（預設抽成，萬分比） |
| `invoice` | `enabled, sellerTaxId, sellerName, sellerAddress, qrKey`（財政部的 QR Code 加密金鑰，32 個十六進位字）、`rolls`（**這台**還在用的號碼段；每段帶 `usedThrough`＝後台收到這一段用到的最後一號，iPad 一定從它的下一號開始，所以本機事件刪掉了也不會重號） |
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
| `reception` | 報到接待 | 桌位（帶位）、預約、報到、會員、訂位、訂單 | | |
| `kitchen` | 後廚 | 廚房、訂單 | | |
| `expo` | 出餐口 | 廚房（所有出單站）、訂單 | | |

會收錢的崗位（`register`、`handheld`）才要號碼段：`POST /invoice/rolls` 照裝置**目前**的崗位（心跳回報的 `workstation`，沒有就用配對時的）判斷，不是配對時的。

## 訂位與候位

- `GET /reservations?date=2026-10-03` → `{ "reservations": [ … ] }`（那一天的訂位＋還在排的候位）
- `POST /reservations` → `{ reservation }`；候位（`kind: "waitlist"`）自動給 `queueNumber`（每天從 1 開始）
- `PATCH /reservations/:id`（只送要改的）→ `{ reservation }`
- `POST /reservations/:id/notify` → `{ "sent": true }`：發簡訊「您的位子好了」（要有「簡訊」服務；沒有回 `409 sms_off`）

範例：`samples/reservation.json`。

預約服務（美業、私人教練）與團體課報名也走這組 API：
- `kind`：`reservation`（訂位）、`waitlist`（候位）、`appointment`（預約服務）、`classBooking`（團體課報名）
- 選填：`staffId`（指定的設計師、教練）、`services[]`（`itemId, name, durationMinutes, staffId?, price?`）、`memberId`、`sessionId`（團體課）、`ticketId`（到店後開的單）
- `GET /classes?date=2026-10-04` → `{ "classes": [ { id, name, staffId, startsAt, durationMinutes, capacity, booked, room, itemId, dropInPrice, note } ] }`（後台「課表」排的；`booked` 不含取消）

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
