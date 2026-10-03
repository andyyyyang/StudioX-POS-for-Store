# StudioX POS

StudioX 的門市收銀（iPad）。和網站、StudioX Console、StudioX App 用**同一份**菜單、會員、報表：
門市的每一筆銷售回到店家自己的後台（atelier-cms 的「門市 POS」服務插件），再到 console 與 App。

- **斷網照常營業**：每個動作先寫進 iPad 上的事件日誌（fsync）才印單、開錢櫃；連上網路自動補送。
  同一個 Wi-Fi 的 iPad 互相直接同步（櫃台看得到手持機點的單、廚房照樣出單）
- **右側固定鍵盤**：整個 App 只有一個數字鍵盤，永遠在最右邊、一樣大、鍵位不變——數量、收現金、PIN、統編（當場驗檢查碼）、
  電話、愛心碼、點錢、配對碼都在這裡打。沒人要數字時，它是「數量／品號」：先打 3 再點珍奶＝3 杯
- **電子發票**：B2C（紙本證明聯、手機條碼、自然人憑證、捐贈）與 B2B（統編，格式 25）；每台 iPad 有自己的號碼段，斷網也能開；
  證明聯照財政部格式印（Code 39＋兩個 QR Code，左邊 QR 的 AES 驗證碼）；同一期整張退＝作廢、其他＝折讓單；後台 48 小時內上傳
- **桌位**：多樓層、拖拉排桌、帶位、換桌、併桌、拆單、用餐時間、待清桌；訂位與候位（簡訊叫號）
- **廚房**：依出單站列印、廚房螢幕（KDS）、催菜（第 2、3 道）
- **錢櫃與交班**：零用金、存入／取出、只開錢櫃、X 帳、交班點錢（每種面額在右側鍵盤打）、Z 帳、短溢收；打卡
- **權限**：收銀／領班／店長／負責人；不夠的時候請主管在右側鍵盤打 PIN 授權（作廢已出單、退款、大額折扣…）

## 開啟

Xcode 26 以上、目標 iPadOS 26。

```bash
open StudioXPOS.xcodeproj
```

專案用 Xcode 的「同步資料夾」：`StudioXPOS/` 底下新增的檔案自動加進專案。核心邏輯在本機的 Swift 套件 `Packages/POSKit`。

**先看示範**：配對畫面按「先看看示範」（或啟動參數 `-demo`）：虛構的「晨麥手作」，菜單、三個區域的桌位、今天的十幾張單、
正在吃的桌子、訂位與候位都準備好了。PIN：Leslie 1234（店長）、Cameron 2580（收銀）、Jacob 1111（領班）、王小美 0000（負責人）。

### 測試與建置

| | |
|---|---|
| `cd Packages/POSKit && swift test` | 核心邏輯的測試（Linux、macOS 都能跑；GitHub Actions 的 `poskit.yml` 每次推上來跑） |
| `.github/workflows/ios.yml` | 每次推上來在 GitHub 的 Mac 上編一次 App（模擬器、不簽章），錯誤列在 Actions 的摘要 |

## 和後台配對

1. 店家的後台（atelier-cms，開了 `pos` 模組；接 StudioX 的店家由 StudioX 在 console 開通「門市 POS」服務）
   →「門市 POS → 裝置」→ 新增裝置，選用途：**收銀機**（有錢櫃、出單機）、**點餐機**（桌邊點餐）、**廚房螢幕**
2. iPad 上在右側鍵盤打畫面上的 8 位數配對碼（10 分鐘內有效），或用相機掃 QR Code（`studiox-pos://pair?cms=…&code=…`）
   - 接 StudioX 的店家不用打網址：console 的 `/api/pos/resolve` 知道配對碼是哪一家
   - 自己架後台的店家：配對畫面「進階」填後台網址
3. 店員用自己的 PIN 登入（PIN 在後台「門市 POS → 人員」設定）

token 存在 Keychain（這台裝置、不跟著備份走）；後台移除這台時，App 會清掉本機資料回到配對畫面。

## 出單機

設定 → 出單機：網路出單機（Epson TM-m30、Star mC-Print 的 ESC/POS 模式、台灣常見的 58／80 mm 熱感機，埠 9100）。
每台可以設定印什麼（收據、發票證明聯、廚房出單＋哪幾站）、中文編碼（Big5／UTF-8／整張畫成圖）、錢櫃接在哪一台。
證明聯一律畫成點陣圖（5.7 公分寬、兩個 QR Code 左右並排）。沒有設定出單機時，印的東西在「設定 → 最近列印」看得到。

## 架構

詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，iPad 與後台之間的格式見 [docs/API.md](docs/API.md)。

```
Packages/POSKit/          核心（只用 Foundation，Linux 也能測）
  POSCore/                金額與 5% 含稅、菜單、桌位、人員與權限、單子與金額算法、付款、交班、報表、
                          事件（雜湊鏈、Lamport 時鐘）與狀態（StoreState：同一串事件每台算出一樣的結果）、
                          右側鍵盤的輸入規則、加密（SHA-256、HMAC、PBKDF2、AES-128，純 Swift）
  POSInvoice/             發票期別、號碼段、開立（B2C／B2B）、折讓、證明聯的一維與二維條碼
  POSPrinting/            ESC/POS、點陣圖、中文寬度排版；收據、結帳單、廚房單、交班單
  POSSync/                本機事件日誌、和後台同步、區網同步的訊息格式、API 的資料格式
StudioXPOS/               iPad App（SwiftUI，Swift 6、預設 @MainActor、@Observable，沒有第三方套件）
  App/                    進入點、開機／配對／鎖定／收銀台的切換、畫面下方的提示
  Shell/                  四欄：側欄｜工作區｜單子｜右側固定鍵盤；外接鍵盤與條碼掃描器
  Keypad/                 右側固定鍵盤（KeypadController：誰要數字、KeypadDock：畫面）
  Model/                  POSModel（設定、事件、同步、目前的人與頁面）＋點餐、結帳、交班、訂位的動作
  Services/               出單機（ESC/POS over TCP、Big5、證明聯點陣圖）、區網同步（Bonjour、AES-GCM）、Keychain
  Pairing/ Lock/          配對、PIN 登入與打卡
  Order/ Payment/         點餐（分類、品項、加料）、單子、結帳（付款、發票、會員）
  Floor/ Reservations/    桌位圖、訂位與候位
  Kitchen/                廚房螢幕
  Orders/ Dashboard/      訂單（進行中、已結帳、退款、補印、改統編）、報表
  Shift/ Settings/        錢櫃與交班、設定
  Brand/ Components/      顏色、字、動態、元件（和 StudioX Console App 同一套）
  Demo/                   示範模式（晨麥手作）
docs/                     架構、API、範例 JSON（由測試產生）
```

## 還沒做（要合約或硬體才能完成）

- **刷卡／感應支付直接連線**：現在是「外接刷卡機＋輸入末四碼」與「電子支付輸入交易序號」。要串 Tap to Pay on iPhone（ProximityReader）
  或 LINE Pay／街口的反掃 API，需要收單機構的合約與金鑰
- **電子發票上傳的加值中心 API**：後台已經產生 MIG 4.1 的 XML（F0401／F0501／G0401／E0402）並排進上傳佇列（Turnkey 模式）；
  接特定加值中心要等合約與測試環境的金鑰
- 客顯（第二螢幕給客人看金額）、外送平台（Uber Eats、foodpanda）接單
