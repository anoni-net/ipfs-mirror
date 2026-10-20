#!/bin/sh
# 組裝 anoni.net 的 IPFS 鏡像並發布到 IPNS 名稱 anoni-net，在 m6 上由 ubuntu 的 crontab 每天執行：
#
#   17 4 * * * /home/ubuntu/app/ipfs-mirror/repo/publish.sh
#
# 用法：
#   publish.sh                 組裝、上傳、發布。內容跟上次發布相同時安靜結束
#   publish.sh --no-upload     只在本機組裝到 $BASE/staging 並檢查，不連 kubo
#   publish.sh --stage         上傳並在 kubo 的 MFS 組成 /mirror-next，印出 CID，不發布
#   publish.sh --partial ...   搭配上面兩個選項，允許缺少某些區段（測試用，正式發布不接受）
#
# 四個區段來自各專案在 m6 上的 ipfs 產物，路徑可以用環境變數覆蓋。值也可以寫成 /ipfs/<CID>，
# 直接拿 kubo 上已有的內容當那個區段（測試或退回時用，只能搭配 --stage 或正式發布）：
#   SRC_ROOT     社群首頁 anoni-net/www，放在根目錄
#   SRC_DOCS     文件站 anoni-net/docs，放在 /docs/。沒有指定時從 S3 下載打包檔（DOCS_BUNDLE_URL）
#   SRC_NEWS     新聞導讀 anoni-net/news，放在 /news/
#   SRC_MYSTERY  隱私推理遊戲 anoni-net/privacy-mystery，放在 /mystery/
#
# kubo 在 digital_sg_1，不在 m6 上執行節點：IPFS 節點會把自己的 IP 公布在 DHT 上，m6 的位址
# 會因此曝光。m6 經 natsu 跳板開 SSH 通道連到 kubo 的 API（SSH 設定 digital_sg_1_kubo，金鑰只能
# 轉送這一個連接埠），ipfs 指令用 docker 裡的 kubo 映像當 client，只連通道，不啟動節點。
#
# 每個區段算一次內容雜湊，跟上次發布時相同就沿用上次的 CID，不重新上傳。上傳的區段先不 pin，
# 在 MFS 組成 /mirror-next，發布之後改名成 /mirror。MFS 裡的內容不會被 GC 清掉，舊版本等
# IPNS 的 ttl 過期才移除，避免閘道在 ttl 內解析到已經刪掉的舊 CID。
set -eu

BASE=${IPFS_MIRROR_BASE:-/home/ubuntu/app/ipfs-mirror}
LOG=${IPFS_MIRROR_LOG:-/home/ubuntu/ipfs-mirror.log}
SRC_ROOT=${SRC_ROOT:-/srv/anoni-net-www/current/ipfs}
# 文件站在 GitHub Actions 建置（anoni-net/docs 的 build_docs.yml 的 ipfs 那一格），打包放在 S3 的
# docs-ipfs/。沒有指定 SRC_DOCS 時，每次執行先下載到 $BASE/docs，見下方 fetch_docs
fetch_docs_enabled=0
[ -z "${SRC_DOCS:-}" ] && fetch_docs_enabled=1
SRC_DOCS=${SRC_DOCS:-$BASE/docs}
DOCS_BUNDLE_URL=${DOCS_BUNDLE_URL:-https://ooni-research.s3.ap-northeast-1.amazonaws.com/docs-ipfs/docs-ipfs.tar.gz}
SRC_NEWS=${SRC_NEWS:-/srv/anoni-net-news/ipfs}
SRC_MYSTERY=${SRC_MYSTERY:-/srv/anoni-net-mystery/current/ipfs}
SSH_HOST=${IPFS_SSH_HOST:-digital_sg_1_kubo}
PORT=${IPFS_TUNNEL_PORT:-15001}
# 跟 digital_sg_1 上的 kubo 同一個版本，升級時一起改
KUBO_IMAGE=${KUBO_IMAGE:-ipfs/kubo:v0.43.0}
KEY=anoni-net
IPNS=k51qzi5uqu5dlfm2jj0f70ex3r3babmwy8qh071inwknttr7wqa3uhdwvlmrmw
GATEWAY=https://ipfs.anoni.net
# 發布時的 --ttl 是 1 分鐘，再加一點緩衝才移除舊版本
GC_GRACE=${IPFS_GC_GRACE:-90}

mode=publish
partial=0
for arg in "$@"; do
    case "$arg" in
        --no-upload) mode=no-upload ;;
        --stage) mode=stage ;;
        --partial) partial=1 ;;
        *) echo "不認得的選項：$arg" >&2; exit 2 ;;
    esac
