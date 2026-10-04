# StudioX POS

StudioX 的門市收銀（iPad）。和網站、StudioX Console、StudioX App 用**同一份**菜單、會員、報表：
門市的每一筆銷售回到店家自己的後台（atelier-cms 的「門市 POS」服務插件），再到 console 與 App。

- **資料在後台，iPad 只為了快**：每個動作先寫進 iPad 上的事件日誌（fsync）才印單、開錢櫃，斷網照常營業、連上自動補送；
  送到後台之後，iPad 只留最近兩天、還開著的單與還沒交班的班（開機快、報表與退款最常用的都在手邊）。
  更早的資料、會員的儲值金與課程卡、報表都以後台為準。同一個 Wi-Fi 的 iPad 互相直接同步
- **右側固定鍵盤**：整個 App 只有一個數字鍵盤，永遠在最右邊、一樣大、鍵位不變——數量、收現金、PIN、統編（當場驗檢查碼）、
  電話、愛心碼、點錢、配對碼都在這裡打。沒人要數字時，它是「數量／品號」：先打 3 再點珍奶＝3 杯
- **電子發票**：B2C（紙本證明聯、手機條碼、自然人憑證、捐贈）與 B2B（統編，格式 25）；每台 iPad 有自己的號碼段，斷網也能開；
  證明聯照財政部格式印（Code 39＋兩個 QR Code，左邊 QR 的 AES 驗證碼）；同一期整張退＝作廢、其他＝折讓單；後台 48 小時內上傳
- **營業模式**：同一套 POS 給不同的店、不同的時段用，每台 iPad 在側欄最上面切換（後台決定開哪幾種、預設哪一種）

  | 模式 | 流程 |
  |---|---|
  | 餐廳桌邊 | 帶位 → 點餐 → 送廚房 → 吃完再結帳；一登入先看桌況 |
  | 櫃台點餐（飲料、快餐） | 點完先結帳 → 廚房單與印大大取餐號碼的收據 → 出餐叫號；預設外帶 |
  | 零售攤位 | 掃條碼或點品項 → 結帳；沒有桌位、不出廚房單 |
  | 咖啡甜點 | 內用外帶都有、先結帳；內用可以帶位 |
  | 服飾零售（衣服、鞋包、選物） | 點款式選顏色 × 尺寸（或掃吊牌）、每個規格自己的庫存（可連網路商店同一份）、同款換尺寸、換別的補差價、業績算給店員 |
  | 美業預約（髮廊、美甲、美容、寵物美容） | 照設計師排預約 → 到店開單（服務帶指定的人）→ 做完結帳；儲值金、療程卡（次數）、助理、抽成、客人的配方備註 |
  | 會員課程（健身房、瑜珈、舞蹈、才藝教室） | 掃會員或打電話入場報到（月卡不扣次、次數卡扣一次）、會籍續約接在到期日後、團體課課表與名額、私人教練預約 |
- **崗位**：同一家店的每台 iPad 放在不同位置，看同一份資料、做不同的事（後台配對時決定，店長可以在 iPad 上換）

  | 崗位 | 做什麼 |
  |---|---|
  | 結帳櫃台 | 全部：收錢、開發票、錢櫃、交班、報表 |
  | 前場點餐 | 桌邊點餐、帶位、送廚房；刷卡、電子支付可以，不收現金 |
  | 報到接待 | 帶位候位、預約表、會員報到、開服務單（結帳交給櫃台） |
  | 後廚 | 依出單站看單、按製作中／可出餐 |
  | 出餐口 | 所有出單站的進度、出餐叫號 |
- **會員帳戶**：儲值金（儲值時開發票或消費時開，店家選）、課程卡（次數）、會籍（期間），和網路商店同一份會員；斷網也算得對
- **桌位**：多樓層、拖拉排桌、帶位、換桌、併桌、拆單、用餐時間、待清桌；訂位與候位（簡訊叫號）
- **廚房**：依出單站列印、廚房螢幕（KDS）、催菜（第 2、3 道）
- **錢櫃與交班**：零用金、存入／取出、只開錢櫃、X 帳、交班點錢（每種面額在右側鍵盤打）、Z 帳、短溢收；打卡
- **權限**：收銀／領班／店長／負責人；不夠的時候請主管在右側鍵盤打 PIN 授權（作廢已出單、退款、大額折扣、換崗位…）
- **業績與抽成**：每一行算給誰（設計師、教練，或整張單的店員）、助理、課程卡抵用照每次的價值算業績

