#!/usr/bin/env bash
# 在 gy-006 的 Buildkite agent pod 里跑 squid 主套件
# （等价于 .github/workflows/test-squid.yaml 的各 job）。
#
# 与 test-squid.yaml 的差别只有一点：结果落 sfs 共享盘 —— container-0 里没有
# buildkite-agent 二进制，传不了 Buildkite artifacts；TSV 同时打到日志，跑完可
# 从 /root/.cache 取原始证据。
#
# 套件仓库用 github 原址克隆即可：gy-006 的 pod postStart 已配
#   url."http://git-cdn-service.../".insteadOf "https://github.com/"
# （见部署仓 other/ascend-gha-runners/vllm-omni/linux-aarch64-a2b3-gy006/values.yaml），
# 实际仍走集群内 git-cdn，脚本不硬编码内网地址。
#
# 关键前提：这里【不配置任何代理】。HTTP(S)_PROXY / NO_PROXY / CA 信任变量
# 都由部署仓 other/ascend-gha-runners/vllm-omni/linux-aarch64-a2b3-gy006/values.yaml
# 通过 pod-spec-patch 注入，这就是被测对象本身。
#
# 用法：
#   bash .buildkite/scripts/run_squid_suite.sh                  # 默认 function
#   bash .buildkite/scripts/run_squid_suite.sh function
#   bash .buildkite/scripts/run_squid_suite.sh concurrency cabundle
#
# 可覆盖环境变量：
#   SUITE_REPO_URL  套件仓库地址（默认集群内 git-cdn）
#   SUITE_REF       套件分支/标签（默认 main；验证未合并的套件 PR 时指向该分支）
#   SUITE_DIR       克隆落地目录
#   RESULTS_ROOT    结果根目录（默认 /root/.cache/squid-suite，落在共享盘）
set -uo pipefail

SUITE_REPO_URL="${SUITE_REPO_URL:-https://github.com/ascend-gha-runners/squid-gha-integration-test.git}"
SUITE_DIR="${SUITE_DIR:-/tmp/squid-suite-src}"
SUITE_REF="${SUITE_REF:-main}"
RESULTS_ROOT="${RESULTS_ROOT:-/root/.cache/squid-suite}"

MODES=("$@")
[ "${#MODES[@]}" -eq 0 ] && MODES=(function)

echo "### 准备：克隆套件仓库"
echo "repo=${SUITE_REPO_URL} ref=${SUITE_REF}"
rm -rf "$SUITE_DIR"
if ! git clone --depth 1 --branch "$SUITE_REF" "$SUITE_REPO_URL" "$SUITE_DIR"; then
    echo "❌ 克隆失败，检查 git-cdn 是否可达（该域应在 NO_PROXY 里直连）"
    exit 1
fi
echo "✅ 克隆完成：$(git -C "$SUITE_DIR" rev-parse --short HEAD)"

rc_total=0
for mode in "${MODES[@]}"; do
    export RESULTS_DIR="$RESULTS_ROOT/$mode-$(date +%s)"
    mkdir -p "$RESULTS_DIR"

    echo
    echo "### 模式 $mode"
    echo "results=${RESULTS_DIR}"
    bash "$SUITE_DIR/test-squid/run-suite.sh" --mode "$mode"
    rc=$?

    if [ -s "$RESULTS_DIR/timings.tsv" ]; then
        echo "--- timings.tsv（$mode）"
        cat "$RESULTS_DIR/timings.tsv"
        fails=$(awk -F'\t' 'NR>1 && $3=="1"' "$RESULTS_DIR/timings.tsv" | wc -l)
        echo "FAIL 阶段数：${fails}"
    else
        echo "⚠️ 没有产出 timings.tsv（$RESULTS_DIR）"
    fi

    # 失败时把各阶段日志尾部打进构建日志：container-0 没有 artifact 通道，
    # 而套件默认只打印判定行，真实报错（如 wget 的 TLS/CONNECT 错误）在 .log 里。
    if [ "$rc" -ne 0 ]; then
        for f in "$RESULTS_DIR"/*/*.log; do
            [ -f "$f" ] || continue
            echo "--- 日志尾部：$(basename "$f")"
            tail -n 15 "$f" | sed 's/^/    | /'
        done
    fi

    if [ "$rc" -ne 0 ]; then
        echo "❌ 模式 $mode 非零退出（rc=$rc）"
        rc_total=1
    else
        echo "✅ 模式 $mode 通过"
    fi
done

echo
echo "### 结论"
if [ "$rc_total" -eq 0 ]; then
    echo "✅ 全部模式通过：${MODES[*]}"
else
    echo "❌ 存在失败模式：${MODES[*]}（原始证据在 $RESULTS_ROOT）"
fi
exit "$rc_total"
