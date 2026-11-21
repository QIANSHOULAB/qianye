#!/bin/bash
# 信箱端到端（施工单 065 验收）：挑信箱 → 假掌机连上 → 手机这头（YiyeKit 的 LiveRelayTests，用的就是 app 里那套 MailClient + MailSocket）
# 来回 ROUNDS 次（默认 10）→ 每段列时间。CI 的 ios-relay.yml 跑它；本机有 Xcode 也能跑：bash ios/tools/relay/e2e.sh
# 线上 luruseng-relay 已经有 /dgj 就对着线上；还没有，就在这台机器上起一个 wrangler dev（luruseng-relay 打上同一目录的补丁）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
ROUNDS="${ROUNDS:-10}"
LIVE="${LIVE_RELAY:-https://luruseng-relay.lunzigeju.workers.dev}"
WORK="${RUNNER_TEMP:-/tmp}/yiye-relay-e2e"
rm -rf "${WORK}" && mkdir -p "${WORK}"
cleanup() {
  [ -n "${FAKE:-}" ] && kill "${FAKE}" 2>/dev/null || true
  if [ -f "${WORK}/dev.pid" ]; then pkill -f "wrangler dev --ip 127.0.0.1 --port 8787" 2>/dev/null || true; pkill -f workerd 2>/dev/null || true; fi
}
trap cleanup EXIT

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${LIVE}/dgj/00000000000000000000000000000000/state" || true)
if [ "${code}" = "200" ]; then
  RELAY="${LIVE}"
  WHERE="线上信箱 ${LIVE}"
else
  echo "线上还没有 /dgj（回 ${code}）：在这台机器上起一个 wrangler dev"
  git clone -q https://github.com/QIANSHOULAB/luruseng-relay "${WORK}/relay"
  cd "${WORK}/relay"
  grep -q "dgj" src/index.js || git apply "${HERE}/luruseng-relay-dgj.patch"
  npm ci --silent --no-audit --no-fund
  WRANGLER_SEND_METRICS=false CI=1 npx wrangler dev --ip 127.0.0.1 --port 8787 > "${WORK}/dev.log" 2>&1 &
  echo $! > "${WORK}/dev.pid"
  for i in $(seq 1 180); do curl -s --max-time 2 http://127.0.0.1:8787/ping >/dev/null && break; sleep 0.5; done
  curl -s http://127.0.0.1:8787/ping
  RELAY="http://127.0.0.1:8787"
  WHERE="本机 wrangler dev（luruseng-relay $(git rev-parse --short HEAD) + 065 补丁）"
  cd "${ROOT}"
fi
echo "信箱：${WHERE}"

P=$(node "${HERE}/fake_butler.mjs" pair "${RELAY}")
node "${HERE}/fake_butler.mjs" run "${P}" "${ROUNDS}" > "${WORK}/fake.log" 2>&1 &
FAKE=$!
sleep 2

cd "${ROOT}/ios/YiyeKit"
set +e
YIYE_LIVE_PAIRING="${P}" YIYE_LIVE_ROUNDS="${ROUNDS}" YIYE_LIVE_REPORT="${WORK}/report.md" swift test --filter LiveRelayTests 2>&1 | tail -40
rc=${PIPESTATUS[0]}
set -e
echo "---- 假掌机"
cat "${WORK}/fake.log" || true
echo "---- 每段时间（毫秒）：${WHERE}"
cat "${WORK}/report.md" 2>/dev/null || echo "（没出表）"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## 信箱来回 ${ROUNDS} 次：${WHERE}"; echo; cat "${WORK}/report.md" 2>/dev/null || echo "（没出表）"; } >> "${GITHUB_STEP_SUMMARY}"
fi
[ -f "${WORK}/report.md" ] || rc=1
exit ${rc}
