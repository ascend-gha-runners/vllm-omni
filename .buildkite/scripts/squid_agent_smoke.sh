#!/usr/bin/env bash
# 目的：在 vllm-omni 的 Buildkite agent pod 里，零配置验证 squid 注入与缓存收益。
#
# 关键前提：这里**不配置任何代理**。HTTP(S)_PROXY / NO_PROXY / CA 信任环境变量
# 都由部署仓 ascend-ci-deployment 的
#   other/ascend-gha-runners/vllm-omni/linux-aarch64-a2b3-gy006/values.yaml
# 通过 pod-spec-patch 注入，这就是被测对象本身。脚本自配代理即失去验证意义。
#
# 判定口径：
#   ❌ = 失败（退出码 1）：代理 env 缺失、https 因证书失败、无 squid 专属痕迹
#   ⚠️ = 只记录（不影响结论）：无法缓存的对象 / 未呈现 MISS→HIT
set -uo pipefail

# 默认取 huaweicloud ubuntu-ports 的静态对象：aarch64 可达、可缓存、
# 且不受 gy-006 git insteadOf（只重写 git 协议）影响。
URL_SMALL="${URL_SMALL:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/Release}"
URL_MED="${URL_MED:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/main/binary-arm64/Packages.gz}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/squid-smoke}"
mkdir -p "$RESULTS_DIR"

rc=0
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
bad()  { echo "❌ $*"; rc=1; }

echo "### 阶段 0：环境快照（只读，不配置任何东西）"
{
    echo "arch=$(uname -m)"
    echo "host=${HOSTNAME:-unknown}"
    echo "HTTP_PROXY=${HTTP_PROXY:-}"
    echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
    echo "http_proxy=${http_proxy:-}"
    echo "https_proxy=${https_proxy:-}"
    echo "NO_PROXY=${NO_PROXY:-}"
    echo "SSL_CERT_FILE=${SSL_CERT_FILE:-}"
    echo "CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-}"
} | tee "$RESULTS_DIR/env.txt"
command -v curl >/dev/null 2>&1 || { bad "agent 里没有 curl，无法执行连通性检查"; exit $rc; }
curl --version | head -1

echo
echo "### 阶段 1：代理 env 注入生效性"
if [ -n "${HTTP_PROXY:-}" ] && [ -n "${HTTPS_PROXY:-}" ] \
   && { echo "${HTTP_PROXY}" | grep -q 'squid'; } \
   && { echo "${HTTPS_PROXY}" | grep -q 'squid'; }; then
    ok "HTTP(S)_PROXY 已指向 squid（pod-spec-patch 注入生效）"
else
    bad "HTTP(S)_PROXY 缺失或未指向 squid —— 该 runner 的 squid 注入未生效"
fi

echo
echo "### 阶段 2：CA 信任形态（MITM 生效的必要条件）"
if [ -n "${SSL_CERT_FILE:-}" ] && [ -r "${SSL_CERT_FILE}" ]; then
    n=$(grep -c 'BEGIN CERTIFICATE' "$SSL_CERT_FILE" 2>/dev/null || echo 0)
    if [ "${n:-0}" -ge 2 ]; then
        ok "SSL_CERT_FILE=${SSL_CERT_FILE} 存在且含 ${n} 张证书（bundle = 系统根 + squid CA）"
    else
        bad "SSL_CERT_FILE=${SSL_CERT_FILE} 只有 ${n} 张证书，疑似纯 squid CA（NO_PROXY 直连域会 TLS 失败）"
    fi
else
    bad "SSL_CERT_FILE 未设置或不可读（${SSL_CERT_FILE:-unset}）"
fi

echo
echo "### 阶段 3：https 经 squid MITM（curl 不加 -k，证书错就失败）"
if code=$(curl -sS --max-time 60 -o "$RESULTS_DIR/small.out" -w '%{http_code}' "$URL_SMALL" 2>"$RESULTS_DIR/small.err"); then
    if [ "$code" = "200" ] && [ -s "$RESULTS_DIR/small.out" ]; then
        ok "https GET $URL_SMALL → 200（MITM CA 链有效）"
    else
        bad "https GET $URL_SMALL → ${code}，响应体为空或非 200"
    fi
else
    bad "https GET $URL_SMALL 失败：$(tr '\n' ' ' < "$RESULTS_DIR/small.err")"
fi

echo
echo "### 阶段 4：squid 专属痕迹（证明流量确实经过 squid）"
curl -sS -L --max-time 60 -o /dev/null -D "$RESULTS_DIR/small.headers" "$URL_SMALL" || true
if grep -qiE '^cache-status:.*squid|^x-cache-lookup:|^x-squid-error:|^via:.*squid' "$RESULTS_DIR/small.headers"; then
    ok "响应头带 squid 专属痕迹：$(grep -iE '^cache-status:|^x-cache-lookup:|^via:' "$RESULTS_DIR/small.headers" | tr -d '\r' | tr '\n' ' ')"
else
    bad "响应头无 squid 专属痕迹 —— 流量未经过 squid（若 Via/X-Cache 来自其他缓存层，属假阳性）"
fi

echo
echo "### 阶段 5：缓存 MISS→HIT（同对象二连发）"
fetch() {
    local out="$1" hdr="$2" t0 ms
    t0=$(date +%s)
    curl -sS -L --max-time 180 -o "$out" -D "$hdr" "$URL_MED" || return 1
    ms=$(( $(date +%s) - t0 ))
    echo "$ms"
}
if ms1=$(fetch "$RESULTS_DIR/med1.bin" "$RESULTS_DIR/med1.hdr"); then
    if ms2=$(fetch "$RESULTS_DIR/med2.bin" "$RESULTS_DIR/med2.hdr"); then
        s1=$(grep -iE '^(cache-status|x-cache-lookup):' "$RESULTS_DIR/med1.hdr" | tail -1 | tr -d '\r' || true)
        s2=$(grep -iE '^(cache-status|x-cache-lookup):' "$RESULTS_DIR/med2.hdr" | tail -1 | tr -d '\r' || true)
        echo "第一发 ${ms1}s: ${s1:-无缓存头}"
        echo "第二发 ${ms2}s: ${s2:-无缓存头}"
        if echo "$s2" | grep -qiE 'detail=hit|x-cache-lookup:.*hit'; then
            ok "MISS→HIT 闭环成立（${ms1}s → ${ms2}s）"
        elif [ -z "${s1}${s2}" ]; then
            warn "响应无 Cache-Status/X-Cache 头（对象不可缓存或缓存头被抑制）——只记录，不判失败"
        else
            warn "未呈现 MISS→HIT（${s1:-无} → ${s2:-无}）——只记录，不判失败"
        fi
        sha1=$(sha256sum "$RESULTS_DIR/med1.bin" | cut -d' ' -f1)
        sha2=$(sha256sum "$RESULTS_DIR/med2.bin" | cut -d' ' -f1)
        [ "$sha1" = "$sha2" ] && ok "两发内容 sha256 一致（${sha1}）" || bad "两发内容 sha256 不一致（${sha1} vs ${sha2}，缓存内容损坏）"
    else
        bad "第二次下载失败"
    fi
else
    bad "第一次下载失败"
fi

echo
echo "### 结论"
if [ "$rc" -eq 0 ]; then
    ok "该 runner 的 squid 注入可用（env + CA + 痕迹 + 缓存一致性）"
else
    bad "存在失败项，请查看上面 ❌ 行与 $RESULTS_DIR 内证据文件"
fi
exit "$rc"