## 開啟

Xcode 26 以上、目標 iPadOS 26。

```bash
open StudioXPOS.xcodeproj
```

專案用 Xcode 的「同步資料夾」：`StudioXPOS/` 底下新增的檔案自動加進專案。核心邏輯在本機的 Swift 套件 `Packages/POSKit`。

**先看示範**：配對畫面按「先看看示範」選一家虛構的店（或啟動參數 `-demo cafe|apparel|salon|fitness`），今天的單、昨天與前 90 天的歷史都準備好了：

| 示範店 | 看什麼 |
|---|---|
| 餐廳咖啡「晨麥手作」 | 三個區域的桌位、正在吃的桌子、廚房出單、訂位與候位、櫃台取餐號碼 |
| 服飾「Lumi 選物」 | 顏色 × 尺寸、吊牌條碼、低庫存與賣完、店員業績、換貨 |
| 美業「Mori Hair」 | 設計師的預約表、到店開單、儲值金與剪髮卡、助理與抽成、客人的配方備註 |
| 健身「Pulse 健身」 | 入場報到（月卡、次數卡、過期的）、團體課名單與名額、私人教練、壽星 |

PIN（四家都一樣）：Leslie 1234（店長）、Cameron 2580（收銀）、Jacob 1111（領班）、王小美 0000（負責人）；
美業多了 Mia 5678（設計師），健身多了 Kevin 5678、Ivy 2468（教練）。截圖與自動測試另外有 `-autologin <PIN>`、`-section <頁>`（只在 Debug）。

### 測試與建置

| | |
|---|---|
| `cd Packages/POSKit && swift test` | 核心邏輯的測試（Linux、macOS 都能跑；GitHub Actions 的 `poskit.yml` 每次推上來跑） |
| `.github/workflows/ios.yml` | 每次推上來在 GitHub 的 Mac 上編一次 App（模擬器、不簽章），錯誤列在 Actions 的摘要 |

## TestFlight

推到 `claude/pos-foundation` 或 `main`（App 的檔案有改）就自動出一版 TestFlight（`.github/workflows/testflight.yml`）：
GitHub 的 Mac 用 App Store Connect API 金鑰自己簽章（這一次專用的憑證與描述檔，用完就撤銷）、封存、上傳，
等 Apple 處理好後把最近的提交寫成「測試內容」、交給內部測試群組「StudioX 團隊」並寄邀請。和 StudioX Console App 同一套，**可以用同一把金鑰**。

**第一次設定**（只有這幾步要在網頁上做）：
1. GitHub 這個 repo → Settings → Secrets and variables → Actions → New repository secret，新增四個（和 StudioX Console App 的一樣）：
   `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`（`.p8` 整段）、`APPLE_TEAM_ID`；要邀請別人再加 `TESTFLIGHT_TESTERS`（逗號隔開的 `姓名 <email>`）
2. Actions → TestFlight → Run workflow 跑一次：它會註冊 App ID `tw.studiox.pos`，然後停下來說「App Store Connect 上還沒有這個 App」
3. App Store Connect → App →「＋」新增 App：平台 iOS、名稱 **StudioX POS**、主要語言 繁體中文、套件 ID 選 `tw.studiox.pos`、SKU `studiox-pos`
   （Apple 不讓 API 建 App，這一步只能在網頁上做）
4. 回 Actions 重跑。之後每次推上來，十幾分鐘後 iPad 上的 TestFlight 就有新版

