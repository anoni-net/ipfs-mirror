# anoni.net IPFS 鏡像

[English](#anoninet-ipfs-mirror-1)

anoni.net 在 IPFS 上的備援。m6 停機、S3 出問題或內容被下架時，讀者仍然可以從 IPFS 讀到社群首頁、文件站、新聞導讀與隱私推理遊戲。這個 repo 放的是組裝與發布的腳本，四個專案各自建置 ipfs 版的產物，`publish.sh` 把它們組成一個目錄，發布到同一個 IPNS 名稱。

規劃與決定記在 toomore/anoni-net-ws#422。

## 讀者與志工怎麼取得

| 項目 | 值 |
|---|---|
| 公開閘道 | <https://ipfs.anoni.net/> |
| IPNS 名稱 | `k51qzi5uqu5dlfm2jj0f70ex3r3babmwy8qh071inwknttr7wqa3uhdwvlmrmw` |
| DNSLink | `_dnslink.anoni.net`，所以 `/ipns/anoni.net` 也解析得到 |

協助 pin 的志工照社群首頁的 [pin 節點設定說明](https://anoni.net/join/pin-ipfs-mirror/)設定即可。IPNS 名稱維持不變，2026-10 之前它只代表文件站，整站發布之後內容變成整個 anoni.net，志工不必改設定。

## 目錄結構

IPFS 的根目錄照 clearnet 的路徑排列，四個專案都把 `https://anoni.net/` 改寫成根目錄的相對路徑，跨專案的連結不必逐條對照。

| 路徑 | 專案 | m6 上的來源 |
|---|---|---|
| `/` | 社群首頁 `anoni-net/www` | `/srv/anoni-net-www/current/ipfs` |
| `/assets/` | 社群首頁內文用到的圖片 | 同上，www 的部署腳本放進來 |
| `/docs/` | 文件站 `anoni-net/docs` | 還沒決定，預設 `/home/ubuntu/app/ipfs-mirror/docs` |
| `/news/` | 新聞導讀 `anoni-net/news` | `/srv/anoni-net-news/ipfs` |
| `/mystery/` | 隱私推理遊戲 `anoni-net/privacy-mystery` | `/srv/anoni-net-mystery/current/ipfs` |
| `/_redirects` | 由 `publish.sh` 產生 | |

鏡像是備援，四個專案的 canonical、og 等完整網址都指回 `https://anoni.net`，搜尋引擎不會把鏡像當成另一個網站。Gears 與 API 不放進鏡像，連到它們的連結維持 clearnet。Gears 的模型合計約 4 GB，多執行緒需要的 COOP、COEP 標頭也只有 m6 的 nginx 會送。API 是動態服務。mystery 只放互動版，靜態版與 PDF 的結局是明文，志工 pin 過就收不回來、也無法修正。

鏡像要掛在閘道的根目錄。`ipfs.anoni.net`、DNSLink 與 subdomain gateway（`<CID>.ipfs.<閘道>`）都符合，`https://<閘道>/ipfs/<CID>/` 這種 path gateway 的形式連結會壞掉，`_redirects` 也不會生效。

## `_redirects`

kubo 在 DNSLink 與 subdomain gateway 上支援 `_redirects`，找不到檔案時才套用，由上往下第一條比對到的生效，檔案上限 64 KiB。`publish.sh` 每次發布都重新產生：

- 各區段的 404：`/docs/en/*`、`/docs/zh-cn/*`、`/docs/*`、`/news/*` 指向各自的 `404.html`，最後一條 `/*` 指向社群首頁的 `404.html`。mystery 沒有自己的 404 頁，落到最後一條
- 舊網址：2026-10 以前根目錄是文件站。依文件站產物最上層的目錄與檔案，各加一條 301 轉到 `/docs/` 底下。跟社群首頁撞名的路徑（`about`、`contact`、`assets` 等）顯示社群首頁的頁面，`/en/*` 與 `/zh-cn/*` 底下社群首頁沒有的頁面轉到文件站的同一頁

kubo 比對前會拿掉結尾的斜線，所以每個舊目錄有兩條規則，`/tools` 一條、`/tools/*` 一條。

## 運作方式

kubo 在 `digital_sg_1`（DigitalOcean 新加坡），不在 m6 上執行節點。IPFS 節點會把自己的 IP 公布在 DHT 上，m6 靠 Cloudflare 與 onion 藏住的位址會因此曝光。

1. m6 經 natsu 跳板開 SSH 通道，把本機的 `127.0.0.1:15001` 接到 kubo 的 API。SSH 設定是 m6 的 `digital_sg_1_kubo`，兩端的金鑰都只能轉送這一個連接埠
2. `ipfs` 指令用 docker 裡的 kubo 映像（`ipfs/kubo:v0.43.0`，跟節點同一個版本）當 client，只連通道，不啟動節點
3. 每個區段算一次內容雜湊，跟上次發布時相同就沿用上次的 CID，有變動的才上傳。上傳時不 pin
4. 在 kubo 的 MFS 組成 `/mirror-next`，加上 `_redirects`，取得根目錄的 CID
5. 發布 IPNS（`--lifetime=720h --ttl=1m`），等 90 秒讓閘道的 IPNS 快取過期，再把 `/mirror-next` 改名成 `/mirror`、執行 GC。MFS 裡的內容不會被 GC 清掉，舊版本在這一步才移除

內容跟上次發布相同時，腳本安靜結束，不會重新發布。kubo 會自己定期重新發布 IPNS record。

## 用法

```sh
./publish.sh                        # 組裝、上傳、發布
./publish.sh --no-upload            # 只在本機組裝到 staging/ 並檢查，不連 kubo
./publish.sh --stage                # 上傳並在 MFS 組成 /mirror-next，印出 CID，不發布
./publish.sh --stage --partial      # 允許缺少某些區段，測試用
```

來源路徑可以用 `SRC_ROOT`、`SRC_DOCS`、`SRC_NEWS`、`SRC_MYSTERY` 覆蓋。值也可以寫成 `/ipfs/<CID>`，直接拿 kubo 上已有的內容當那個區段，測試或退回時使用。

`--stage` 組好之後，在 `digital_sg_1` 上可以用 kubo 內建的 localhost subdomain gateway 測試，Host 要帶連接埠：

```sh
curl -sI -H "Host: <CID>.ipfs.localhost:8080" http://127.0.0.1:8080/tools/
```

## m6 上的設定

| 位置 | 內容 |
|---|---|
| `/home/ubuntu/app/ipfs-mirror/repo` | 本 repo 的 clone |
| `/home/ubuntu/app/ipfs-mirror/state/sections` | 上次發布的各區段雜湊、CID 與根目錄的 CID |
| `/home/ubuntu/app/ipfs-mirror/staging` | `--no-upload` 組出來的目錄 |
| `/home/ubuntu/ipfs-mirror.log` | 發布與失敗的紀錄 |

每天發布一次，www 與 news 每小時重建，跟著每小時發布的話 CID 每小時換一次，志工也要每小時下載差異。crontab 寫在 `publish.sh` 開頭的註解。要暫停自動發布時建立 `/home/ubuntu/app/ipfs-mirror/hold`，刪掉就恢復。

閘道的 nginx 設定在 m6 設定 repo 的 `digital_sg_1/nginx/`。`/mystery/` 的回應要帶 `Cache-Control: no-transform`，避免 Cloudflare Polish 洗掉照片的 EXIF，遊戲的線索在 EXIF 裡。

## 狀態

2026-10-21：社群首頁與 mystery 的 ipfs 產物已經在 m6 上產生，組裝與 `_redirects` 用 `--stage` 在 kubo 上測過。文件站與新聞導讀的 ipfs 目標還沒做，四個區段都齊了才會設定 crontab、正式發布。

## 授權

MIT，見 [LICENSE](./LICENSE)。鏡像裡的內容照各專案自己的授權。

---

# anoni.net IPFS mirror

A fallback for anoni.net on IPFS. If m6 goes down, S3 breaks or content is taken down, readers can still reach the home page, the docs site, the news digest and the privacy mysteries over IPFS. This repository holds the assembly and publishing script: each of the four projects builds its own ipfs output, and `publish.sh` puts them together in one directory and publishes it under one IPNS name.

The plan and its decisions are in toomore/anoni-net-ws#422.

## Reaching the mirror

| | |
|---|---|
| Public gateway | <https://ipfs.anoni.net/> |
| IPNS name | `k51qzi5uqu5dlfm2jj0f70ex3r3babmwy8qh071inwknttr7wqa3uhdwvlmrmw` |
| DNSLink | `_dnslink.anoni.net`, so `/ipns/anoni.net` resolves too |

Volunteers who pin the mirror can follow the [pinning guide](https://anoni.net/en/join/pin-ipfs-mirror/) on the home page. The IPNS name stays the same: until 2026-10 it held only the docs site, and once the whole site is published it holds all of anoni.net, with no change needed on the volunteers' side.

## Layout

The root mirrors the clearnet paths. All four projects rewrite `https://anoni.net/` into root-relative paths, so links between them work without a lookup table.

| Path | Project | Source on m6 |
|---|---|---|
| `/` | Home page, `anoni-net/www` | `/srv/anoni-net-www/current/ipfs` |
| `/assets/` | Images used by the home page | Same as above, added by www's deployment script |
| `/docs/` | Docs site, `anoni-net/docs` | Not decided yet; defaults to `/home/ubuntu/app/ipfs-mirror/docs` |
| `/news/` | News digest, `anoni-net/news` | `/srv/anoni-net-news/ipfs` |
| `/mystery/` | Privacy mysteries, `anoni-net/privacy-mystery` | `/srv/anoni-net-mystery/current/ipfs` |
| `/_redirects` | Generated by `publish.sh` | |

The mirror is a fallback, so canonical, og and the other absolute URLs in all four projects point back to `https://anoni.net`, and search engines don't treat the mirror as a separate site. Gears and the API are left out, and links to them stay on clearnet: Gears' models add up to about 4 GB, and only m6's nginx sends the COOP and COEP headers its multithreading needs; the API is a dynamic service. The mysteries ship their interactive editions only: the static editions and PDFs carry the endings in plain text, and what volunteers pin can't be taken back or corrected.

The mirror has to sit at the gateway's root. `ipfs.anoni.net`, DNSLink and subdomain gateways (`<CID>.ipfs.<gateway>`) all qualify; on a path gateway (`https://<gateway>/ipfs/<CID>/`) links break and `_redirects` does not apply.

## `_redirects`

kubo supports `_redirects` on DNSLink and subdomain gateways. Rules apply only when no file matches, the first matching rule wins, and the file is capped at 64 KiB. `publish.sh` regenerates it on every publish:

- Per-section 404s: `/docs/en/*`, `/docs/zh-cn/*`, `/docs/*` and `/news/*` point to their own `404.html`, and a final `/*` points to the home page's `404.html`. The mysteries have no 404 page of their own and fall through to that last rule
- Old URLs: until 2026-10 the root was the docs site. Each top-level directory and file in the docs output gets a 301 to the same path under `/docs/`. Paths that clash with the home page (`about`, `contact`, `assets` and so on) show the home page, and pages under `/en/*` and `/zh-cn/*` that the home page doesn't have go to the same page on the docs site

kubo strips the trailing slash before matching, so each old directory has two rules: one for `/tools` and one for `/tools/*`.

## How it works

kubo runs on `digital_sg_1` (DigitalOcean, Singapore), not on m6. An IPFS node announces its IP address on the DHT, which would expose the address m6 keeps behind Cloudflare and onion services.

1. m6 opens an SSH tunnel through the natsu jump host, connecting local `127.0.0.1:15001` to kubo's API. The SSH host on m6 is `digital_sg_1_kubo`, and the keys on both hops can forward only this one port
2. The `ipfs` command runs from the kubo image in docker (`ipfs/kubo:v0.43.0`, the same version as the node) as a client of the tunnel only; no node is started
3. Each section is hashed, and a section that hasn't changed since the last publish reuses its CID; only changed sections are uploaded, without pinning
4. The sections and `_redirects` are put together in kubo's MFS as `/mirror-next`, which gives the root CID
5. The IPNS record is published (`--lifetime=720h --ttl=1m`). After 90 seconds, once gateways' IPNS caches have expired, `/mirror-next` is renamed to `/mirror` and GC runs. Content in MFS is never garbage collected, so the old version is removed only at this step

When nothing has changed since the last publish, the script exits quietly without publishing. kubo republishes the IPNS record on its own.

## Usage

```sh
./publish.sh                        # assemble, upload, publish
./publish.sh --no-upload            # assemble locally into staging/ and check; no kubo
./publish.sh --stage                # upload and assemble /mirror-next in MFS, print the CID; no publish
./publish.sh --stage --partial      # allow missing sections, for testing
```

`SRC_ROOT`, `SRC_DOCS`, `SRC_NEWS` and `SRC_MYSTERY` override the source paths. A value can also be `/ipfs/<CID>` to use content already on kubo as that section, for testing or rolling back.

After `--stage`, test on `digital_sg_1` through kubo's built-in localhost subdomain gateway; the Host header needs the port:

```sh
curl -sI -H "Host: <CID>.ipfs.localhost:8080" http://127.0.0.1:8080/tools/
```

## Setup on m6

| Location | Contents |
|---|---|
| `/home/ubuntu/app/ipfs-mirror/repo` | A clone of this repository |
| `/home/ubuntu/app/ipfs-mirror/state/sections` | Each section's hash and CID from the last publish, and the root CID |
| `/home/ubuntu/app/ipfs-mirror/staging` | The directory `--no-upload` assembles |
| `/home/ubuntu/ipfs-mirror.log` | Publishes and failures |

It publishes once a day. www and news rebuild every hour, and publishing with them would change the CID every hour and have volunteers download the difference every hour. The crontab line is in the comment at the top of `publish.sh`. To pause automatic publishing, create `/home/ubuntu/app/ipfs-mirror/hold`; delete it to resume.

The gateway's nginx configuration is in the m6 config repository under `digital_sg_1/nginx/`. Responses under `/mystery/` need `Cache-Control: no-transform` so Cloudflare Polish doesn't strip EXIF from the photos, where the game's clues are.

## Status

2026-10-21: the home page and the mysteries produce their ipfs output on m6, and the assembly and `_redirects` have been tested on kubo with `--stage`. The ipfs targets for the docs site and the news digest are still to do; the crontab and the first full publish wait until all four sections are in place.

## License

MIT; see [LICENSE](./LICENSE). The mirrored content is under each project's own license.
