# 虛擬出單機（ESC/POS）

沒有實體出單機時，確認 POS 印出來的樣子：收到的 ESC/POS 指令畫成圖片（58 mm＝384 點、80 mm＝576 點）。

照台灣常見的熱感出單機排：英數 12×24 點，其他每一個字（中文、全形標點、×、…、·）都是雙位元組、24×24 點。
看得懂：文字（Big5／UTF-8、粗體、放大、反白、底線、對齊）、走紙、切紙（換一張圖）、點陣圖（GS v 0）、
QR Code（GS ( k）、Code 39（GS k）、開錢櫃（ESC p）、嗶聲（BEL）。不認得的指令會記在紀錄裡。

```sh
pip install pillow qrcode
# 當成網路出單機：每一次連線＝一張單（.bin 原始指令、.png 印出來的樣子、.json 摘要）
python3 escpos_emulator.py serve --port 9100 --paper 58 --encoding big5hkscs --out prints/58
# 收 UTF-8、照 Big5 出單機印（Big5 沒有的字印成「?」）：檢查有沒有出單機印不出來的字
python3 escpos_emulator.py serve --port 9100 --paper 58 --encoding utf-8 --big5-check --out prints/58
# 把存下來的指令畫出來
python3 escpos_emulator.py render job.bin --paper 80 --encoding big5hkscs -o job.png
```

- POSKit 的範本：`POSKIT_WRITE_PRINTS=<資料夾> swift test --filter PrintSamples`（Packages/POSKit）產生 58／80 的收據、廚房單、結帳單、
  號碼牌、證明聯（文字版）、點陣圖，再用 `render` 或送到 `serve` 看。
- App 實測：截圖的 CI（`.github/workflows/ui-screenshots.yml` 的「列印實測」）開三台虛擬出單機，模擬器裡的 POS 帶
  `-printerLab 127.0.0.1`（`StudioXPOS/App/PrinterLab.swift`）從網路印一輪，結果在 `docs/print-samples/`。
- 藍牙出單機模擬不了；第一次接實機時印一張設定頁的「測試列印」確認。