done
if [ "$partial" = 1 ] && [ "$mode" = publish ]; then
    echo "--partial 只能搭配 --no-upload 或 --stage" >&2
    exit 2
fi

mkdir -p "$BASE/state"
STATE=$BASE/state/sections
exec 9>"$BASE/state/lock"
flock -n 9 || { echo "上一輪還沒結束" >&2; exit 0; }
[ "$mode" = publish ] && [ -e "$BASE/hold" ] && exit 0

log() { echo "$(date -Iseconds) $*" >>"$LOG"; }
fail() { echo "$*" >&2; [ "$mode" = publish ] && log "$*"; exit 1; }

# 文件站的打包檔：先讀 .sha256，跟上次解開的相同就不再下載。下載完核對 sha256，對得上才解開並
# 換掉 $BASE/docs。走 S3 的 HTTPS 端點，物件是 public-read，不需要憑證。任何一步失敗都沿用
# 上一份，正式發布時那一輪的文件站就停在上一版，下一輪再試
note() { echo "$*"; [ "$mode" = publish ] && log "$*"; return 0; }
fetch_docs() {
    want=$(curl -fsS --max-time 30 "$DOCS_BUNDLE_URL.sha256" 2>/dev/null | cut -d' ' -f1) || want=""
    if [ -z "$want" ]; then
        note "讀不到文件站打包檔的 sha256，沿用上一份"
        return 0
    fi
    [ "$(cat "$BASE/state/docs-bundle" 2>/dev/null)" = "$want" ] && [ -f "$BASE/docs/index.html" ] && return 0
    tmp=$BASE/state/docs-bundle.tar.gz
    if ! curl -fsS --max-time 900 -o "$tmp" "$DOCS_BUNDLE_URL"; then
        note "文件站打包檔下載失敗，沿用上一份"
        rm -f "$tmp"; return 0
    fi
    if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$want" ]; then
        note "文件站打包檔的 sha256 對不上，沿用上一份"
        rm -f "$tmp"; return 0
    fi
    rm -rf "$BASE/docs.tmp"
    mkdir -p "$BASE/docs.tmp"
    if ! tar -xzf "$tmp" -C "$BASE/docs.tmp" || [ ! -f "$BASE/docs.tmp/index.html" ]; then
        note "文件站打包檔解不開或沒有 index.html，沿用上一份"
        rm -rf "$BASE/docs.tmp" "$tmp"; return 0
    fi
    rm -rf "$BASE/docs.old"
    [ -d "$BASE/docs" ] && mv "$BASE/docs" "$BASE/docs.old"
    mv "$BASE/docs.tmp" "$BASE/docs"
    rm -rf "$BASE/docs.old" "$tmp"
    echo "$want" >"$BASE/state/docs-bundle"
    note "更新文件站的產物（$(echo "$want" | cut -c1-12)）"
}
[ "$fetch_docs_enabled" = 1 ] && fetch_docs

# 區段名稱、掛載點、來源
SECTIONS="root:/:$SRC_ROOT docs:/docs:$SRC_DOCS news:/news:$SRC_NEWS mystery:/mystery:$SRC_MYSTERY"
field() { echo "$1" | cut -d: -f"$2"; }
src_of() { echo "$1" | cut -d: -f3-; }

ipfs() {
    docker run --rm -i --network host --entrypoint ipfs "$KUBO_IMAGE" --api "/ip4/127.0.0.1/tcp/$PORT" "$@"
}
ipfs_add_dir() {
    docker run --rm --network host -v "$1:/in:ro" --entrypoint ipfs "$KUBO_IMAGE" --api "/ip4/127.0.0.1/tcp/$PORT" \
        add -r --cid-version=1 --pin=false --quieter /in
}

