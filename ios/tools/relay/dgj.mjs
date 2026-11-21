// 接口 v2（一叶笺 ⇄ 大管家 走 Cloudflare 信箱）的 Node 版两头工具：加解密、信封、连信箱。
// 假掌机（fake_butler.mjs）和手机探针（phone_probe.mjs）共用；Node 22 自带 fetch、WebSocket、WebCrypto，不用装包。
// 格式照 ios/docs/大管家接口.md 的 v2 一节：AES-256-GCM，nonce(12) ‖ 密文 ‖ tag(16)，附加数据「yiye-dgj/2/<信箱号>/<收信的一方>」。

export const DEFAULT_RELAY = 'https://luruseng-relay.lunzigeju.workers.dev';
const te = new TextEncoder();
const td = new TextDecoder();

export const b64url = (u8) => Buffer.from(u8).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const unb64url = (s) => new Uint8Array(Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
export const iso = (d = new Date()) => {
  const off = -d.getTimezoneOffset();
  const p = (n) => String(Math.floor(Math.abs(n))).padStart(2, '0');
  const local = new Date(d.getTime() + off * 60000).toISOString().slice(0, 19);
  return `${local}${off >= 0 ? '+' : '-'}${p(off / 60)}:${p(off % 60)}`;
};

/** 新配一对：信箱号 16 字节随机（32 个十六进制字），钥匙 32 字节随机（base64url） */
export function newPairing(relay = DEFAULT_RELAY, host = '假掌机') {
  const box = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex');
  return { v: 2, relay, box, key: b64url(crypto.getRandomValues(new Uint8Array(32))), host, at: iso() };
}

export function checkPairing(p) {
  if (!p || p.v !== 2 || !/^[0-9a-f]{32}$/.test(p.box || '') || unb64url(p.key || '').length !== 32 || !/^https?:\/\//.test(p.relay || '')) {
    throw new Error('配对不对：' + JSON.stringify(p));
  }
  return p;
}

export async function seal(p, to, obj) {
  const key = await crypto.subtle.importKey('raw', unb64url(p.key), 'AES-GCM', false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: te.encode(`yiye-dgj/2/${p.box}/${to}`) }, key, te.encode(JSON.stringify(obj))));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv);
  out.set(ct, 12);
  return out;
}

export async function open(p, me, bytes) {
  const key = await crypto.subtle.importKey('raw', unb64url(p.key), 'AES-GCM', false, ['decrypt']);
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12), additionalData: te.encode(`yiye-dgj/2/${p.box}/${me}`) }, key, bytes.slice(12));
  const env = JSON.parse(td.decode(pt));
  if (env.v !== 2) throw new Error('接口版本不对：' + env.v);
  return env;
}

/** 一头：role 'pc'（掌机）或 'phone'（手机） */
export class End {
  constructor(p, role) {
    this.p = checkPairing(p);
    this.role = role;
    this.peer = role === 'pc' ? 'phone' : 'pc';
    this.base = p.relay.replace(/\/+$/, '') + `/dgj/${p.box}`;
  }

  async send(kind, data, files = {}) {
    const env = { v: 2, kind, id: data.id, at: data.at || iso(), data };
    const f = Object.fromEntries(Object.entries(files).map(([k, v]) => [k, Buffer.from(v).toString('base64')]));
    if (Object.keys(f).length) env.files = f;
    const body = await seal(this.p, this.peer, env);
    const r = await fetch(`${this.base}/msg?to=${this.peer}&mid=${encodeURIComponent(data.id)}`, { method: 'PUT', body });
    const j = await r.json().catch(() => ({}));
    if (r.status !== 200) throw new Error(`寄不出去：${r.status} ${JSON.stringify(j)}`);
    return { ...j, bytes: body.length };
  }

  async take(item) {
    let bytes;
    if (item.data) bytes = new Uint8Array(Buffer.from(item.data, 'base64'));
    else {
      const r = await fetch(`${this.base}/msg/${item.seq}`);
      if (r.status !== 200) throw new Error(`取不到 ${item.seq}：${r.status}`);
      bytes = new Uint8Array(await r.arrayBuffer());
    }
    return open(this.p, this.role, bytes);
  }

  async ack(seq) {
    if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify({ t: 'ack', seq }));
    else await fetch(`${this.base}/msg/${seq}`, { method: 'DELETE' });
  }

  /** 连上信箱；onPush(消息, 到的毫秒)。keepAlive：掌机发 "ping"（自动回 pong，不算额度） */
  connect(onPush, keepAlive = 'ping', every = 30000) {
    return new Promise((ok, bad) => {
      const ws = new WebSocket(this.base.replace(/^http/, 'ws') + `/ws?as=${this.role}`);
      this.ws = ws;
      ws.onmessage = (e) => {
        const at = Date.now();
        if (e.data === 'pong') return;
        let m;
        try { m = JSON.parse(e.data); } catch (err) { return; }
        if (m.t === 'hello') ok(m);
        onPush(m, at);
      };
      ws.onerror = (e) => bad(new Error('连不上信箱：' + (e.message || e.type)));
      this.timer = setInterval(() => { if (ws.readyState === 1) ws.send(keepAlive); }, every);
      ws.onclose = () => clearInterval(this.timer);
    });
  }

  close() { clearInterval(this.timer); try { this.ws?.close(); } catch (e) { /* 已经关了 */ } }
}
