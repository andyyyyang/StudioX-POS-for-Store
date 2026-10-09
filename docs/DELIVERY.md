# 外送平台串接（Uber Eats、foodpanda）

外送平台的單直接進 POS：不用另外的平板、不用重打。平台的單在後台收下、變成一張「外送」的單，同步到每一台 iPad，
廚房、出餐口、報表都和店裡的單一樣；接單、拒單、出餐好了、暫停接單、賣完都在 POS 上做，後台替你告訴平台。

這份文件是 iPad（POSKit）、後台（atelier-cms 的 `src/lib/delivery`）、各平台連接器之間的約定。和 [API.md](API.md) 一樣：
金額一律是整數「分」（NT$1 = 100）、時間是 ISO 8601 UTC（毫秒）、沒有的欄位不送（不送 null）。

```
平台 ──webhook──▶ 後台 /api/delivery/<platform>/…   驗簽 → 去重 → 取完整訂單 → 換成 POS 的單
                     │                                   │
                     │  寫事件（後台的「外送平台」虛擬裝置）  ▼
                     │  ticket.opened(+delivery) / lines.added / payment.added(platform) / delivery.updated
                     ▼
iPad ◀── 照常同步（GET /events） ── 外送收件匣：倒數、打分鐘數接單、拒單、出餐好了
iPad ── POST /api/pos/v1/delivery/orders/{id}/accept … ──▶ 後台 ──▶ 平台 API（失敗排隊重試）
```

## 為什麼這樣做（和業界比）

| 痛點（Toast、Square、Deliverect、iCHEF 的商家最常抱怨的） | 這裡怎麼做 |
| --- | --- |
| 一個平台一台平板、單要重打 | 平台的單直接是 POS 的單，所有 iPad 都看得到；接單在右欄打分鐘數一鍵完成 |
| 沒接到單 → 平台自動取消、連續幾次被暫停到隔天 | 每張待接的單有倒數；「自動接單」在後台做（沒有 iPad 在線也接）；POS 全部斷線超過 3 分鐘，後台先替你把平台暫停，連回來自動恢復 |
| 賣完沒同步、客人點到沒有的 | 店裡按「賣完」，所有平台一起下架；恢復也一起 |
| 備餐時間固定，尖峰來不及 | 建議的備餐時間看廚房現在的份數（內用、外帶、叫號、外送一起算）；「忙碌」一鍵加時間或暫停 |
| 菜單對不上（PLU 不對）就掉單 | 平台上的品項 id 就是 POS 的品項 id（我們自己推菜單）；對不上的照樣進單（照平台寫的名稱與價錢），只標「沒對到」 |
| 抽成吃掉利潤、不知道每個平台實際賺多少 | 報表分通路：營業額、抽成、實收；每張外送單記平台撥款 |
| POS、中介、平台互踢皮球 | 直接串平台（不經中介）；每個平台的連線狀態、最後一張單、最近的錯誤都在設定頁 |
| 平台換人（foodpanda 台灣可能被 Grab 收購） | 平台是可替換的連接器（`DeliveryConnector`），換平台不動 POS |

## 資料：POSKit

### `DeliveryOrder`（掛在單子上）

`TicketOpened.delivery` / `Ticket.delivery`：這張單是外送平台的單。沒有＝店裡的單。

