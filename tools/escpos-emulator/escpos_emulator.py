#!/usr/bin/env python3
"""虛擬的 ESC/POS 出單機：把收到的指令「印」成圖片（58 mm＝384 點、80 mm＝576 點）。

沒有實體出單機時用來確認 POS 印出來的樣子：文字模式（Big5／UTF-8、粗體、放大、反白、對齊、走紙、切紙）、
點陣圖（GS v 0：號碼牌、證明聯）、QR Code（GS ( k）、Code 39（GS k）、開錢櫃（ESC p，記在旁邊）。

  # 當成網路出單機（9100 埠）：每一次連線＝一張單，切紙＝換一張圖
  python3 escpos_emulator.py serve --port 9100 --paper 58 --out prints/58
  # 把存下來的位元組畫出來
  python3 escpos_emulator.py render job.bin --paper 80 --encoding big5 -o job.png

需要 Pillow；QR Code 要 qrcode 套件（沒有的話畫一個框代替）。中文字型自己找系統裡的（macOS 的蘋方、Linux 的文泉驛／Noto CJK）。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time
from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFont

try:
    import qrcode  # type: ignore
except ImportError:  # pragma: no cover
    qrcode = None

# 依序試；.ttc 裡每一個字型都試。要有繁體字（台灣的單子）：簡體字型（Songti SC、Hiragino Sans GB、STHeiti）
# 常常沒有「麥、號、廚、稅、聯」這些繁體才有的字，畫出來是空白——先挑繁體的，再用 FONT_PROBE 確認真的有字
FONT_CANDIDATES = [
    "/System/Library/Fonts/Hiragino Sans CNS.ttc",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]
# 繁體才有的字（簡體字型沒有）＋常用的：都畫得出來才用這個字型
FONT_PROBE = "麥號廚稅聯發單細帶計區晨"

# Font A：英數 12×24 點，中文 24×24 點（台灣常見的 58／80 mm 熱感機都是這個大小）
CELL_W, CELL_H = 12, 24
LINE_GAP = 6  # ESC 2 的預設行距 30 點＝24＋6


_FONT_CHOICE: tuple[str, int] | None = None


def _glyph(font: ImageFont.FreeTypeFont, ch: str) -> Image.Image:
    img = Image.new("L", (40, 40), 0)
    ImageDraw.Draw(img).text((4, 4), ch, font=font, fill=255)
    return img


def _has_glyphs(font: ImageFont.FreeTypeFont, text: str) -> bool:
    """每個字都有自己的字形（不是缺字時的空白或 .notdef 方塊）"""
    missing = _glyph(font, "\U0010FFFD").tobytes()
    for ch in text:
        g = _glyph(font, ch)
        if g.getbbox() is None or g.tobytes() == missing:
            return False
    return True


def pick_font() -> tuple[str, int] | None:
    """第一個繁體字都畫得出來的字型（路徑、.ttc 裡的第幾個）；記住，之後都用它"""
    global _FONT_CHOICE
    if _FONT_CHOICE is not None:
        return _FONT_CHOICE
    for path in FONT_CANDIDATES:
        if not os.path.exists(path):
            continue
        for index in range(0, 16 if path.endswith(".ttc") else 1):
            try:
                f = ImageFont.truetype(path, 24, index=index)
            except OSError:
                break
            if _has_glyphs(f, FONT_PROBE):
                _FONT_CHOICE = (path, index)
                print(f"字型：{os.path.basename(path)} #{index}", file=sys.stderr)
                return _FONT_CHOICE
    print("找不到有繁體字的字型：缺的字會是空白", file=sys.stderr)
    return None


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    choice = pick_font()
    if choice:
        return ImageFont.truetype(choice[0], size, index=choice[1])
    return ImageFont.load_default()


def is_wide(ch: str) -> bool:
    """台灣出單機（Big5，或 UTF-8 但用 Big5／GB 的 24×24 字型）：英數 12 點，其他每個字都是雙位元組、24 點"""
    o = ord(ch)
    if o < 0x80:
        return False
    return not (0xFF61 <= o <= 0xFFDC or 0xFFE8 <= o <= 0xFFEE)


@dataclass
class Style:
    align: int = 0  # 0 左、1 中、2 右
    bold: bool = False
    width: int = 1
    height: int = 1
    invert: bool = False
    underline: bool = False


@dataclass
class Page:
    """一張紙：一段一段往下畫（文字列、點陣圖、條碼）"""
    width: int
    items: list = field(default_factory=list)  # (kind, payload)
    events: list = field(default_factory=list)  # 開錢櫃、嗶聲…

    def add(self, kind: str, payload) -> None:
        self.items.append((kind, payload))


class Printer:
    def __init__(self, width: int, encoding: str = "big5", big5_check: bool = False) -> None:
        self.width = width
        self.encoding = encoding
        # 收到的是 UTF-8，但照 Big5 出單機印：Big5 沒有的字印成「?」（iPad 用 Big5 送出去時就是這樣）
        self.big5_check = big5_check
        self.missing: dict[str, int] = {}
        self.pages: list[Page] = []
        self.page = Page(width)
        self.style = Style()
        self.line: list[tuple[str, Style]] = []
        self.text_buf = bytearray()
        self.qr_data = b""
        self.qr_module = 3
        self.barcode_height = 162
        self.barcode_module = 3
        self.unknown: dict[str, int] = {}

    # --- 文字 ---
    def flush_text(self) -> None:
        if not self.text_buf:
            return
        try:
            s = bytes(self.text_buf).decode(self.encoding)
        except UnicodeDecodeError:
            s = bytes(self.text_buf).decode(self.encoding, errors="replace")
        st = Style(**self.style.__dict__)
        for ch in s:
            if self.big5_check and ord(ch) >= 0x80:
                try:
                    ch.encode("big5hkscs")
                except UnicodeEncodeError:
                    self.missing[ch] = self.missing.get(ch, 0) + 1
                    ch = "?"
            self.line.append((ch, st))
        self.text_buf.clear()

    def newline(self) -> None:
        self.flush_text()
        self.page.add("text", (list(self.line), self.style.align))
        self.line = []

    def finish_page(self, cut: bool) -> None:
        self.flush_text()
        if self.line:
            self.newline()
        if self.page.items or self.page.events:
            self.page.events.append("切紙" if cut else "（沒有切紙）")
            self.pages.append(self.page)
        self.page = Page(self.width)

    def note(self, name: str) -> None:
        self.unknown[name] = self.unknown.get(name, 0) + 1

    # --- 解指令 ---
    def feed(self, data: bytes) -> None:  # noqa: C901（指令表本來就長）
        i, n = 0, len(data)

        def need(k: int) -> bool:
            return i + k <= n

        while i < n:
            b = data[i]
            if b == 0x0A:  # LF
                self.newline(); i += 1; continue
            if b == 0x0D:  # CR
                i += 1; continue
            if b == 0x07:  # BEL
                self.flush_text(); self.page.events.append("嗶"); i += 1; continue
            if b == 0x1B and need(2):  # ESC
                c = data[i + 1]
                if c == 0x40:  # ESC @
                    self.flush_text(); self.style = Style(); i += 2; continue
                if c == 0x61 and need(3):  # ESC a
                    self.flush_text(); self.style.align = data[i + 2] % 48 if data[i + 2] >= 48 else data[i + 2]; i += 3; continue
                if c == 0x45 and need(3):  # ESC E
                    self.flush_text(); self.style.bold = bool(data[i + 2] & 1); i += 3; continue
                if c == 0x2D and need(3):  # ESC -
                    self.flush_text(); self.style.underline = bool(data[i + 2] & 3); i += 3; continue
                if c == 0x64 and need(3):  # ESC d n
                    self.flush_text()
                    if self.line:
                        self.newline()
                    self.page.add("feed", data[i + 2]); i += 3; continue
                if c == 0x70 and need(5):  # ESC p
                    self.flush_text(); self.page.events.append("開錢櫃"); i += 5; continue
                if c in (0x32,):  # ESC 2
                    i += 2; continue
                if c == 0x33 and need(3):  # ESC 3 n
                    i += 3; continue
                if c == 0x21 and need(3):  # ESC ! n
                    self.flush_text(); n_ = data[i + 2]
                    self.style.bold = bool(n_ & 0x08); self.style.height = 2 if n_ & 0x10 else 1; self.style.width = 2 if n_ & 0x20 else 1
                    i += 3; continue
                if c == 0x74 and need(3):  # ESC t 字碼頁
                    i += 3; continue
                self.note(f"ESC {c:#04x}"); i += 2; continue
            if b == 0x1C and need(2):  # FS（中文模式開關）
                c = data[i + 1]
                if c in (0x26, 0x2E):  # FS & / FS .
                    i += 2; continue
                if c == 0x43 and need(3):  # FS C
                    i += 3; continue
                self.note(f"FS {c:#04x}"); i += 2; continue
            if b == 0x1D and need(2):  # GS
                c = data[i + 1]
                if c == 0x21 and need(3):  # GS !
                    self.flush_text(); v = data[i + 2]
                    self.style.width = (v >> 4) + 1; self.style.height = (v & 0x0F) + 1; i += 3; continue
                if c == 0x42 and need(3):  # GS B
                    self.flush_text(); self.style.invert = bool(data[i + 2] & 1); i += 3; continue
                if c == 0x56 and need(3):  # GS V
                    m = data[i + 2]
                    i += 4 if m in (65, 66) and need(4) else 3
                    self.finish_page(cut=True); continue
                if c == 0x68 and need(3):  # GS h
                    self.barcode_height = data[i + 2]; i += 3; continue
                if c == 0x77 and need(3):  # GS w
                    self.barcode_module = data[i + 2]; i += 3; continue
                if c == 0x48 and need(3):  # GS H
                    i += 3; continue
                if c == 0x6B and need(3):  # GS k
                    m = data[i + 2]
                    if m >= 65 and need(4):
                        ln = data[i + 3]
                        payload = data[i + 4:i + 4 + ln]
                        self.flush_text()
                        if self.line:
                            self.newline()
                        self.page.add("code39", (payload.decode("ascii", "replace"), self.barcode_height, self.barcode_module, self.style.align))
                        i += 4 + ln; continue
                    j = data.find(b"\x00", i + 3)
                    i = (j + 1) if j >= 0 else n; continue
                if c == 0x76 and need(8) and data[i + 2] == 0x30:  # GS v 0
                    xl, xh, yl, yh = data[i + 4], data[i + 5], data[i + 6], data[i + 7]
                    rb, h = xl + (xh << 8), yl + (yh << 8)
                    raw = data[i + 8:i + 8 + rb * h]
                    self.flush_text()
                    if self.line:
                        self.newline()
                    self.page.add("raster", (rb, h, raw, self.style.align))
                    i += 8 + rb * h; continue
                if c == 0x28 and need(5) and data[i + 2] == 0x6B:  # GS ( k
                    pl, ph = data[i + 3], data[i + 4]
                    ln = pl + (ph << 8)
                    body = data[i + 5:i + 5 + ln]
                    if len(body) >= 3 and body[0] == 0x31:
                        fn = body[1]
                        if fn == 0x43:
                            self.qr_module = body[2]
                        elif fn == 0x50:
                            self.qr_data = bytes(body[3:])
                        elif fn == 0x51:
                            self.flush_text()
                            if self.line:
                                self.newline()
                            self.page.add("qr", (self.qr_data, self.qr_module, self.style.align))
                    i += 5 + ln; continue
                if c in (0x4C, 0x57) and need(4):  # GS L / GS W 邊界、寬度
                    i += 4; continue
                self.note(f"GS {c:#04x}"); i += 2; continue
            if b < 0x20 and b not in (0x09,):
                self.note(f"控制字元 {b:#04x}"); i += 1; continue
            self.text_buf.append(b); i += 1

    def close(self) -> list[Page]:
        self.finish_page(cut=False)
        return self.pages


# --- 畫圖 ---
def render_page(page: Page, font_cache: dict) -> Image.Image:
    W = page.width
    blocks: list[Image.Image] = []

    def font(px: int):
        if px not in font_cache:
            font_cache[px] = load_font(px)
        return font_cache[px]

    for kind, payload in page.items:
        if kind == "text":
            chars, align = payload
            if not chars:
                blocks.append(Image.new("L", (W, CELL_H + LINE_GAP), 255)); continue
            hmax = max(st.height for _, st in chars)
            line_h = CELL_H * hmax + LINE_GAP
            img = Image.new("L", (W, line_h), 255)
            d = ImageDraw.Draw(img)
            widths = [(CELL_W * (2 if is_wide(ch) else 1)) * st.width for ch, st in chars]
            total = sum(widths)
            x = 0 if align == 0 else (max(W - total, 0) // 2 if align == 1 else max(W - total, 0))
            for (ch, st), w in zip(chars, widths):
                h = CELL_H * st.height
                y = line_h - LINE_GAP - h
                if st.invert:
                    d.rectangle([x, y, x + w - 1, y + h - 1], fill=0)
                f = font(h - 2 if is_wide(ch) else int(h * 0.92))
                color = 255 if st.invert else 0
                cx = x + (w - d.textlength(ch, font=f)) / 2
                d.text((cx, y), ch, font=f, fill=color)
                if st.bold:
                    d.text((cx + 1, y), ch, font=f, fill=color)
                if st.underline:
                    d.line([x, y + h - 1, x + w - 1, y + h - 1], fill=color, width=2)
                x += w
            if x > W:  # 超出紙寬：畫一條紅線提醒（換成 RGB 時看得到）
                d.line([W - 2, 0, W - 2, line_h], fill=128, width=2)
            blocks.append(img)
        elif kind == "feed":
            blocks.append(Image.new("L", (W, (CELL_H + LINE_GAP) * max(payload, 0)), 255))
        elif kind == "raster":
            rb, h, raw, align = payload
            w = rb * 8
            img = Image.new("1", (w, h), 1)
            px = img.load()
            for y in range(h):
                for xb in range(rb):
                    v = raw[y * rb + xb] if y * rb + xb < len(raw) else 0
                    for bit in range(8):
                        if v & (0x80 >> bit):
                            px[xb * 8 + bit, y] = 0
            canvas = Image.new("L", (W, h), 255)
            x = 0 if align == 0 or w >= W else ((W - w) // 2 if align == 1 else W - w)
            canvas.paste(img.convert("L").crop((0, 0, min(w, W), h)), (x, 0))
            blocks.append(canvas)
        elif kind == "qr":
            data, module, align = payload
            if qrcode is not None:
                q = qrcode.QRCode(border=0, box_size=max(module, 1), error_correction=qrcode.constants.ERROR_CORRECT_L)
                q.add_data(data.decode("utf-8", "replace"))
                q.make(fit=True)
                img = q.make_image(fill_color="black", back_color="white").convert("L")
            else:
                img = Image.new("L", (120, 120), 255)
                ImageDraw.Draw(img).rectangle([0, 0, 119, 119], outline=0, width=3)
            canvas = Image.new("L", (W, img.height + 8), 255)
            x = (W - img.width) // 2 if align == 1 else (0 if align == 0 else W - img.width)
            canvas.paste(img, (max(x, 0), 4))
            blocks.append(canvas)
        elif kind == "code39":
            text, height, module, align = payload
            img = code39_image(text, height, module)
            canvas = Image.new("L", (W, img.height + 8), 255)
            x = (W - img.width) // 2 if align == 1 else 0
            canvas.paste(img.crop((0, 0, min(img.width, W), img.height)), (max(x, 0), 4))
            blocks.append(canvas)

    margin = 12
    total_h = sum(b.height for b in blocks) + margin * 2
    paper = Image.new("RGB", (W + 2 * margin, max(total_h, 40)), (255, 255, 255))
    y = margin
    for b in blocks:
        paper.paste(b.convert("RGB"), (margin, y))
        y += b.height
    d = ImageDraw.Draw(paper)
    d.rectangle([0, 0, paper.width - 1, paper.height - 1], outline=(200, 200, 200))
    return paper


CODE39 = {
    "0": "nnnwwnwnn", "1": "wnnwnnnnw", "2": "nnwwnnnnw", "3": "wnwwnnnnn", "4": "nnnwwnnnw", "5": "wnnwwnnnn",
    "6": "nnwwwnnnn", "7": "nnnwnnwnw", "8": "wnnwnnwnn", "9": "nnwwnnwnn", "A": "wnnnnwnnw", "B": "nnwnnwnnw",
    "C": "wnwnnwnnn", "D": "nnnnwwnnw", "E": "wnnnwwnnn", "F": "nnwnwwnnn", "G": "nnnnnwwnw", "H": "wnnnnwwnn",
    "I": "nnwnnwwnn", "J": "nnnnwwwnn", "K": "wnnnnnnww", "L": "nnwnnnnww", "M": "wnwnnnnwn", "N": "nnnnwnnww",
    "O": "wnnnwnnwn", "P": "nnwnwnnwn", "Q": "nnnnnnwww", "R": "wnnnnnwwn", "S": "nnwnnnwwn", "T": "nnnnwnwwn",
    "U": "wwnnnnnnw", "V": "nwwnnnnnw", "W": "wwwnnnnnn", "X": "nwnnwnnnw", "Y": "wwnnwnnnn", "Z": "nwwnwnnnn",
    "-": "nwnnnnwnw", ".": "wwnnnnwnn", " ": "nwwnnnwnn", "*": "nwnnwnwnn", "$": "nwnwnwnnn", "/": "nwnwnnnwn",
    "+": "nwnnnwnwn", "%": "nnnwnwnwn",
}


def code39_image(text: str, height: int, module: int) -> Image.Image:
    narrow, wide = max(module, 1), max(module, 1) * 3
    seq = "*" + text.upper() + "*"
    widths: list[tuple[int, bool]] = []
    for ch in seq:
        pat = CODE39.get(ch, CODE39["-"])
        for k, p in enumerate(pat):
            widths.append((wide if p == "w" else narrow, k % 2 == 0))
        widths.append((narrow, False))
    total = sum(w for w, _ in widths)
    img = Image.new("L", (total, height), 255)
    d = ImageDraw.Draw(img)
    x = 0
    for w, bar in widths:
        if bar:
            d.rectangle([x, 0, x + w - 1, height - 1], fill=0)
        x += w
    return img


def render_bytes(data: bytes, width: int, encoding: str, big5_check: bool = False) -> tuple[list[Image.Image], dict]:
    p = Printer(width, encoding, big5_check)
    p.feed(data)
    pages = p.close()
    cache: dict = {}
    images = [render_page(pg, cache) for pg in pages]
    info = {"pages": len(pages), "events": [pg.events for pg in pages], "unknown": p.unknown, "bytes": len(data),
            "notInBig5": {f"U+{ord(k):04X} {k}": v for k, v in p.missing.items()}}
    return images, info


def save(images: list[Image.Image], out: str) -> list[str]:
    paths = []
    base, ext = os.path.splitext(out)
    for k, img in enumerate(images):
        path = out if len(images) == 1 else f"{base}-{k + 1}{ext or '.png'}"
        img.save(path)
        paths.append(path)
    return paths


def serve(port: int, width: int, encoding: str, outdir: str, big5_check: bool = False) -> None:
    os.makedirs(outdir, exist_ok=True)
    counter = {"n": 0}
    lock = threading.Lock()

    def handle(conn: socket.socket, addr) -> None:
        chunks = []
        conn.settimeout(3)
        try:
            while True:
                b = conn.recv(65536)
                if not b:
                    break
                chunks.append(b)
        except socket.timeout:
            pass
        finally:
            conn.close()
        data = b"".join(chunks)
        if not data:
            return
        with lock:
            counter["n"] += 1
            n = counter["n"]
        stamp = time.strftime("%H%M%S")
        base = os.path.join(outdir, f"{n:03d}-{stamp}")
        with open(base + ".bin", "wb") as f:
            f.write(data)
        images, info = render_bytes(data, width, encoding, big5_check)
        paths = save(images, base + ".png")
        with open(base + ".json", "w") as f:
            json.dump(info, f, ensure_ascii=False)
        extra = " ".join(str(x) for x in (info["unknown"], info["notInBig5"]) if x)
        print(f"[{port}] 第 {n} 張：{len(data)} bytes → {', '.join(os.path.basename(p) for p in paths)} {info['events']} {extra}", flush=True)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)
    print(f"虛擬出單機在 :{port}（{width} 點、{encoding}）→ {outdir}", flush=True)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=9100)
    s.add_argument("--paper", choices=["58", "80"], default="58")
    s.add_argument("--encoding", default="big5")
    s.add_argument("--out", default="prints")
    s.add_argument("--big5-check", action="store_true", help="收 UTF-8、照 Big5 出單機印（Big5 沒有的字印成 ?）")
    r = sub.add_parser("render")
    r.add_argument("file")
    r.add_argument("--paper", choices=["58", "80"], default="58")
    r.add_argument("--encoding", default="big5")
    r.add_argument("-o", "--out", default=None)
    r.add_argument("--big5-check", action="store_true")
    a = ap.parse_args(argv)
    width = 384 if a.paper == "58" else 576
    if a.cmd == "serve":
        serve(a.port, width, a.encoding, a.out, a.big5_check)
        return 0
    data = open(a.file, "rb").read()
    images, info = render_bytes(data, width, a.encoding, a.big5_check)
    out = a.out or os.path.splitext(a.file)[0] + ".png"
    paths = save(images, out)
    print(json.dumps({**info, "files": paths}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
