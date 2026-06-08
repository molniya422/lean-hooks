#!/usr/bin/env bash
# Test script for multiagent-detect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PY="${PY:-python3}"
SCRIPT="$SCRIPT_DIR/multiagent-detect.sh"

trigger_tests=(
    '帮我并行审查这3个文件'
    '清理playwright，同时修改multiagent逻辑'
    '你找找前面的记忆，另外找一个叫browseract的skill，分析它的功能'
    '降低阈值，同时看看有没有新的识别模式能改善触发，另外看看这个https://example.com，并对比https://github.com/browser-act/，修改完multiagent之后自动测试'
    '找文件，修bug，写测试，同时部署'
    '看看A怎么回事，另外也看看B'
    '改完代码之后测试一下，再对比一下结果'
)

no_trigger_tests=(
    '你好'
    '今天天气怎么样'
    '帮我写一个hello world'
    '谢谢'
    '怎么用git commit？'
)

echo "=== TRIGGER TESTS (must output additionalContext) ==="
trigger_pass=0
trigger_fail=0
for t in "${trigger_tests[@]}"; do
    out=$(printf '{"prompt":"%s"}\n' "$t" | bash "$SCRIPT")
    if echo "$out" | grep -q '"additionalContext"'; then
        echo "  PASS: $t"
        trigger_pass=$((trigger_pass + 1))
    else
        echo "  FAIL: $t"
        echo "    output: $out"
        trigger_fail=$((trigger_fail + 1))
    fi
done

echo ""
echo "=== NO-TRIGGER TESTS (must NOT output additionalContext) ==="
no_trigger_pass=0
no_trigger_fail=0
for t in "${no_trigger_tests[@]}"; do
    out=$(printf '{"prompt":"%s"}\n' "$t" | bash "$SCRIPT")
    if echo "$out" | grep -q '"additionalContext"'; then
        echo "  FAIL (false positive): $t"
        echo "    output: $out"
        no_trigger_fail=$((no_trigger_fail + 1))
    else
        echo "  PASS: $t"
        no_trigger_pass=$((no_trigger_pass + 1))
    fi
done

echo ""
echo "=== SUMMARY ==="
echo "Trigger tests: $trigger_pass passed, $trigger_fail failed"
echo "No-trigger tests: $no_trigger_pass passed, $no_trigger_fail failed"
total_pass=$((trigger_pass + no_trigger_pass))
total_fail=$((trigger_fail + no_trigger_fail))
echo "Total: $total_pass passed, $total_fail failed"
exit $total_fail
