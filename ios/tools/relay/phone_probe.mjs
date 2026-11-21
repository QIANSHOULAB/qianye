#!/usr/bin/env node
// 手机探针（Node 版，跟 YiyeKit 的 LiveRelayTests 做同样的事）：连信箱（as=phone），交 N 个理顺请求（带一张 400KB 的图），
// 等假掌机回结果，每一段列时间。
//   node phone_probe.mjs '<配对 JSON>' [N]
import { End, iso } from './dgj.mjs';

const end = new End(JSON.parse(process.argv[2]), 'phone');
const n = Number(process.argv[3] || 10);
const waiters = new Map();
const hello = await end.connect((m, at) => {
  if (m.t === 'msg' && waiters.has(m.item.mid)) waiters.get(m.item.mid)(m.item, at);
}, JSON.stringify({ t: 'state' }), 30000);
if (!hello.pc) { console.error('假掌机没连上信箱'); process.exit(1); }

const rows = [];
for (let i = 1; i <= n; i++) {
  const id = crypto.randomUUID().toUpperCase();
  const img = new Uint8Array(400_000).map((_, k) => (k * 31 + i) & 255);
  const req = { v: 1, id, note: crypto.randomUUID().toUpperCase(), kind: 'photo', text: `第 ${i} 条：A线早班 128O件`, images: ['附件/T-原图-1.jpg'], unsure: ['128O件'], ask: 'fix', at: iso(), app: 'probe' };
  const back = new Promise((ok, bad) => { waiters.set(id, (item, at) => ok({ item, at })); setTimeout(() => bad(new Error('20 秒没回')), 20000); });
  const t0 = Date.now();
  const s = await end.send('request', req, { '附件/T-原图-1.jpg': img });
  const t1 = Date.now();
  const { item, at: t4 } = await back;
  const env = await end.take(item);
  const t5 = Date.now();
  await end.ack(item.seq);
  const kv = Object.fromEntries(String(env.data.changes).split('|').map((x) => x.split('=')).filter((x) => x.length === 2));
  const t2 = Number(kv.got), t3 = Number(kv.sent);
  rows.push({ i, bytes: s.bytes, put: t1 - t0, toButler: t2 - t0, butler: t3 - t2, back: t4 - t3, open: t5 - t4, total: t5 - t0, ok: env.data.text.includes('1280') });
}
end.close();
const q = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)]; };
console.log('| # | 请求（加密后） | 交出去：加密+PUT | 交出去→假掌机收到 | 假掌机拆信+回信 | 回信→手机收到推送 | 手机拆开 | 合计 | 对 |');
console.log('|---|---|---|---|---|---|---|---|---|');
for (const r of rows) console.log(`| ${r.i} | ${r.bytes} | ${r.put} | ${r.toButler} | ${r.butler} | ${r.back} | ${r.open} | ${r.total} | ${r.ok ? '是' : '否'} |`);
const tot = rows.map((r) => r.total);
console.log(`\n合计（毫秒）：最快 ${Math.min(...tot)}，中位 ${q(tot, 0.5)}，p90 ${q(tot, 0.9)}，最慢 ${Math.max(...tot)}；${rows.filter((r) => r.ok).length}/${rows.length} 对`);
