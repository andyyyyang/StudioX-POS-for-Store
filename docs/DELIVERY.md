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

後台的程式：`src/lib/delivery/service.ts`（收單、接單、拒單…）、`device.ts`（虛擬裝置寫事件）、`build.ts`（事件內容，純函式）、
`queue.ts`（往平台的呼叫排隊重試）、`watchdog.ts`（看門狗）、`connectors/*`（各平台）。自我檢查：`npx tsx scripts/verify-delivery.mts`。

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
  "acceptBy": "2026-10-09T04:23:30.000Z",   // 這之前要接或拒，不然平台自動取消（見下面「接單期限」）
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
  "acceptedBy": "…",                 // 接單的裝置 id（後台自己接的：負責結帳的那台收銀機，或 "server"）
  "reason": "too_busy",              // 拒單、取消的原因
  "test": true                       // 平台的測試單、模擬器的單（false 不出現）
}
```

**接單期限**：平台給的和「後台收到這張單的時間＋平台的預設」取早的（Uber 11.5 分、foodpanda 8 分）。
Uber 的 11.5 分鐘是從我們收到 webhook 開始算；預約單 Uber 不給期限，就從收到這一次通知算。

狀態：

```
pending ──接單──▶ accepted ──出餐好了──▶ ready ──外送員拿走──▶ pickedUp
   │                 │                    │
   └─拒單─▶ rejected  └──── 平台取消 ──────┴──▶ cancelled