```jsonc
{
  "platform": "ubereats",            // ubereats | foodpanda
  "orderId": "8f3c…",                // 平台的訂單 id（Uber 的 order id、foodpanda 的 order token）
  "code": "3F2A1",                   // 給外送員、客人看的短碼（Uber display_id、foodpanda shortCode/code）
  "kind": "delivery",                // delivery 外送員來拿 | pickup 客人自取
  "status": "pending",               // 見下面的狀態
  "placedAt": "2026-10-09T04:12:00.000Z",
  "acceptBy": "2026-10-09T04:23:30.000Z",   // 這之前要接或拒，不然平台自動取消
  "readyAt": "2026-10-09T04:30:00.000Z",    // 答應幾點做好（接單時決定）
  "prepMinutes": 18,
  "scheduledFor": "…",               // 預約單：客人要的時間
  "customerName": "王小姐",
  "customerNote": "不要香菜",          // 整單備註（過敏也在這；看不到的平台規定要拒單）
  "courier": { "name": "陳先生", "status": "arriving", "eta": "…" },   // assigned | arriving | arrived | pickedUp
  "subtotal": 42000,                 // 平台上的品項合計（客人在平台上付的餐點錢）
  "commission": 13650,               // 抽成（平台給的；沒有就照設定的抽成率估，estimated=true）
  "payout": 28350,                   // 平台撥給店的
  "estimated": true,
  "invoice": { "carrier": "/ABC1234" },     // 客人在平台上填的載具／統編（平台有給才有）
  "test": false
}
```

狀態：

```
pending ──接單──▶ accepted ──出餐好了──▶ ready ──外送員拿走──▶ pickedUp
   │                 │                    │
   └─拒單─▶ rejected  └──── 平台取消 ──────┴──▶ cancelled
```

### 事件

| 事件 | 誰寫 | 內容 |
| --- | --- | --- |
| `ticket.opened` | 後台（外送平台裝置） | 原本的欄位＋`delivery`（`orderType`＝`delivery` 或 `takeout`、`number`＝`UE-3F2A1`／`FP-a1b2`、`customerName`） |
| `lines.added` | 後台 | 平台上的品項（`itemId`＝對到的 POS 品項，沒對到是空字串；價錢照平台；`kitchen`＝`new`） |
| `payment.added` | 後台 | `tender`＝`platform`、`amount`＝這張單的金額、`reference`＝平台名稱與短碼：平台已經收了錢 |
| `delivery.updated` | 後台 | `{ticketId, status?, readyAt?, prepMinutes?, courier?, reason?, commission?, payout?, acceptedBy?}`：只送有變的 |
| `lines.sent` | 接單的那台 iPad（或後台自動接單時，`relayPrint`＝`new` 請櫃台印） | 送廚房 |
| `ticket.closed` | 接單的那台 iPad | 外送單是先付的：接單就結帳（`platform` 付款），之後廚房照樣做、出餐口照樣出 |
| `ticket.voided` | 後台 | 還沒接就被拒、被平台取消、逾時 |

接單之後才被平台取消（已經結帳）：iPad 右欄提示「Uber Eats 取消了 UE-3F2A1」，一鍵退款（`platform`）。

### `Tender.platform`

「外送平台代收」：不是現金、不進錢櫃；報表的付款方式分平台（`reference` 開頭是平台名稱）。

## 後台：iPad 用的 API（`/api/pos/v1/delivery`）

都要裝置 token（和其他 `/api/pos/v1` 一樣）。外送的單本身從事件同步來，這裡只做「現在就要平台知道」的動作，
所以要連線；斷線時 iPad 擋住按鈕並說明。

| 方法 | 路徑 | 內容 | 回 |
| --- | --- | --- | --- |
| GET | `delivery` | — | `{platforms:[PlatformState], orders:[{ticketId, delivery}]}`（還沒結束的） |
| POST | `delivery/orders/{orderId}/accept` | `{prepMinutes}` | `{status:"accepted", readyAt, acceptedBy, mine}`；`mine`＝這台接的（這台負責結帳、送廚房） |
| POST | `delivery/orders/{orderId}/reject` | `{reason, message?}` | `{status:"rejected"}` |
| POST | `delivery/orders/{orderId}/ready` | — | `{status:"ready"}` |
| POST | `delivery/orders/{orderId}/cancel` | `{reason, message?}` | `{status:"cancelled"}` |
| POST | `delivery/busy` | `{extraMinutes, minutes?}` | 每個平台：之後的單備餐時間多加；`extraMinutes`＝0 取消 |
| POST | `delivery/pause` | `{platform?, minutes?}` | 暫停接單（沒給 platform＝全部；沒給 minutes＝到明天開店） |
| POST | `delivery/resume` | `{platform?}` | 恢復接單 |
| POST | `delivery/simulate` | `{platform, items?}` | 測試單（設定開了「測試模式」才行）：走完整的流程，平台那邊不會真的有單 |

