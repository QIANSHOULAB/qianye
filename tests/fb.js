// 0.3.5 提意见入口：node tests/fb.js
// 中文、英文各开一遍（英文那遍浏览器语言故意给 zh-CN，中文那遍点右上角「中文」再刷新），手机 390、电脑 1280：
// 页脚一个「提意见」、设置（齿轮）里一个「提意见」。点它：在 window 的捕获阶段拦下 mailto 导航（不真去开邮件程序），
// 核对收件人、标题、正文（三行提示 + 最后一行「版本 · 系统 · 浏览器」）。另外拿一组 UA 喂 fbDevice()，看系统、浏览器的简写对不对。
// 截图（手机那遍）：docs/shots-fb/<zh|en>_390_<foot|set>.png；结果 docs/shots-fb/fb.json。
'use strict';
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'docs', 'shots-fb');
const STR = require(path.join(ROOT, 'strings.js'));
const VER = (fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8').match(/const VERSION = '([\d.]+)'/) || [])[1];
const TO = 'oilsongchengmin@gmail.com';
const EXP = {
  zh: { subject: `[千手院反馈] 一叶笺 ${VER}`, lines: ['哪里不好用：', '', '想要什么：', '', '别的：', '', '', '——'], text: '提意见', locale: 'en-US' },
  en: { subject: `[QIANSHOU feedback] Yiye · Pretty Notes ${VER}`, lines: ['What’s not working:', '', 'What you want:', '', 'Anything else:', '', '', '—'], text: 'Feedback', locale: 'zh-CN' },
};
const UAS = [
  ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36', { platformVersion: '15.0.0' }, 'Windows 11 · Chrome 130'],
  ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0', { platformVersion: '10.0.0' }, 'Windows 10 · Edge 130'],
  ['Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0', null, 'Windows · Firefox 131'],
  ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', null, 'macOS · Safari 17.5'],
  ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36', { platformVersion: '14.5.0' }, 'macOS 14 · Chrome 130'],
  ['Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1', null, 'iOS 17.5 · Safari 17.5'],
  ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.50(0x18003231) NetType/WIFI Language/zh_CN', null, 'iOS 18 · WeChat 8.0'],
  ['Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36', { platformVersion: '14.0.0' }, 'Android 14 · Chrome 130'],
];
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml' };
function serve() {
  const srv = http.createServer((req, res) => {
    const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let f = p.startsWith('/qianye/') ? path.join(ROOT, p.slice(8) || 'index.html') : null;
    if (!f || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}
const INTERCEPT = () => {
  window.__mailto = [];
  window.addEventListener('click', (e) => { const a = e.target.closest && e.target.closest('a[href^="mailto:"]'); if (a) { window.__mailto.push(a.href); e.preventDefault(); } }, true);
};
function parse(href) {
  const [addr, q] = href.slice('mailto:'.length).split('?'), o = { to: decodeURIComponent(addr) };
  for (const kv of q.split('&')) { const i = kv.indexOf('='); o[kv.slice(0, i)] = decodeURIComponent(kv.slice(i + 1)); }
  return o;
}

(async () => {
  const srv = await serve(), URL = `http://127.0.0.1:${srv.address().port}/qianye/index.html`;
  fs.mkdirSync(OUT, { recursive: true });
  const b = await chromium.launch(); let bad = 0; const res = [];
  const fail = (...a) => { bad++; console.log('  ✗', ...a); };
  for (const L of ['en', 'zh']) for (const w of [390, 1280]) {
    const E = EXP[L], phone = w < 500;
    const ctx = await b.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: 2, isMobile: phone, hasTouch: phone, locale: E.locale });
    const pg = await ctx.newPage(); const errs = [];
    pg.on('pageerror', (e) => errs.push(e.message)); pg.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });
    await pg.addInitScript(INTERCEPT);
    await pg.goto(URL); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
    if (L === 'zh') { await pg.click('[data-lang="zh"]'); await pg.reload(); await pg.waitForFunction(() => window.__teng && window.__teng.ready); }
    // 纸上先有字（示例），更像真用的时候
    await pg.evaluate((t) => window.__teng.set(t), STR[L].sample); await pg.waitForTimeout(300);
    const check = async (where, sel) => {
      const a = pg.locator(sel);
      if (await a.count() !== 1) return fail(L, w, where, '没有「提意见」');
      if ((await a.innerText()).trim() !== E.text) fail(L, w, where, '按钮字不对', await a.innerText());
      await a.scrollIntoViewIfNeeded();
      await pg.evaluate(() => { window.__mailto = []; });
      await a.click();
      const got = await pg.evaluate(() => window.__mailto);
      if (got.length !== 1) return fail(L, w, where, '点了没拦到 mailto', got.length);
      const m = parse(got[0]), lines = m.body.split('\r\n'), last = lines.pop();
      if (m.to !== TO) fail(L, w, where, '收件人', m.to);
      if (m.subject !== E.subject) fail(L, w, where, '标题', m.subject);
      if (JSON.stringify(lines) !== JSON.stringify(E.lines)) fail(L, w, where, '正文提示', JSON.stringify(lines));
      if (!new RegExp(`^${VER.replace(/\./g, '\\.')} · \\S.* · \\S.* \\d`).test(last)) fail(L, w, where, '正文最后一行', last);
      res.push({ lang: L, w, where, subject: m.subject, last });
      console.log(`  ${L} ${w} ${where}: ${m.subject} | ${last}`);
    };
    // 页脚：手机上底下那条（版式、保存、分享）盖着页脚，滚到底再点
    await pg.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await pg.waitForTimeout(200);
    await check('foot', 'footer a.fb');
    if (phone) await pg.screenshot({ path: path.join(OUT, `${L}_${w}_foot.png`) });
    await pg.click('#gear'); await pg.waitForSelector('#dlg-set[open]');
    await check('set', '#dlg-set a.fb');
    if (phone) await pg.screenshot({ path: path.join(OUT, `${L}_${w}_set.png`) });
    if (errs.length) fail(L, w, '控制台报错', errs.join(' | '));
    await ctx.close();
  }
  const ctx = await b.newContext(); const pg = await ctx.newPage(); await pg.goto(URL); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
  for (const [ua, hi, want] of UAS) {
    const got = await pg.evaluate(([ua, hi]) => { Object.defineProperty(navigator, 'userAgent', { get: () => ua, configurable: true }); return window.__teng.fbDevice(hi); }, [ua, hi]);
    if (got !== want) fail('UA', want, '得到', got); else console.log('  UA', got);
  }
  await ctx.close(); await b.close(); srv.close();
  fs.writeFileSync(path.join(OUT, 'fb.json'), JSON.stringify({ ver: VER, bad, res }, null, 1));
  console.log(bad ? `✗ ${bad} 处不对` : '✓ 全对');
  process.exit(bad ? 1 : 0);
})();