```

### 事件

| 事件 | 誰寫 | 內容 |
| --- | --- | --- |
| `ticket.opened` | 後台（外送平台裝置） | 原本的欄位＋`delivery`（`orderType`＝`delivery` 或 `takeout`、`number`＝`UE-3F2A1`／`FP-a1b2`、`customerName`；`tableIds` 空、`guests` 0、`serviceChargeBps` 0） |
| `lines.added` | 後台 | 平台上的品項（`itemId`＝對到的 POS 品項，沒對到是空字串；價錢照平台；`kitchen`＝`new`；`addedBy`＝`delivery`；`unitPrice` 是一份的價錢扣掉選項加價） |
| `ticket.updated` | 後台（只有平台上有店家出的優惠時） | `discount`＝`{kind:"amount", value, reason:"Uber Eats 店家優惠"}`：各行加起來比平台的品項合計多出來的部分，iPad 的總計才會等於平台的 `subtotal` |
| `payment.added` | 後台 | `tender`＝`platform`、`amount`＝這張單的總計（＝平台的品項合計）、`change` 0、`by`＝`delivery`、`reference`＝「Uber Eats #3F2A1」：平台已經收了錢 |
| `delivery.updated` | 後台 | `{ticketId, status?, readyAt?, prepMinutes?, courier?, reason?, commission?, payout?, estimated?, acceptedBy?}`：只送有變的 |
| `lines.sent` | 接單的那台 iPad（或後台自己接單時：`relayPrint`＝`new` 請櫃台印） | 送廚房 |
| `ticket.closed` | `acceptedBy` 那台 iPad | 外送單是先付的：接單就結帳（`platform` 付款），之後廚房照樣做、出餐口照樣出 |
| `ticket.voided` | 後台 | 還沒接就被拒、被平台取消、逾時（還開著的單才作廢；已經結帳的交給 iPad 退款） |

接單之後才被平台取消（已經結帳）：iPad 右欄提示「Uber Eats 取消了 UE-3F2A1」，一鍵退款（`platform`）。

事件 JSON 和 iPad 寫的一樣：key 照字母排、沒有值的不出現、時間是 ISO 8601 UTC 毫秒。

### 誰結帳（`acceptedBy`）

接單的那台負責結帳：`acceptedBy` 等於自己的裝置 id 的那台 iPad 自動結帳（`ticket.closed`，付款就是 `payment.added` 的 `platform`）。
後台自己接的（自動接單、快到期限的保底、平台那邊已經接了的單）：`acceptedBy`＝**最近 3 分鐘內看到的收銀機**（崗位 `register`，
心跳回報的優先、最近看到的那台）；沒有收銀機就最近看到的任何一台；都沒有＝`"server"`——收銀機上線時把 `acceptedBy`＝`"server"` 的單結掉。

### `Tender.platform`

「外送平台代收」：不是現金、不進錢櫃；報表的付款方式分平台（`reference` 開頭是平台名稱）。

## 後台：iPad 用的 API（`/api/pos/v1/delivery`）

都要裝置 token（和其他 `/api/pos/v1` 一樣）。外送的單本身從事件同步來，這裡只做「現在就要平台知道」的動作，
所以要連線；斷線時 iPad 擋住按鈕並說明。

| 方法 | 路徑 | 內容 | 回 |
| --- | --- | --- | --- |
| GET | `delivery` | — | `{platforms:[PlatformState], orders:[{ticketId, delivery}]}`（還沒結束的） |
| POST | `delivery/orders/{orderId}/accept` | `{prepMinutes}`（1–180） | `{status:"accepted", readyAt, prepMinutes, acceptedBy, mine}`；`mine`＝這台接的（這台負責結帳、送廚房：自己寫 `lines.sent`） |
| POST | `delivery/orders/{orderId}/reject` | `{reason, message?}` | `{status:"rejected"}`（還沒接的；單子作廢） |
| POST | `delivery/orders/{orderId}/ready` | — | `{status:"ready"}`（先在 POS 記下，回應之後才告訴平台；平台失敗排隊重試） |
| POST | `delivery/orders/{orderId}/cancel` | `{reason, message?}` | `{status:"cancelled"}`（接了之後的；還開著的單作廢） |
| POST | `delivery/busy` | `{extraMinutes, minutes?}` | `{platforms}`：每個平台之後的單備餐時間多加（0–120；0＝取消；`minutes` 後自動取消）。只影響後台算的備餐時間，不呼叫平台 |
| POST | `delivery/pause` | `{platform?, minutes?}` | `{platforms, failed?}`：暫停接單（沒給 platform＝全部；沒給 minutes＝到下一個營業日開始，營業日分界預設凌晨 4 點） |
| POST | `delivery/resume` | `{platform?}` | `{platforms, failed?}`：恢復接單 |
| POST | `delivery/simulate` | `{platform, items?}` | `{ticketId, orderId, code}`：模擬器產生的測試單，走完整的流程（含自動接單），平台那邊不會真的有單 |

`{orderId}`：單子的 `ticketId`（建議）或平台的 `orderId`。`items`（simulate）：`[{itemId?, name?, quantity?, price?}]`，沒給就從菜單隨機挑 1–4 個；
對不到菜單的照 `name`、`price` 進單（測「沒對到」）。測試單只有在那個平台的店開了「測試模式」，或後台不是正式環境（`NODE_ENV` 不是 `production`）
才能下，不然 `409 simulate_off`；模擬的單之後接單、拒單一律走模擬器（不會打到平台）。

錯誤（`{error, message}`，`message` 直接給人看）：`400 invalid`、`404 not_found`、
`409 already_accepted`（多帶 `acceptedBy`、`readyAt`）／`closed`／`not_pending`（已經接了的要用 cancel）／`not_accepted`（還沒接的要用 reject）／
`not_connected`（沒開這個平台）／`simulate_off`、`502 platform_error`（平台連不上或不收：後台已經短暫重試過；iPad 顯示 message，可以再按，或到平台的平板上處理）。

`reason`（拒單、取消）：`too_busy` 太忙｜`item_unavailable` 有東西賣完｜`closed` 打烊了｜`other` 其他。
連接器把它換成平台的代碼（Uber 拒單：`RESTAURANT_TOO_BUSY`/`ITEM_ISSUE`/`STORE_CLOSED`/`OTHER`（舊版 API 是 `CAPACITY`/`ITEM_AVAILABILITY`）；foodpanda：`TOO_BUSY`/`ITEM_UNAVAILABLE`/`CLOSED`/`TECHNICAL_PROBLEM`）。

接單同一時間兩台按：後台用資料列鎖決定，第一個 `mine:true`、第二個回 `409 already_accepted`（iPad 照事件更新就好）；同一台重送回原本的結果。
接單、拒單、取消、暫停是「現在就要平台知道」的：後台直接呼叫平台（可以重試的錯短暫重試 3 次，每次最多等 8 秒），不行就回 502、記在 `lastError`。

`PlatformState`：

```jsonc
{ "platform": "foodpanda", "enabled": true, "connected": true, "storeName": "黃毛丫頭 文化店",
  "status": "online",                 // online | paused | offline（沒連上）
  "pausedUntil": "…", "pausedBy": "watchdog",   // watchdog＝POS 全部斷線時後台自動暫停的；manual＝店裡按的；platform＝平台自己暫停的
  "busyExtraMinutes": 10, "autoAccept": true, "defaultPrepMinutes": 15,
  "lastOrderAt": "…", "lastError": { "at": "…", "message": "…" },
  "health": "ok",                     // 自動連線檢查：ok｜waiting_platform 等平台開通（不是錯誤）｜needs_reauth 要重新連結｜error；還沒檢查不出現
  "lastCheckedAt": "…" }