- 版號用 UTC 時間（`2610041530`＝26/10/04 15:30），版本改 `MARKETING_VERSION`
- Secrets 還沒設定時整個流程跳過，不會失敗；這個 repo 是公開的，Mac 的分鐘數不另外計費
- TestFlight 版一樣有「先看看示範」（四家示範店），不用後台也能試
- 上架需要的已經準備好：`ITSAppUsesNonExemptEncryption = NO`、隱私清單 `StudioXPOS/PrivacyInfo.xcprivacy`、沒有透明度的 App 圖示

## 和後台配對

1. 店家的後台（atelier-cms，開了 `pos` 模組；接 StudioX 的店家由 StudioX 在 console 開通「門市 POS」服務）
   →「門市 POS → 裝置」→ 新增裝置，選崗位：**結帳櫃台**（有錢櫃、出單機）、**前場點餐**、**報到接待**、**後廚**、**出餐口**
   （之後店長可以在 iPad 的「設定 → 崗位」換）
2. iPad 上在右側鍵盤打畫面上的 8 位數配對碼（10 分鐘內有效），或用相機掃 QR Code（`studiox-pos://pair?cms=…&code=…`）
   - 接 StudioX 的店家不用打網址：console 的 `/api/pos/resolve` 知道配對碼是哪一家
   - 自己架後台的店家：配對畫面「進階」填後台網址
3. 店員用自己的 PIN 登入（PIN 在後台「門市 POS → 人員」設定）

token 存在 Keychain（這台裝置、不跟著備份走）；後台移除這台時，App 會清掉本機資料回到配對畫面。

## 出單機（58／80 mm、網路與藍牙）

設定 → 出單機，每一台各自設定：

| | |
|---|---|
| 連線 | **網路**（Wi-Fi／網路線：Epson TM-m30、Star mC-Print 的 ESC/POS 模式、台灣常見的熱感機，埠 9100）或 **藍牙 BLE**（小型 58／80 mm 熱感機：在 App 裡搜尋附近的機器、點一下配對） |
| 紙寬 | **58 mm**（一行 32 個半形字、384 點）或 **80 mm**（48 個字、576 點）；收據、結帳單、廚房單、交班單照紙寬排版 |
| 印什麼 | 收據、電子發票證明聯、廚房出單（可以只印某幾站：吧台、廚房） |
| 中文 | Big5（台灣的機器多半是這個）、UTF-8、或整張畫成圖（不挑機器的字型，最慢） |
| 錢櫃 | 接在這台（收現金、退現金、交班時自動開） |

- **電子發票證明聯一律 5.7 公分寬**（法規），畫成點陣圖：兩個 QR Code 左右並排。建議一台 58 mm 專印證明聯、一台 80 mm 印收據與廚房單；
  只有一台 80 mm 時，證明聯照 5.7 公分寬置中印
- 藍牙只支援 BLE：傳統藍牙（SPP）的機器 iPad 不能直接連（要 Apple 的 MFi 認證），買機器時請選「支援 BLE」的
- 沒有設定出單機時，印的東西在「設定 → 最近列印」看得到（示範模式也是）

## 架構

詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，iPad 與後台之間的格式見 [docs/API.md](docs/API.md)。

```
Packages/POSKit/          核心（只用 Foundation，Linux 也能測）
  POSCore/                金額與 5% 含稅、菜單（種類、規格）、桌位、人員與權限、單子與金額算法、付款、交班、報表（含業績）、
                          會員帳戶（儲值金、課程卡、會籍：從事件推出來，和後台同一套規則）、報到、換貨、
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
  Services/               出單機（網路 TCP 9100、藍牙 BLE、Big5、證明聯點陣圖）、區網同步（Bonjour、AES-GCM）、Keychain
  Pairing/ Lock/          配對、PIN 登入與打卡
  Order/ Payment/         點餐（分類、品項、加料）、單子、結帳（付款、發票、會員）
  Floor/ Reservations/    桌位圖、訂位與候位
  Appointments/ CheckIn/  預約表（設計師、教練）、入場報到與團體課
  Members/                會員：儲值金、課程卡、消費紀錄、備註
  Kitchen/                廚房螢幕（後廚、出餐口）
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
