#!/usr/bin/env python3
"""
App Store Connect API（GitHub Actions 的 TestFlight 流程用，.github/workflows/testflight.yml）。

  python3 ci/asc.py prepare
      確認 App ID（bundle id）註冊了，沒有就註冊；確認 App Store Connect 上有這個 App（沒有就停下來說明怎麼建）
  python3 ci/asc.py signing --dir <暫存資料夾> --name "StudioX CI 2610021405"
      這一次建置專用的簽章：打開 App ID 的推播能力、建一張 Apple Distribution 憑證（私鑰只在這台 Mac）、
      建 App Store 描述檔，寫出 signing.p12（密碼在 signing.pass）、profile.mobileprovision、appstore.entitlements，
      輸出 cert_id、profile_id、profile_uuid
  python3 ci/asc.py invite
      只寄 TestFlight 邀請（帳號持有人＋TESTFLIGHT_TESTERS），不建置；.github/workflows/testflight-invite.yml。
      TESTFLIGHT_TESTERS 裡還不是 App Store Connect 團隊成員的人，先寄團隊邀請（內部測試員一定要是成員）
  python3 ci/asc.py cleanup --cert <id> --profile <id>
      用完就撤銷憑證、刪掉描述檔（已經上傳的版本不受影響；不會越積越多）
  python3 ci/asc.py finish --app <id> --version 1.0 --build 2610021405 --notes notes.txt
      等 Apple 處理好這一版、寫「測試內容」、交給內部測試群組，寄 TestFlight 邀請給帳號持有人
      （和 Secrets 的 TESTFLIGHT_TESTERS，選填，逗號隔開，每一筆「email」或「姓名 <email>」）

金鑰從環境變數讀（GitHub 的 Secrets）：ASC_KEY_ID、ASC_ISSUER_ID、ASC_PRIVATE_KEY（.p8 的內容）。
只用標準函式庫＋PyJWT（pip install pyjwt cryptography）。
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "tw.studiox.pos")
APP_NAME = os.environ.get("APP_NAME", "StudioX POS")


class ApiError(Exception):
    def __init__(self, status, method, path, detail):
        super().__init__(f"App Store Connect API {method} {path} → {status}: {detail[:1500]}")
        self.status = status
        self.detail = detail


def private_key():
    return os.environ["ASC_PRIVATE_KEY"].strip().replace("\\n", "\n")


# 團隊金鑰（Team key）用 iss＝Issuer ID；個人金鑰（Individual key）用 sub＝"user"。先試團隊的，401 再試個人的
KEY_MODE = {"mode": "team", "switched": False}


def token():
    # iat 往前 30 秒：GitHub 機器的時間比 Apple 快一點也不會被當成「未來的 token」（有效期限一樣不超過 20 分鐘）
    now = int(time.time())
    claims = {"iat": now - 30, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    if KEY_MODE["mode"] == "team":
        claims["iss"] = os.environ["ASC_ISSUER_ID"].strip()
    else:
        claims["sub"] = "user"
    return jwt.encode(claims, private_key(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def call(method, path, body=None, query=None):
    # /v2/… 的端點（上架地區）不在 /v1 底下
    base = API.rsplit("/v1", 1)[0] if path.startswith("/v2/") else API
    url = base + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        if e.code == 401 and not KEY_MODE["switched"]:
            KEY_MODE["switched"] = True
            KEY_MODE["mode"] = "individual"
            try:
                result = call(method, path, body, query)
                summary("- 這把是個人金鑰（Individual key）")
                return result
            except ApiError:
                KEY_MODE["mode"] = "team"
        raise ApiError(e.code, method, path, detail) from None


def apple_error(e):
    """Apple 回的錯誤代碼與說明（不含任何金鑰內容）"""
    try:
        errs = json.loads(e.detail).get("errors", [])
        return "；".join(f"{x.get('code')}：{x.get('detail') or x.get('title')}" for x in errs) or str(e)
    except Exception:
        return str(e)


def diagnose():
    """金鑰被拒時：只檢查格式（不印出任何值），告訴他哪一個 Secret 可能貼錯"""
    import re
    lines = []
    kid = os.environ.get("ASC_KEY_ID", "").strip()
    iss = os.environ.get("ASC_ISSUER_ID", "").strip()
    team = os.environ.get("APPLE_TEAM_ID", "").strip()
    uuid = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    lines.append(f"- `ASC_KEY_ID`：{'✅ 10 個英數字' if re.fullmatch(r'[A-Z0-9]{10}', kid) else f'❌ 應該是 10 個大寫英數字（現在 {len(kid)} 個字）'}")
    if uuid.match(kid):
        lines.append("  - 看起來貼成了 Issuer ID，兩個可能對調了")
    lines.append(f"- `ASC_ISSUER_ID`：{'✅ UUID 格式' if uuid.match(iss) else f'❌ 應該是有 4 個「-」的 UUID（現在 {len(iss)} 個字）'}")
    try:
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from cryptography.hazmat.primitives.asymmetric import ec
        k = load_pem_private_key(private_key().encode(), password=None)
        ok = isinstance(k, ec.EllipticCurvePrivateKey) and k.curve.name == "secp256r1"
        lines.append(f"- `ASC_PRIVATE_KEY`：{'✅ 讀得懂（EC P-256）' if ok else '❌ 不是 App Store Connect 的金鑰（要 EC P-256）'}")
    except Exception:
        pk = private_key()
        hint = "少了 `-----BEGIN PRIVATE KEY-----` 那一行" if "BEGIN PRIVATE KEY" not in pk else "內容不完整或多了字"
        lines.append(f"- `ASC_PRIVATE_KEY`：❌ 讀不懂（{hint}）；用文字編輯器打開 .p8，從第一行到最後一行整段貼上")
    lines.append(f"- `APPLE_TEAM_ID`：{'✅ 10 個英數字' if re.fullmatch(r'[A-Z0-9]{10}', team) else '❌ 應該是 10 個大寫英數字（developer.apple.com → Membership）'}")
    return "\n".join(lines)


def summary(text):
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")


def output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")


# ── prepare ──────────────────────────────────────────────────────────────────

def prepare():
    try:
        found = call("GET", "/bundleIds", query={"filter[identifier]": BUNDLE_ID, "limit": 200})
    except ApiError as e:
        if e.status == 401:
            summary(f"### ❌ App Store Connect 不接受這把 API 金鑰（401）\nApple 說：{apple_error(e)}\n\n"
                    f"各個 Secret 的格式檢查：\n{diagnose()}\n\n"
                    "格式都對的話，通常是這幾個：\n"
                    "1. **Key ID 和 .p8 不是同一把**：.p8 的檔名是 `AuthKey_XXXXXXXXXX.p8`，XXXXXXXXXX 要和 `ASC_KEY_ID` 一模一樣。"
                    "推播（APNs）或 Sign in with Apple 的金鑰也是 .p8、長得一樣，但不能用——要「使用者與存取權 → 整合 → App Store Connect API」那裡產生的\n"
                    "2. **Issuer ID**：在同一頁「團隊金鑰」表格上方（不是金鑰那一列的 ID）\n"
                    "3. 金鑰剛產生：等幾分鐘，在 Actions 這一頁按 Re-run jobs\n"
                    "4. 金鑰被撤銷了：重新產生一把，`ASC_KEY_ID`、`ASC_PRIVATE_KEY` 一起換")
            sys.exit(1)
        if e.status == 403:
            summary(f"### ❌ 這把 API 金鑰的權限不夠（403）\nApple 說：{apple_error(e)}\n\n"
                    "App Store Connect → 使用者與存取權 → 整合 → 團隊金鑰：重新產生一把、存取權選 **Admin**"
                    "（要能註冊 App ID、建憑證與描述檔），然後更新 `ASC_KEY_ID` 與 `ASC_PRIVATE_KEY`。")
            sys.exit(1)
        raise
    bundle = next((b for b in found.get("data", []) if b["attributes"]["identifier"] == BUNDLE_ID), None)
    if bundle is None:
        call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE_ID, "name": "StudioX POS", "platform": "IOS"}}})
        summary(f"- 註冊了 App ID `{BUNDLE_ID}`")
    else:
        summary(f"- App ID `{BUNDLE_ID}` 已註冊")

    apps = call("GET", "/apps", query={"filter[bundleId]": BUNDLE_ID, "limit": 1}).get("data", [])
    if not apps:
        summary(
            "### ⏸ App Store Connect 上還沒有這個 App\n"
            "Apple 不讓 API 建新的 App，這一步要在網頁上做一次（之後都自動）：\n"
            "1. 打開 https://appstoreconnect.apple.com/apps →「＋」→ 新增 App\n"
            f"2. 平台 iOS、名稱 {APP_NAME}、主要語言 繁體中文、套件 ID 選 `{BUNDLE_ID}`、SKU 填 `studiox-pos`、使用者存取權 完整存取權\n"
            "3. 建好之後回 GitHub 的 Actions → TestFlight → Re-run jobs\n")
        sys.exit(1)
    app = apps[0]
    summary(f"- App Store Connect 上的 App：{app['attributes'].get('name')}（{app['id']}）")
    output("app_id", app["id"])


# ── signing ──────────────────────────────────────────────────────────────────

# API 打得開的能力（Apple 的 CapabilityType）：App ID 要打開，描述檔裡才會有。
# POS 不用推播；藍牙出單機（CoreBluetooth）、區網同步（Bonjour）、相機掃碼都只要 Info.plist 的說明，不用 entitlement
CAPABILITIES = []
# App 想要的 entitlements。實際放哪些看 Apple 發的描述檔裡有什麼
WANTED_ENTITLEMENTS = []


def bundle_resource():
    found = call("GET", "/bundleIds", query={"filter[identifier]": BUNDLE_ID, "limit": 200}).get("data", [])
    bundle = next((b for b in found if b["attributes"]["identifier"] == BUNDLE_ID), None)
    if bundle is None:
        sys.exit(f"App ID {BUNDLE_ID} 還沒註冊（prepare 應該先註冊）")
    return bundle


def ensure_capabilities(bundle_id):
    """App ID 打開 App 要的能力（已經打開的不動）。打不開的寫在摘要，不讓建置失敗——描述檔裡沒有的 entitlement 不會放進 App"""
    have = {c["attributes"].get("capabilityType") for c in
            call("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities").get("data", [])}
    for cap in CAPABILITIES:
        if cap in have:
            continue
        try:
            call("POST", "/bundleIdCapabilities", {"data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": cap},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}}}})
            summary(f"- App ID 打開了 {cap}")
        except ApiError as e:
            # 注意：App Store Connect 的 409 是「資料不對」，不一定是「已經有了」
            summary(f"- ⚠️ App ID 沒辦法打開 {cap}：{apple_error(e)}")


def profile_entitlements(profile_bytes):
    """描述檔（CMS 簽章包著的 plist）裡 Apple 允許的 entitlements"""
    import plistlib
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.find(b"</plist>")
    if start < 0 or end < 0:
        return {}
    return plistlib.loads(profile_bytes[start:end + len(b"</plist>")]).get("Entitlements", {})


def write_entitlements(path, allowed):
    """App 要的 entitlements，只放描述檔允許的（值用描述檔的，例如 aps-environment＝production）"""
    import plistlib
    ent = {k: allowed[k] for k in WANTED_ENTITLEMENTS if k in allowed}
    with open(path, "wb") as f:
        plistlib.dump(ent, f)
    missing = [k for k in WANTED_ENTITLEMENTS if k not in allowed]
    if "com.apple.developer.usernotifications.time-sensitive" in missing:
        summary("- 這一版沒有 Time Sensitive 通知（緊急的通知照樣送，只是專注模式下不會穿透）。"
                "要的話到 developer.apple.com → Identifiers → `" + BUNDLE_ID + "` 勾 Time Sensitive Notifications，下一版就會有")
    if "aps-environment" in missing:
        summary("- ⚠️ 描述檔裡沒有推播（aps-environment），這一版收不到通知")


def signing(args):
    import base64
    import secrets
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import NameOID

    os.makedirs(args.dir, exist_ok=True)
    bundle = bundle_resource()
    ensure_capabilities(bundle["id"])

    # 憑證：私鑰在這台 Mac 產生、只存在暫時的鑰匙圈，建置完就撤銷
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, args.name)]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    # 到上限（409）多半是同一個團隊的另一個 App（StudioX Console）正在建置、它這一次的憑證還沒撤銷：
    # 等它用完（每 45 秒再試，最多 12 分鐘），不撤銷別人的憑證
    deadline = time.time() + 12 * 60
    while True:
        try:
            cert = call("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
                "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}})["data"]
            break
        except ApiError as e:
            if e.status != 409:
                raise
            if time.time() < deadline:
                print("Apple Distribution 憑證到上限：等同一個團隊的另一個建置用完再試（45 秒後）", flush=True)
                time.sleep(45)
                continue
            summary("### ❌ Apple Distribution 憑證已經到上限\n"
                    "等了 12 分鐘還是滿的：到 developer.apple.com → Certificates 撤銷用不到的 Distribution 憑證，再重跑。")
            sys.exit(1)
    output("cert_id", cert["id"])
    der = base64.b64decode(cert["attributes"]["certificateContent"])
    certificate = x509.load_der_x509_certificate(der)

    # 舊版 macOS 的 security 只讀得懂傳統加密的 .p12
    password = secrets.token_urlsafe(24)
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder()
                  .kdf_rounds(50000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
                  .hmac_hash(hashes.SHA1())
                  .build(password.encode()))
    with open(os.path.join(args.dir, "signing.p12"), "wb") as f:
        f.write(pkcs12.serialize_key_and_certificates(args.name.encode(), key, certificate, None, encryption))
    # 密碼只放在暫存資料夾（不進 GitHub 的輸出），也先遮掉
    print(f"::add-mask::{password}")
    with open(os.path.join(args.dir, "signing.pass"), "w") as f:
        f.write(password)

    # App Store 描述檔：只綁這張憑證
    profile = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": args.name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
        }}})["data"]
    output("profile_id", profile["id"])
    output("profile_uuid", profile["attributes"]["uuid"])
    profile_bytes = base64.b64decode(profile["attributes"]["profileContent"])
    with open(os.path.join(args.dir, "profile.mobileprovision"), "wb") as f:
        f.write(profile_bytes)

    write_entitlements(os.path.join(args.dir, "appstore.entitlements"), profile_entitlements(profile_bytes))
    summary(f"- 這一次的簽章：憑證與描述檔「{args.name}」（建置完就撤銷）")


def cleanup(args):
    if args.profile:
        try:
            call("DELETE", f"/profiles/{args.profile}")
        except ApiError as e:
            summary(f"- ⚠️ 描述檔沒有刪掉：{e}")
    if args.cert:
        try:
            call("DELETE", f"/certificates/{args.cert}")
            summary("- 撤銷了這一次的憑證、刪掉描述檔（已經上傳的版本不受影響）")
        except ApiError as e:
            summary(f"- ⚠️ 憑證沒有撤銷，到 developer.apple.com 撤銷名稱是「StudioX CI …」的那張：{e}")


# ── finish ───────────────────────────────────────────────────────────────────


def wait_for_build(app_id, version, build, minutes=40):
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        builds = call("GET", "/builds", query={
            "filter[app]": app_id, "filter[version]": build,
            "filter[preReleaseVersion.version]": version, "limit": 1,
        }).get("data", [])
        if builds:
            state = builds[0]["attributes"].get("processingState")
            if state == "VALID":
                return builds[0]
            if state in ("FAILED", "INVALID"):
                summary(f"### ❌ Apple 處理這一版失敗（{state}）\n到 App Store Connect → TestFlight 看原因（通常也會寄信）。")
                sys.exit(1)
        time.sleep(30)
    summary(f"### ⏳ Apple 還在處理 {version}（{build}），超過 {minutes} 分鐘\n處理好之後一樣會出現在 TestFlight，只是這次沒寫到「測試內容」。")
    sys.exit(0)


def whats_new(app_id, build_id, text):
    locs = call("GET", f"/builds/{build_id}/betaBuildLocalizations").get("data", [])
    if locs:
        for loc in locs:
            call("PATCH", f"/betaBuildLocalizations/{loc['id']}", {"data": {
                "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})
    else:
        locale = call("GET", f"/apps/{app_id}").get("data", {}).get("attributes", {}).get("primaryLocale") or "zh-Hant"
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": locale, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    summary("- 寫好了 TestFlight 的「測試內容」")


def internal_groups(app_id):
    """內部測試群組；一個都沒有就建一個（拿到每一版）"""
    # 關聯的端點（/apps/{id}/betaGroups、/bundleIds/{id}/bundleIdCapabilities）不收 limit
    groups = call("GET", f"/apps/{app_id}/betaGroups").get("data", [])
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if internal:
        return internal
    try:
        g = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": "StudioX 團隊", "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        summary("- 建了內部測試群組「StudioX 團隊」")
        return [g]
    except ApiError as e:
        summary(f"- ⚠️ 沒辦法建內部測試群組（到 App Store Connect → TestFlight → 內部測試「＋」建一個）：{apple_error(e)}")
        return []


def mask(email):
    name, _, domain = email.partition("@")
    return f"{name[:2]}***@{domain}" if domain else "***"


def testers():
    """要收到邀請的人：App Store Connect 的帳號持有人，加上 Secrets 的 TESTFLIGHT_TESTERS（逗號隔開的 Email，選填）。
    Email 不寫在程式裡，從 App Store Connect 或 Secrets 讀"""
    people = {}
    try:
        for u in call("GET", "/users", query={"filter[roles]": "ACCOUNT_HOLDER", "limit": 10}).get("data", []):
            a = u["attributes"]
            if a.get("username"):
                people[a["username"].lower()] = (a.get("firstName") or "", a.get("lastName") or "")
    except ApiError as e:
        summary(f"- ⚠️ 讀不到帳號持有人（金鑰要 Admin）：{apple_error(e)}")
    for email, name in parse_testers(os.environ.get("TESTFLIGHT_TESTERS", "")).items():
        people.setdefault(email, name)
    for email, name in sealed_testers().items():
        people.setdefault(email, name)
    return people


# ci/testers.enc：用 App Store Connect 金鑰的公鑰加密的名單（一行一筆「姓名 <email>」），repo 裡看不到 Email。
# 只有拿得到 ASC_PRIVATE_KEY 的 GitHub Actions 解得開。加一筆：python3 ci/seal_tester.py <公鑰> "姓名 <email>" >> ci/testers.enc
# （公鑰印在「TestFlight 邀請」的摘要；金鑰換了要重新加密）
SEALED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testers.enc")
SEAL_INFO = b"studiox-testflight-testers-v1"


def signing_key():
    from cryptography.hazmat.primitives import serialization
    return serialization.load_pem_private_key(private_key().encode(), password=None)


def public_key_b64():
    from cryptography.hazmat.primitives import serialization
    point = signing_key().public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.b64encode(point).decode()


def sealed_testers():
    if not os.path.exists(SEALED):
        return {}
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    key = signing_key()
    out = {}
    for line in open(SEALED, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            blob = base64.b64decode(line)
            ephemeral = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), blob[:65])
            shared = key.exchange(ec.ECDH(), ephemeral)
            aes = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=SEAL_INFO).derive(shared)
            text = AESGCM(aes).decrypt(blob[65:77], blob[77:], SEAL_INFO).decode("utf-8")
            out.update(parse_testers(text))
        except Exception:
            summary("- ⚠️ ci/testers.enc 有一筆解不開（App Store Connect 的金鑰換過了？用新的公鑰重新加密）")
    return out


def pubkey_cmd():
    """印出加密名單用的公鑰（公鑰不是秘密）"""
    pub = public_key_b64()
    print(pub)
    summary(f"### 加密測試員名單用的公鑰\n`{pub}`\n\n`python3 ci/seal_tester.py {pub} \"姓名 <email>\" >> ci/testers.enc`")


def parse_testers(raw):
    """TESTFLIGHT_TESTERS：逗號或換行隔開，每一筆是「email」或「姓名 <email>」→ {email: (名, 姓)}"""
    out = {}
    for part in raw.replace("\n", ",").split(","):
        part = part.strip()
        name, email = "", part
        if "<" in part and part.endswith(">"):
            name, email = part[:part.index("<")].strip(), part[part.index("<") + 1:-1].strip()
        email = email.lower()
        if "@" in email:
            out[email] = split_name(name)
    return out


def split_name(name):
    """（名, 姓）：英文名最後一個字是姓；中文名第一個字是姓（複姓請寫成「歐陽 娜娜」）"""
    name = " ".join(name.split())
    if " " in name:
        if all(ord(c) >= 0x2E80 for c in name.replace(" ", "")):
            last, _, first = name.partition(" ")
        else:
            first, _, last = name.rpartition(" ")
        return (first, last)
    if len(name) >= 2 and all(ord(c) >= 0x2E80 for c in name):
        return (name[1:], name[:1])
    return (name, "")


# 可以當內部測試員的角色（Apple 的規定）
TESTER_ROLES = {"ACCOUNT_HOLDER", "ADMIN", "APP_MANAGER", "DEVELOPER", "MARKETING"}


def team_status(email):
    """App Store Connect 團隊裡有沒有這個人：("user", …)、("invited", …)（還沒接受團隊邀請）或 (None, None)。
    回來的資料要 Email 完全一樣才算（篩選沒生效時會回別人）"""
    try:
        users = call("GET", "/users", query={"filter[username]": email, "limit": 10}).get("data", [])
    except ApiError:
        # 篩選不能用：整個團隊拿回來自己找（團隊不大）
        users = call("GET", "/users", query={"limit": 200}).get("data", [])
    for u in users:
        if (u["attributes"].get("username") or "").lower() == email:
            return "user", u
    pending = call("GET", "/userInvitations", query={"filter[email]": email, "limit": 10}).get("data", [])
    for invitation in pending:
        if (invitation["attributes"].get("email") or "").lower() == email:
            return "invited", invitation
    return None, None


def can_test(app_id, user, email):
    """團隊成員能不能當這個 App 的內部測試員：角色要對、要看得到這個 App（看不到就打開這一個 App 給他）"""
    a = user["attributes"]
    roles = set(a.get("roles") or [])
    if not roles & TESTER_ROLES:
        summary(f"- ⚠️ {mask(email)} 是團隊成員，但角色（{'、'.join(sorted(roles)) or '?'}）不能當內部測試員：\n"
                f"  App Store Connect → 使用者和存取權限 → 他 → 角色加上 Developer")
        return False
    if a.get("allAppsVisible"):
        return True
    try:
        visible = {x["id"] for x in call("GET", f"/users/{user['id']}/relationships/visibleApps").get("data", [])}
    except ApiError as e:
        summary(f"- ⚠️ 讀不到 {mask(email)} 看得到哪些 App：{apple_error(e)}")
        return True
    if app_id in visible:
        return True
    try:
        call("POST", f"/users/{user['id']}/relationships/visibleApps", {"data": [{"type": "apps", "id": app_id}]})
        summary(f"- {mask(email)} 原本看不到這個 App：打開給他（只有這一個）")
        return True
    except ApiError as e:
        summary(f"- ⚠️ 沒辦法讓 {mask(email)} 看到這個 App：{apple_error(e)}\n"
                f"  App Store Connect → 使用者和存取權限 → 他 → App 加上這一個")
        return False


def invite_to_team(app_id, email, first, last):
    """TestFlight 的內部測試員一定要是 App Store Connect 團隊的成員（Apple 的規定）。
    還不是的人先寄團隊邀請：Developer 角色、只看得到這個 App、不能動憑證和描述檔；
    對方按信裡的連結接受後，下一次邀請（或下一版 TestFlight）就會把他加進測試群組、寄 TestFlight 邀請"""
    local = email.split("@")[0]
    try:
        call("POST", "/userInvitations", {"data": {
            "type": "userInvitations",
            "attributes": {"email": email, "firstName": first or local, "lastName": last or local,
                           "roles": ["DEVELOPER"], "allAppsVisible": False, "provisioningAllowed": False},
            "relationships": {"visibleApps": {"data": [{"type": "apps", "id": app_id}]}}}})
        summary(f"- ✉️ {mask(email)} 還不是 App Store Connect 團隊的成員：寄了團隊邀請（Developer、只看得到這個 App）。"
                f"對方接受後再跑一次「TestFlight 邀請」就會寄 TestFlight 邀請")
    except ApiError as e:
        summary(f"- ⚠️ 沒辦法邀請 {mask(email)} 加入 App Store Connect 團隊：{apple_error(e)}\n"
                f"  可以在 App Store Connect → 使用者和存取權限 →「＋」手動邀請（角色 Developer）")


def group_members(gid):
    """群組裡的測試員（email → 資料）。用群組裡看到的 id 寄邀請最可靠"""
    out = {}
    try:
        for t in call("GET", f"/betaGroups/{gid}/betaTesters").get("data", []):
            email = (t["attributes"].get("email") or "").lower()
            if email:
                out[email] = t
    except ApiError as e:
        summary(f"- ⚠️ 讀不到群組的測試員：{apple_error(e)}")
    return out


def send_invitation(app_id, tester_id, tries=4):
    """寄（或重寄）TestFlight 邀請。剛加進群組時 Apple 可能還沒同步，404 就等一下再試"""
    for i in range(tries):
        try:
            call("POST", "/betaTesterInvitations", {"data": {
                "type": "betaTesterInvitations",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                    "betaTester": {"data": {"type": "betaTesters", "id": tester_id}}}}})
            return None
        except ApiError as e:
            if e.status == 404 and i < tries - 1:
                time.sleep(20)
                continue
            return apple_error(e)


def tester_groups(tester_id):
    try:
        return [g["id"] for g in call("GET", f"/betaTesters/{tester_id}/relationships/betaGroups").get("data", [])]
    except ApiError:
        return None


def add_to_group(gid, gname, email, first, last):
    """把 App Store Connect 的使用者加進內部群組（和 fastlane pilot 一樣：建立測試員時直接指定群組）。
    之前留下、不在任何群組裡的測試員紀錄會擋住（STATE_ERROR：Tester(s) cannot be assigned），先刪掉再建"""
    for old in call("GET", "/betaTesters", query={"filter[email]": email, "limit": 10}).get("data", []):
        groups = tester_groups(old["id"])
        if groups == []:
            try:
                call("DELETE", f"/betaTesters/{old['id']}")
                summary(f"- 刪掉 {mask(email)} 之前沒加成功的測試員紀錄")
            except ApiError as e:
                summary(f"- ⚠️ 舊的測試員紀錄刪不掉：{apple_error(e)}")
        elif groups and gid not in groups:
            try:
                call("POST", f"/betaTesters/{old['id']}/relationships/betaGroups", {"data": [{"type": "betaGroups", "id": gid}]})
                summary(f"- {mask(email)} 加進「{gname}」")
                return
            except ApiError as e:
                summary(f"- ⚠️ {mask(email)} 加不進「{gname}」：{apple_error(e)}")
    try:
        created = call("POST", "/betaTesters", {"data": {
            "type": "betaTesters",
            "attributes": {"email": email, "firstName": first or None, "lastName": last or None},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}}).get("data", {})
        a = created.get("attributes") or {}
        summary(f"- {mask(email)} 建立為「{gname}」的測試員（{a.get('inviteType') or '?'}／{a.get('state') or '?'}）")
    except ApiError as e:
        summary(f"- ⚠️ 沒辦法把 {mask(email)} 加進「{gname}」：{apple_error(e)}")


def invite(app_id, group):
    """確定帳號持有人（和 TESTFLIGHT_TESTERS）在測試群組裡，寄 TestFlight 邀請給群組裡每個還沒裝的人"""
    gid, gname = group["id"], group["attributes"].get("name")
    members = group_members(gid)
    missing = {}
    for email, (first, last) in testers().items():
        if email in members:
            continue
        try:
            status, user = team_status(email)
        except ApiError as e:
            summary(f"- ⚠️ 查不到 {mask(email)} 是不是團隊成員：{apple_error(e)}")
            status = "user"
            user = None
        if status is None:
            invite_to_team(app_id, email, first, last)
        elif status == "invited":
            summary(f"- ⏳ {mask(email)} 還沒接受 App Store Connect 的團隊邀請（Apple 寄的信），接受後再跑一次就會寄 TestFlight 邀請")
        elif user is None or can_test(app_id, user, email):
            add_to_group(gid, gname, email, first, last)
            missing[email] = (first, last)
    if missing:
        # Apple 把人放進群組要一點時間
        for _ in range(6):
            time.sleep(10)
            members = group_members(gid)
            if all(e in members for e in missing):
                break
    summary(f"- 「{gname}」有 {len(members)} 位測試員" + ("：" + "、".join(
        f"{mask(m)}（{t['attributes'].get('state') or '?'}）" for m, t in members.items()) if members else ""))
    if not members:
        summary(f"### 👉 Apple 還沒有把人放進「{gname}」\n"
                f"App Store Connect → App → TestFlight → 內部測試「{gname}」→ 測試人員旁的「＋」→ 勾自己 → 加入（一次就好）")
    for email, tester in members.items():
        if tester["attributes"].get("state") == "INSTALLED":
            summary(f"- {mask(email)} 已經裝了，打開 iPhone 的 TestFlight 就有新版")
            continue
        error = send_invitation(app_id, tester["id"])
        if error is None:
            summary(f"- ✉️ 寄了 TestFlight 邀請給 {mask(email)}")
        else:
            summary(f"- ⚠️ 邀請信沒寄出（{mask(email)}）：{error}\n"
                    f"  可以在 App Store Connect → TestFlight →「{gname}」→ 測試人員，勾選後按「重新傳送邀請」")


def invite_cmd():
    apps = call("GET", "/apps", query={"filter[bundleId]": BUNDLE_ID, "limit": 1}).get("data", [])
    if not apps:
        summary("### ⏸ App Store Connect 上還沒有這個 App")
        sys.exit(1)
    groups = internal_groups(apps[0]["id"])
    if not groups:
        sys.exit(1)
    summary(f"### TestFlight 邀請（{apps[0]['attributes'].get('name')}）")
    invite(apps[0]["id"], groups[0])


def give_to_internal_groups(app_id, build_id):
    internal = internal_groups(app_id)
    if not internal:
        return []
    for g in internal:
        name = g["attributes"].get("name")
        if g["attributes"].get("hasAccessToAllBuilds"):
            summary(f"- 內部群組「{name}」自動拿到所有版本")
            continue
        try:
            call("POST", f"/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})
            summary(f"- 交給內部群組「{name}」")
        except ApiError as e:
            summary(f"- ⚠️ 沒有交給「{name}」：{apple_error(e)}")
    return internal


def finish(args):
    build = wait_for_build(args.app, args.version, args.build)
    summary(f"### ✅ {args.version}（{args.build}）已經在 TestFlight")
    text = open(args.notes, encoding="utf-8").read().strip()[:3900] if args.notes else ""
    if text:
        try:
            whats_new(args.app, build["id"], text)
        except ApiError as e:
            summary(f"- ⚠️ 「測試內容」沒有寫上去：{e}")
    groups = give_to_internal_groups(args.app, build["id"])
    if groups:
        invite(args.app, groups[0])


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prepare")
    sub.add_parser("invite")
    sub.add_parser("pubkey")
    sg = sub.add_parser("signing")
    sg.add_argument("--dir", required=True)
    sg.add_argument("--name", required=True)
    c = sub.add_parser("cleanup")
    c.add_argument("--cert", default="")
    c.add_argument("--profile", default="")
    f = sub.add_parser("finish")
    f.add_argument("--app", required=True)
    f.add_argument("--version", required=True)
    f.add_argument("--build", required=True)
    f.add_argument("--notes")
    args = p.parse_args()
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"):
        if not os.environ.get(name, "").strip():
            sys.exit(f"缺少 {name}")
    {"prepare": lambda: prepare(), "invite": lambda: invite_cmd(), "pubkey": lambda: pubkey_cmd(), "signing": lambda: signing(args),
     "cleanup": lambda: cleanup(args), "finish": lambda: finish(args)}[args.cmd]()


if __name__ == "__main__":
    main()