`reason`（拒單、取消）：`too_busy` 太忙｜`item_unavailable` 有東西賣完｜`closed` 打烊了｜`other` 其他。
連接器把它換成平台的代碼（Uber 拒單：`RESTAURANT_TOO_BUSY`/`ITEM_ISSUE`/`STORE_CLOSED`/`OTHER`（舊版 API 是 `CAPACITY`/`ITEM_AVAILABILITY`）；foodpanda：`TOO_BUSY`/`ITEM_UNAVAILABLE`/`CLOSED`/`TECHNICAL_PROBLEM`）。

接單同一時間兩台按：後台用資料列鎖決定，第一個 `mine:true`、第二個回 `409 already_accepted`（iPad 照事件更新就好）。

`PlatformState`：

```jsonc
{ "platform": "foodpanda", "enabled": true, "connected": true, "storeName": "黃毛丫頭 文化店",
  "status": "online",                 // online | paused | offline（沒連上）
  "pausedUntil": "…", "pausedBy": "watchdog",   // watchdog＝POS 全部斷線時後台自動暫停的
  "busyExtraMinutes": 10, "autoAccept": true, "defaultPrepMinutes": 15,
  "lastOrderAt": "…", "lastError": { "at": "…", "message": "…" } }
```

### bootstrap

`features.delivery`（有串任何一個平台）；`delivery`：`{platforms:[PlatformState], commissionBps:{ubereats, foodpanda}}`。

## 後台：平台打進來的（不用裝置 token、各自驗簽）

| 平台 | 路徑 | 驗證 |
| --- | --- | --- |
| Uber Eats | `POST /api/delivery/ubereats/webhook` | `X-Uber-Signature`＝HMAC-SHA256(原始 body, client secret 或 webhook signing key) 的小寫十六進位；`event_id` 去重；回 200 空白 |
| Uber Eats | `GET /api/delivery/ubereats/oauth/callback` | 店家授權（`eats.pos_provisioning`）之後選要連的店 |
| foodpanda | `POST /api/delivery/foodpanda/order/{remoteId}` | `Authorization: Bearer <JWT HS512, service=middleware>`（plugin secret）；`token` 去重；回 `{remoteResponse:{remoteOrderId}}` |
| foodpanda | `PUT /api/delivery/foodpanda/remoteId/{remoteId}/remoteOrder/{remoteOrderId}/posOrderStatus` | 同上；`ORDER_CANCELLED`、`ORDER_PICKED_UP` |

收到的每一筆原樣記在 `pos_delivery_inbound`（除錯、對帳、平台說「我們有送」時查得到）。

## 後台：連接器（`src/lib/delivery/connectors/*`）

每個平台一個，介面一樣（`DeliveryConnector`，見 `src/lib/delivery/connector.ts`）：驗簽、把平台的格式換成 `NormalizedOrder`、
取訂單、接單／拒單／出餐好了／取消、店家暫停／恢復、品項賣完／恢復、推菜單。另有 `simulator`：不連任何平台，測試與示範用。

往平台的呼叫都經過 `pos_delivery_jobs`（排隊、指數退避重試、記錄最後的錯誤）；接單、拒單這種有時限的先直接呼叫，失敗才排隊。

## 店家要做的事（上線前）

- **Uber Eats**：Uber 核准成為串接夥伴（簽 NDA、API 授權、Uber 一起測試）才有正式的 client id/secret；店家在 POS 後台按「連結 Uber Eats」登入授權、選店。
- **foodpanda**：Delivery Hero 的 POS 串接夥伴（拿到 plugin secret、middleware 帳號、各店的 remoteId）；台灣 foodpanda 可能被 Grab 收購（公平會 2026-10-27 前決定），連接器可以換。
- 兩個平台：餐點的發票是店家開（平台只開外送費、服務費的發票）；外送單結帳時照店裡的發票設定開。
