#!/usr/bin/env node
// 手机探针（Node 版，跟 YiyeKit 的 LiveRelayTests 做同样的事）：连信箱（as=phone），交 N 个请求，等大管家（或假掌机）回，每一段列时间。
//   node phone_probe.mjs '<配对 JSON>' [N] [photo|text|speak]
// photo（默认）：理顺请求，带一张 400KB 的图；text：理顺请求，只有字；speak：配音请求（等「送来」带 request，或者 ok=false 的结果）。
// 对面是 fake_butler.mjs 时，它把自己那头的时间写在 changes 里（fake|got=…|sent=…），表里多两段；真掌机没有就只列总的。
import { End, iso } from './dgj.mjs';

const end = new End(JSON.parse(process.argv[2]), 'phone');
const n = Number(process.argv[3] || 10);
const kind = process.argv[4] || 'photo';
const waiters = new Map();

const hello = await end.connect(async (m, at) => {
  if (m.t !== 'msg' || m.item.to !== 'phone') return;
  let env;
  try { env = await end.take(m.item); } catch (e) { console.log(`拆不开 ${m.item.seq}：${e.message}`); return; }
  const opened = Date.now();
  const key = env.kind === 'delivery' ? env.data.request : env.data.id;
  const w = waiters.get(key);
  if (!w) return;                     // 不是这回等的（攒着的旧信）：不动它
  await end.ack(m.item.seq);
  w({ env, at, opened, item: m.item });
}, JSON.stringify({ t: 'state' }), 30000);
if (!hello.pc) { console.error('大管家没连上信箱（hello.pc=false）'); process.exit(1); }

const rows = [];
for (let i = 1; i <= n; i++) {
  const id = crypto.randomUUID().toUpperCase();
  const files = {};
  const req = { v: 1, id, note: crypto.randomUUID().toUpperCase(), kind: kind === 'photo' ? 'photo' : 'text', ask: kind === 'speak' ? 'speak' : 'fix', at: iso(), app: 'probe' };
  if (kind === 'photo') {
    req.text = `第 ${i} 条：A线早班 128O件`;
    req.images = ['附件/T-原图-1.jpg'];
    req.unsure = ['128O件'];
    files['附件/T-原图-1.jpg'] = new Uint8Array(400_000).map((_, k) => (k * 31 + i) & 255);
  } else if (kind === 'text') {
    req.text = `第${i}条 今天早班A线做了128O件，晚班记得加冷却夜`;
  } else {
    req.text = `# Probe ${i}\nThe butler reads this line out loud. That is all.`;
  }
  const back = new Promise((ok, bad) => { waiters.set(id, ok); setTimeout(() => bad(new Error(`${id.slice(0, 8)} 120 秒没回`)), 120000); });
  const t0 = Date.now();
  const s = await end.send('request', req, files);
  const t1 = Date.now();
  let got;
  try { got = await back; } catch (e) { rows.push({ i, bytes: s.bytes, put: t1 - t0, err: e.message }); continue; }
  const { env, at: t4, opened: t5 } = got;
  const kv = Object.fromEntries(String(env.data.changes || '').split('|').map((x) => x.split('=')).filter((x) => x.length === 2));
  const t2 = Number(kv.got), t3 = Number(kv.sent);
  const ok = env.kind === 'delivery' ? !!(env.files && env.data.audio && env.files[env.data.audio]) : env.data.ok === true;
  rows.push({ i, bytes: s.bytes, put: t1 - t0, toButler: t2 ? t2 - t0 : null, butler: t2 && t3 ? t3 - t2 : null, back: t3 ? t4 - t3 : null,
    open: t5 - t4, total: t5 - t0, ok, what: env.kind === 'delivery' ? `送来 ${env.data.audio}` : (env.data.ok ? (env.data.changes || '').slice(0, 40) : `ok=false：${env.data.error}`) });
}
end.close();
const f = (x) => (x === null || x === undefined || Number.isNaN(x) ? '—' : x);
const q = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.max(0, Math.ceil(p * s.length) - 1))]; };
console.log(`| # | 请求（加密后，字节） | 交出去：加密+PUT | 交出去→掌机收到 | 掌机拆信+办+回信 | 回信→手机收到推送 | 手机拆开 | 合计 | 对 | 回的 |`);
console.log('|---|---|---|---|---|---|---|---|---|---|');
for (const r of rows) {
  if (r.err) { console.log(`| ${r.i} | ${r.bytes} | ${r.put} | — | — | — | — | — | 否 | ${r.err} |`); continue; }
  console.log(`| ${r.i} | ${r.bytes} | ${r.put} | ${f(r.toButler)} | ${f(r.butler)} | ${f(r.back)} | ${r.open} | ${r.total} | ${r.ok ? '是' : '否'} | ${r.what} |`);
}
const tot = rows.filter((r) => !r.err).map((r) => r.total);
if (tot.length) console.log(`\n合计（毫秒）：最快 ${Math.min(...tot)}，中位 ${q(tot, 0.5)}，p90 ${q(tot, 0.9)}，最慢 ${Math.max(...tot)}；${rows.filter((r) => r.ok).length}/${rows.length} 对`);
process.exit(rows.every((r) => r.ok) ? 0 : 1);
