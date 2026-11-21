#!/usr/bin/env node
// 假掌机（施工单 065 验收用）：照接口 v2 连信箱（as=pc），收到理顺请求就回一个结果。不叫大脑，只量时间。
//   node fake_butler.mjs pair [relay]            → 打一份新配对（JSON 一行）
//   node fake_butler.mjs run '<配对 JSON>' [N]   → 连上信箱等请求，回满 N 个就退（不给 N 就一直等）
// 时间写进结果的 changes：fake|got=<收到推送的毫秒>|sent=<开始回信的毫秒>|bytes=<请求多大>
import { End, newPairing, iso, DEFAULT_RELAY } from './dgj.mjs';

const [cmd, a1, a2] = process.argv.slice(2);
if (cmd === 'pair') {
  console.log(JSON.stringify(newPairing(a1 || DEFAULT_RELAY)));
  process.exit(0);
}
if (cmd !== 'run' || !a1) {
  console.error('用法：fake_butler.mjs pair [relay] | run <配对 JSON> [N]');
  process.exit(2);
}

const end = new End(JSON.parse(a1), 'pc');
const want = Number(a2 || 0);
let done = 0;
const seen = new Set();

async function handle(item, got) {
  if (item.to !== 'pc' || seen.has(item.seq)) return;
  seen.add(item.seq);
  try {
    const env = await end.take(item);
    if (env.kind !== 'request') { await end.ack(item.seq); return; }
    const r = env.data;
    const sent = Date.now();
    const text = String(r.text || '').replace(/128O/g, '1280').replace(/□班/g, '早班');
    await end.send('result', {
      v: 1, id: r.id, note: r.note, ok: true, text, changes: `fake|got=${got}|sent=${sent}|bytes=${item.size}`,
      error: null, model: 'fake-butler', at: iso(),
    });
    await end.ack(item.seq);
    done += 1;
    console.log(`${new Date().toISOString()} 回了 ${r.id.slice(0, 8)}（${item.size} 字节，带图 ${Object.keys(env.files || {}).length} 张）收到→回信 ${Date.now() - got} ms`);
    if (want && done >= want) setTimeout(() => { end.close(); process.exit(0); }, 500);
  } catch (e) {
    console.log(`${new Date().toISOString()} 出错 ${item.seq}：${e.message}`);
  }
}

const hello = await end.connect((m, at) => {
  if (m.t === 'msg') handle(m.item, at);
}, 'ping', 30000);
console.log(`${new Date().toISOString()} 假掌机连上了 ${end.base}，攒着的 ${hello.items.length} 封`);
for (const it of hello.items) handle(it, Date.now());
process.on('SIGTERM', () => { end.close(); process.exit(0); });