# 目錄的內容雜湊（路徑加檔案內容），/ipfs/<CID> 的雜湊就是 CID 本身
tree_hash() {
    case "$1" in
        /ipfs/*) echo "${1#/ipfs/}" ;;
        *) (cd "$1" && find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-64 ;;
    esac
}

# 區段最上層的名稱，目錄加上結尾的 /
top_names() {
    case "$1" in
        /ipfs/*) ipfs ls --size=false "$1" | awk '{ $1 = ""; sub(/^ /, ""); print }' ;;
        *) (cd "$1" && for f in * .[!.]*; do [ -e "$f" ] || continue; if [ -d "$f" ]; then echo "$f/"; else echo "$f"; fi; done) ;;
    esac
}

need_tunnel=0
[ "$mode" != no-upload ] && need_tunnel=1

# 檢查來源
present=""
for s in $SECTIONS; do
    name=$(field "$s" 1); src=$(src_of "$s")
    case "$src" in
        /ipfs/*)
            [ "$mode" = no-upload ] && fail "$name：--no-upload 不能用 /ipfs/<CID> 當來源"
            present="$present $name" ;;
        *)
            if [ -f "$src/index.html" ]; then
                present="$present $name"
            elif [ "$partial" = 1 ]; then
                echo "略過 $name：$src 沒有 index.html"
            else
                fail "$name 的來源 $src 沒有 index.html，不發布"
            fi ;;
    esac
done
has() { case " $present " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
has root || fail "缺少根目錄（社群首頁），無法組裝"

TUNNEL_SOCK=$BASE/state/tunnel.sock
close_tunnel() { [ -S "$TUNNEL_SOCK" ] && ssh -S "$TUNNEL_SOCK" -O exit "$SSH_HOST" 2>/dev/null; return 0; }
if [ "$need_tunnel" = 1 ]; then
    rm -f "$TUNNEL_SOCK"
    ssh -f -N -M -S "$TUNNEL_SOCK" -o BatchMode=yes -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:$PORT:127.0.0.1:5001" "$SSH_HOST" || fail "無法建立到 $SSH_HOST 的通道"
    trap close_tunnel EXIT INT TERM
    i=0
    until ipfs id >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -ge 30 ] && fail "kubo 的 API 30 秒內沒有回應"
        sleep 1
    done
fi

# 根目錄不能有跟其他區段撞名的項目
ROOT_TOP=$(top_names "$SRC_ROOT")
for s in $SECTIONS; do
    name=$(field "$s" 1); mount=$(field "$s" 2)
    [ "$name" = root ] && continue
    echo "$ROOT_TOP" | grep -qx "${mount#/}/\?" && fail "根目錄已經有 ${mount#/}，跟 $name 區段撞名"
done

# _redirects：kubo 在找不到檔案時才套用，由上往下第一條比對到的生效，上限 64 KiB
REDIRECTS=$(mktemp)
trap 'rm -f "$REDIRECTS"; close_tunnel' EXIT INT TERM
{
    echo "# 由 anoni-net/ipfs-mirror 的 publish.sh 產生，不要手改"
    if has docs; then
        echo "/docs/en/*     /docs/en/404.html     404"
        echo "/docs/zh-cn/*  /docs/zh-cn/404.html  404"
        echo "/docs/*        /docs/404.html        404"
    fi
    if has news; then
        echo "/news/*        /news/404.html        404"
    fi
    if has docs; then
        # 2026-10 以前 ipfs.anoni.net 的根目錄是文件站，舊網址轉到 /docs/ 底下。跟社群首頁撞名的
        # 路徑顯示社群首頁，en 與 zh-cn 底下社群首頁沒有的頁面轉到文件站的同一頁
        echo "# 文件站搬到 /docs/ 之前的網址"
        top_names "$SRC_DOCS" | LC_ALL=C sort | while read -r n; do
            case "$n" in
                en/|zh-cn/) echo "/${n}*  /docs/${n}:splat  301" ;;
                index.html|404.html|_redirects|.*) ;;
                # kubo 比對前會拿掉結尾的斜線，目錄本身要另外一條
                *) if echo "$ROOT_TOP" | grep -qxF "$n"; then :; elif [ "${n%/}" != "$n" ]; then
                       echo "/${n%/}  /docs/$n  301"
                       echo "/${n}*  /docs/${n}:splat  301"
                   else
                       echo "/$n  /docs/$n  301"
                   fi ;;
            esac
        done
    fi
    echo "/*  /404.html  404"
} >"$REDIRECTS"
size=$(wc -c <"$REDIRECTS")
[ "$size" -lt 65536 ] || fail "_redirects 有 $size 位元組，超過 kubo 的 64 KiB 上限"

# 這次的內容指紋：各區段的雜湊加上 _redirects
hashes=""
for s in $SECTIONS; do
    name=$(field "$s" 1)
    has "$name" || continue
    hashes="$hashes$name $(tree_hash "$(src_of "$s")")
"
done
fingerprint=$(printf '%s%s' "$hashes" "$(sha256sum <"$REDIRECTS")" | sha256sum | cut -c1-64)

if [ "$mode" = no-upload ]; then
    out=$BASE/staging
    rm -rf "$out.tmp"
    for s in $SECTIONS; do
        name=$(field "$s" 1); mount=$(field "$s" 2); src=$(src_of "$s")
        has "$name" || continue
        dest="$out.tmp${mount%/}"
        mkdir -p "$(dirname "$dest")"
        cp -al "$src" "$dest" 2>/dev/null || cp -a "$src" "$dest"
    done
    cp "$REDIRECTS" "$out.tmp/_redirects"
    rm -rf "$out"
    mv "$out.tmp" "$out"
    echo "組裝在 $out（$(du -sh "$out" | cut -f1)），_redirects $(grep -cv '^#' "$out/_redirects") 條、$size 位元組"
    printf '%s' "$hashes"
    exit 0
fi

if [ "$mode" = publish ] && [ "$(sed -n 's/^fingerprint //p' "$STATE" 2>/dev/null)" = "$fingerprint" ]; then
    exit 0
fi

# 上傳有變動的區段，其他沿用上次發布時的 CID（那些區塊在 MFS 的 /mirror 裡，不會被 GC 清掉）
cids=""
for s in $SECTIONS; do
    name=$(field "$s" 1); src=$(src_of "$s")
    has "$name" || continue
    h=$(echo "$hashes" | sed -n "s/^$name //p")
    cid=$(awk -v n="$name" -v h="$h" '$1 == n && $2 == h { print $3 }' "$STATE" 2>/dev/null || true)
    if [ -z "$cid" ]; then
        case "$src" in
            /ipfs/*) cid=${src#/ipfs/} ;;
            *) cid=$(ipfs_add_dir "$src") || fail "$name 上傳失敗" ;;
        esac
        echo "上傳 $name：$cid"
    fi
    cids="$cids$name $h $cid
"
done
redirects_cid=$(ipfs add --cid-version=1 --pin=false --quieter <"$REDIRECTS") || fail "_redirects 上傳失敗"

ipfs files rm -r --force /mirror-next >/dev/null 2>&1 || true
for s in $SECTIONS; do
    name=$(field "$s" 1); mount=$(field "$s" 2)
    has "$name" || continue
    cid=$(echo "$cids" | awk -v n="$name" '$1 == n { print $3 }')
    target=/mirror-next${mount%/}
    ipfs files cp "/ipfs/$cid" "$target" || fail "MFS 組裝失敗：$name"
done
ipfs files cp "/ipfs/$redirects_cid" /mirror-next/_redirects || fail "MFS 組裝失敗：_redirects"
new=$(ipfs files stat --hash /mirror-next) || fail "讀不到 /mirror-next 的 CID"

if [ "$mode" = stage ]; then
    echo "組裝在 kubo 的 MFS /mirror-next：$new"
    echo "還沒有發布，正式的 /mirror 與 IPNS 都沒有變"
    exit 0
fi

old=$(ipfs name resolve "/ipns/$IPNS" 2>/dev/null || true)
old=${old#/ipfs/}
if [ "$old" = "$new" ]; then
    ipfs files rm -r --force /mirror-next >/dev/null 2>&1 || true
    exit 0
fi

# --lifetime=720h：IPNS record 在 DHT 上 30 天內有效。--ttl=1m：閘道快取解析結果 1 分鐘
ipfs name publish --key="$KEY" --lifetime=720h --ttl=1m "/ipfs/$new" >/dev/null || fail "IPNS 發布失敗，線上維持 $old"
ipfs routing provide "$new" >/dev/null 2>&1 || true
curl -fsS -o /dev/null --max-time 60 "$GATEWAY/" || true

# 舊版本等閘道的 IPNS 快取過期再移除
[ "$GC_GRACE" -gt 0 ] && sleep "$GC_GRACE"
ipfs files rm -r --force /mirror >/dev/null 2>&1 || true
ipfs files mv /mirror-next /mirror || log "/mirror-next 改名失敗，下一輪會重新組裝"
# 2026-10 以前文件站單獨發布時用的是 pin，第一次整站發布之後就不再有這種 pin
[ -n "$old" ] && ipfs pin rm "$old" >/dev/null 2>&1 || true
ipfs repo gc >/dev/null 2>&1 || true

{
    printf '%s' "$cids"
    echo "fingerprint $fingerprint"
    echo "published $new"
} >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"
log "發布 $new（$(echo "$cids" | awk 'NF { printf "%s%s", sep, $1; sep = "、" }')）"