```

`connected`＝測試模式，或有串接商的帳密而且 `health` 是 `ok`（或還沒檢查）；沒連上 `status` 就是 `offline`。
iPad 可以照 `health` 說明：`waiting_platform`「等 foodpanda 開通（自動重試中）」、`needs_reauth`「請負責人在後台重新連結」。

### bootstrap

`features.delivery`（後台開了任何一個平台的店；一律出現）；`delivery`：`{platforms:[PlatformState], commissionBps:{ubereats?, foodpanda?}}`（`features.delivery` 開著才有）。
開機資料的 `PlatformState` 不帶 `lastOrderAt`、`lastCheckedAt`（常常變、所有 iPad 都要重抓）；`GET delivery` 有。每個平台一筆：開著的那家店（一個平台同時只開一家）。

## 後台：平台打進來的（不用裝置 token、各自驗簽）

| 平台 | 路徑 | 驗證 |
| --- | --- | --- |
| Uber Eats | `POST /api/delivery/ubereats/webhook` | `X-Uber-Signature`＝HMAC-SHA256(原始 body, client secret 或 webhook signing key) 的小寫十六進位；`event_id` 去重；回 200 空白 |
| Uber Eats | `GET /api/delivery/ubereats/oauth/callback` | 店家授權（`eats.pos_provisioning`）之後選要連的店 |
| foodpanda | `POST /api/delivery/foodpanda/order/{remoteId}` | `Authorization: Bearer <JWT HS512, service=middleware>`（plugin secret）；`token` 去重；回 `{remoteResponse:{remoteOrderId}}` |
| foodpanda | `PUT /api/delivery/foodpanda/remoteId/{remoteId}/remoteOrder/{remoteOrderId}/posOrderStatus` | 同上；`ORDER_CANCELLED`、`ORDER_PICKED_UP` |

foodpanda 的路徑整個交給連接器分（`/api/delivery/foodpanda/[...path]`，POST／PUT／GET），之後多的 plugin 端點不用改路由。
`remoteOrderId`＝我們的 `ticketId`：之後的狀態通知帶這個，後台先當平台的 orderId 找、找不到再當 ticketId 找。

收到的每一筆原樣記在 `pos_delivery_inbound`（除錯、對帳、平台說「我們有送」時查得到）：body 最多 64 KB（驗簽沒過的只留 2 KB）、
標頭只留安全的（`Authorization` 只記有沒有帶）、回了什麼（`ok`／`duplicate`／`bad_signature`／`ignored`／`error`）。

處理順序：記下來 → 驗簽（不對 `401`，不解析）→ 解析 → 去重（連接器給的 key；重送的照第一次的結果回，foodpanda 一樣拿到我們的單 id）→
新單：Uber 只給 id 要取完整訂單（取不到排進佇列重試、先回 200）→ 對菜單 → 在**同一個交易**寫 `pos_delivery_orders` 與事件 → 回平台。
自動接單、通知平台出餐這種慢的放在回應之後（Next 的 `after()`），平台幾秒內就拿到回應。沒做完（資料庫錯）回 5xx 並放掉去重的 key，平台重送時照樣做。
店沒在後台開 → `404 unknown_store`。

**Uber 的預約單**會來兩次新單通知（預約時、到時間時），兩次都要接：第二次來時這張單 POS 已經接了 → 後台自動用同樣的備餐時間再接一次（不寫事件）。
外送員的通知（`delivery.state_changed`、`orders.release`）帶 `status: accepted` 當下限：後台的狀態只往前（ready 不會被改回 accepted），外送員的資訊照樣更新；
我們還是 pending 時收到平台說 accepted（平台的平板上接的）＝照後台接單一樣：送廚房、指定負責結帳的那台。

## 後台：「外送平台」虛擬裝置

平台的單由後台的一台虛擬裝置寫成事件，iPad 照常從 `GET /events` 拉到：`pos_devices` 一筆，名稱「外送平台」、`role`＝`integration`、`code`＝`DLV`
（真的 iPad 是 A–Z 一個字母，撞不到）、沒有 token（`token_hash` 不是十六進位，任何 token 都對不上）。
寫事件時在交易裡鎖事件流（和 `POST /events` 同一把鎖）與這台裝置那一筆：`seq`＝最後一筆＋1、`prevHash`＝最後一筆的 hash（第一筆 64 個 0）、
`lamport`＝目前所有事件最大的＋1、`at`＝現在，雜湊照 API.md 的規則算，然後走和 `POST /events` **同一段程式**收（驗雜湊、接鏈、投影）。
沒有 `staffId`。後台「裝置」頁、在線台數、收銀機台數、看門狗都不算它，也不能從後台改或移除。iPad 不用特別處理這台（`openedBy` 是空字串）。

## 後台：自動接單與看門狗

- **自動接單**（店的設定）：收單的回應送出之後後台就接。備餐時間＝基本＋忙碌加的＋廚房的量（`PrepTimeAdvisor` 同一套：每 3 份加 1 分、最多加 30、5–120 分；
  後台只算「接了還沒做好的外送單」的份數＋這張的份數）。寫 `delivery.updated(accepted, readyAt, prepMinutes, acceptedBy)`＋`lines.sent(relayPrint: new)`。
  失敗（可以重試的）排進佇列再試。
- **看門狗**（`/api/cron/pos-delivery-watchdog`，每分鐘；沒開任何平台什麼都不做）：
  1. **3 分鐘內沒有任何一台真的 iPad 連上後台**（任何 API 請求都算，心跳每分鐘一次）→ 每一家開著、接單中的店暫停（`pausedBy: watchdog`，不給時間）；
     有一台連回來 → 只恢復看門狗暫停的（店裡自己按的暫停不動）
  2. 店裡按的「暫停到幾點」到了 → 恢復（有 iPad 在線時）；忙碌的時間到了 → 取消
  3. 待接的單離期限不到 **75 秒**（排程每分鐘跑，留一點餘裕），而且那家店開了「快到期限替你接」（`auto_accept_fallback`，預設開）或自動接單 → 後台接（同上）
  4. 期限過了 15 分鐘還是待接（平台沒通知取消）→ 當作平台取消（`delivery.updated(cancelled, "逾時沒有接單")`＋作廢），收件匣不會一直掛著
  5. 自動連線檢查（見下面「開通」；連不上平台的店 1. 不去暫停）

## 後台：設定（`/admin/pos/delivery`）與開通（全自動，不用 StudioX 的人）

每個平台一家店：平台上的店 id（Uber store_id、foodpanda vendor code）、店名、開關、**測試模式**（單從模擬器來、什麼都不送到平台）、自動接單、
快到期限替你接、備餐時間、抽成率（平台沒給抽成時估實收）、平台價加成（推菜單時）。另有：測試連線、推菜單、要貼到平台的網址（沒接 StudioX 的網站才要）、
最近的單與平台打進來的紀錄。

**帳密分兩層**：

| 層 | 是什麼 | 存在哪 |
| --- | --- | --- |
| 串接商（StudioX） | Uber Eats app 的 client id／secret、webhook signing key；foodpanda plugin 的 middleware 帳密、plugin secret、baseUrl、市場代碼——所有店共用 | 接了 StudioX 的網站：console 的服務設定（`platformConfig().services.delivery.credentials`，key 是「平台.欄位」：`ubereats.clientId`、`foodpanda.pluginSecret`…；`settings` 的 `ubereats.sandbox`＝`true` 是測試環境）。店家看不到、不用填。沒接的網站：自己在設定頁填 |
| 店 | 店在平台上的 id（`pos_delivery_stores`）、foodpanda 的 `chainCode`；Uber 授權時的 token 只放 Redis 30 分鐘 | 網站自己的 `integrations`（`pos_delivery`），secret 的 sealed、只能寫 |

合起來：串接商的欄位 console 有就用 console 的（沒有才用網站存的）；店自己的欄位網站存的優先。StudioX 關掉（或客戶暫停）外送＝串接商的帳密都沒有（平台連不上）。
console 還沒有外送這項服務時照舊全部用網站自己存的。

**開通**（店家自己做完，沒有人工步驟）：
- **Uber Eats**：負責人按「連結 Uber Eats」→ Uber 登入、同意（`eats.pos_provisioning`）→ 回到設定頁選店 → 後台告訴 Uber 這家由我們接單（`pos_data`）
  → 存成開著的店 → **馬上自動檢查連線** → 連上了就是接單中。
- **foodpanda**：填 vendor code（我們也用它當 `remoteId`）、打開、儲存 → 自動檢查連線 → foodpanda（Delivery Hero）那邊還沒開通＝`waiting_platform`
  （不是錯誤），看門狗每 5 分鐘重試，開通了就自己變成接單中。

**自動連線檢查**（`src/lib/delivery/health.ts`）：開店時馬上一次；之後看門狗每分鐘看誰該檢查——正常的 15 分鐘一次、其他 5 分鐘一次。
檢查＝連接器的 `testConnection`（換 token：快取的 token 失效時連接器自己重換；讀店家狀態）。Uber 404／403＝`needs_reauth`（店的授權沒了：設定頁出現
「重新連結 Uber Eats」）、foodpanda 404／403＝`waiting_platform`、網路與 5xx 這種暫時的連續 3 次才算 `error`；要人處理的（`needs_reauth`、`error`）才記在
`lastError`，好了自動清掉。Uber 的 `store.deprovisioned` webhook＝`needs_reauth`（店不關掉，重新連結就回來）；`store.provisioned`＝馬上重新檢查。

## 後台：連接器（`src/lib/delivery/connectors/*`）

每個平台一個，介面一樣（`DeliveryConnector`，見 `src/lib/delivery/connector.ts`）：驗簽、把平台的格式換成 `NormalizedOrder`、
取訂單、接單／拒單／出餐好了／取消、店家暫停／恢復、品項賣完／恢復、推菜單。另有 `simulator`：不連任何平台，測試與示範用。

往平台的呼叫排隊重試用 BullMQ 的 `pos-delivery` 佇列（和電子發票上傳同一套：worker 從 `/api/internal/queue-tick` 啟動；
指數退避 30 秒起、最多 8 次；平台說內容錯〔4xx〕就不再試；每次失敗記在那家店的 `lastError`）。工作：`availability`（店裡按賣完／恢復 → 每一家開著、
不是測試模式的店）、`store-status`（暫停／恢復沒送到的，照資料表現在的狀態再送）、`ready`、`menu-push`、`order`（取不到的完整訂單）、
`accept`（自動接單的重試）、`reaccept`（Uber 預約單再接一次的重試）。接單、拒單、取消這種有時限的直接呼叫，失敗回 502、不排隊（讓人決定）。

推菜單：POS 的菜單（只推一般的餐點；時價、課程卡、儲值、服務不推）、品項 id＝POS 的 id、價錢與選項加價乘上加成後四捨五入到整數元、今天賣完的標 `available: false`。
對單：平台的 id（或連接器對好的 `posItemId`）就是 POS 的品項 id → 對到；不然照名稱（含短名，不分全半形、大小寫；同名兩個以上不猜）；都不行 → `itemId` 空字串。
選項先對 id、再在對到的品項的選項群組裡對名稱；對不到的 `groupId`、`optionId` 是空字串（或平台的 id），加價照平台。

## 上線前（StudioX 做一次，之後每家店自己開通）

- **Uber Eats**：Uber 核准 StudioX 成為串接夥伴（簽 NDA、API 授權、Uber 一起測試）才有正式的 client id/secret，設定在 console 的外送服務；
  店家在 POS 後台按「連結 Uber Eats」登入授權、選店（見上面「開通」）。
- **foodpanda**：StudioX 是 Delivery Hero 的 POS 串接夥伴（plugin secret、middleware 帳號在 console）；店家填 vendor code，DH 那邊開通後自動接單。
  台灣 foodpanda 可能被 Grab 收購（公平會 2026-10-27 前決定），連接器可以換。
- 兩個平台：餐點的發票是店家開（平台只開外送費、服務費的發票）；外送單結帳時照店裡的發票設定開。
