// 中英两套真流程（双语单）：node tests/bi.js
// 默认英文（浏览器语言是中文也不自己切）→ 右上角点「中文」→ 刷新还记得 → 点回 EN。
// 中英各跑一遍：手机 390（iPhone 尺寸、触屏、假分享面板）、电脑 1280 —— 空纸、打字、换版式、分享 / 保存、拍照认字、设置；
// 查：控制台和页面 0 报错；按钮没被撑破、没挤成两行、字没截断；手机 390 没有横向滚动；出图落款是这门语言的名字、衬线字体不缺字；
// 存图文件名前缀。截图放 docs/shots-bi/（手机 390、电脑 1280 × 空纸、结果；另加设置），结果写 docs/shots-bi/bi.json。
// 本机服务照线上路径摆：/qianye/ = 本仓库，/pabiao/ = 渡表僧仓库（本机叫 扒表僧，云端 clone 叫 pabiao；只读，用它的认字模型）。
'use strict';
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PABIAO = ['扒表僧', 'pabiao'].map((d) => path.join(ROOT, '..', d)).find((d) => fs.existsSync(path.join(d, 'models'))) || path.join(ROOT, '..', 'pabiao');
const OUT = path.join(ROOT, 'docs', 'shots-bi');
const STR = require(path.join(ROOT, 'strings.js'));
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const SHARE_MOCK = `
window.__shared = [];
navigator.canShare = (d) => !!(d && d.files && d.files.length);
navigator.share = async (d) => { const f = d.files[0]; window.__shared.push({ name: f.name, type: f.type, size: f.size }); };`;
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.txt': 'text/plain; charset=utf-8',
  '.onnx': 'application/octet-stream', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml' };

function serve() {
  const srv = http.createServer((req, res) => {
    const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let f = null;
    if (p.startsWith('/qianye/')) f = path.join(ROOT, p.slice(8) || 'index.html');
    else if (p.startsWith('/pabiao/')) f = path.join(PABIAO, p.slice(8));
    else if (p === '/luruseng/key.html') f = path.join(ROOT, 'tests', 'key_placeholder.html');
    if (f && f.endsWith(path.sep)) f = path.join(f, 'index.html');
    if (!f || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}

// 页面里跑：能看见的按钮、标签、字，有没有被撑破 / 挤成两行 / 截断；页面有没有横向滚动
const LAYOUT_CHECK = () => {
  const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const lines = (el) => {
    const tops = new Set();
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      if (!n.textContent.trim()) continue;
      const r = document.createRange(); r.selectNodeContents(n);
      for (const q of r.getClientRects()) if (q.width > 1) tops.add(Math.round(q.top / 4));
    }
    return tops.size;
  };
  const bad = [];
  const sel = 'button, a.btn, .pill, .th span, .seg button, label, .brand, .tools, .acts2, .dacts';
  for (const el of document.querySelectorAll(sel)) {
    if (!vis(el)) continue;
    const name = (el.id ? '#' + el.id : el.className ? '.' + String(el.className).split(' ')[0] : el.tagName) + ' ' + JSON.stringify(el.textContent.trim().slice(0, 30));
    const r = el.getBoundingClientRect();
    if (el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX !== 'auto') bad.push(`${name} 截断（${el.scrollWidth} > ${el.clientWidth}）`);
    if (el.matches('button, a.btn, .pill, .th span, .seg button, label') && el.textContent.trim() && lines(el) > 1) bad.push(`${name} 挤成 ${lines(el)} 行`);
    let sc = el.parentElement;               // 横着滑的那排（版式）里，滑到屏幕外的不算
    while (sc && !/auto|scroll/.test(getComputedStyle(sc).overflowX)) sc = sc.parentElement;
    if (!sc && (r.right > innerWidth + 0.5 || r.left < -0.5)) bad.push(`${name} 出了屏幕（${Math.round(r.left)}–${Math.round(r.right)} / ${innerWidth}）`);
  }
  // 一排按钮挤成两排也算（设置底下那排、工具那排）
  for (const row of document.querySelectorAll('.dacts, .acts2')) {
    if (!vis(row)) continue;
    const tops = new Set([...row.children].filter((c) => vis(c) && c.textContent.trim()).map((c) => Math.round(c.getBoundingClientRect().top)));
    if (tops.size > 1) bad.push(`${row.className} 那排挤成 ${tops.size} 排`);
  }
  const sw = document.documentElement.scrollWidth;
  if (sw > innerWidth) bad.push(`页面横向滚动 ${sw} > ${innerWidth}`);
  return bad;
};

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await serve();
  const URL = `http://127.0.0.1:${srv.address().port}/qianye/index.html`;
  const b = await chromium.launch();
  const rep = { default: {}, en: {}, zh: {} };
  const errors = [];
  let fails = 0;
  const say = (ok, s) => { if (!ok) fails++; console.log(`${ok ? '✓' : '✗'} ${s}`); };
  const watch = (pg, tag) => {
    pg.on('console', (m) => { if (m.type() === 'error') errors.push(`${tag} console: ${m.text()}`); });
    pg.on('pageerror', (e) => errors.push(`${tag} pageerror: ${e.message}`));
  };
  const head = (pg) => pg.evaluate(() => ({ lang: document.documentElement.lang, title: document.title,
    desc: document.querySelector('meta[name=description]').content, app: document.querySelector('meta[name=apple-mobile-web-app-title]').content,
    font: getComputedStyle(document.body).fontFamily.split(',').slice(0, 6).map((s) => s.trim()).join(', '),
    pressed: [...document.querySelectorAll('[data-lang]')].map((x) => `${x.dataset.lang}:${x.getAttribute('aria-pressed')}`).join(' ') }));

  // ---------------------------------------------------------------- 默认英文、不跟浏览器语言、切换记住
  {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, userAgent: IPHONE_UA, locale: 'zh-CN' });
    const pg = await ctx.newPage(); watch(pg, 'default');
    await pg.goto(URL); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
    const h0 = await head(pg);
    say(h0.lang === 'en' && h0.title === STR.en.title && h0.desc === STR.en.desc && h0.app === STR.en.appShort,
      `浏览器语言 zh-CN、没选过：默认英文 · lang=${h0.lang} · title「${h0.title}」 · ${h0.pressed}`);
    say(/^-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI Variable Text", "Segoe UI", system-ui/.test(h0.font), `英文字体栈西文在前：${h0.font}`);
    await pg.tap('[data-lang=zh]');
    const h1 = await head(pg);
    const shown = await pg.evaluate(() => [document.querySelector('#snap').textContent, document.querySelector('#save').textContent, document.querySelector('.th span') && document.querySelector('.th span').textContent]);
    say(h1.lang === 'zh-CN' && h1.title === STR.zh.title && h1.desc === STR.zh.desc && shown[0] === STR.zh.snap && shown[1] === STR.zh.save,
      `点「中文」：lang=${h1.lang} · title「${h1.title}」 · 按钮 ${JSON.stringify(shown)} · ${h1.pressed}`);
    say(!/Segoe UI/.test(h1.font.split(',').slice(0, 4).join()), `中文字体栈不变：${h1.font}`);
    await pg.reload(); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
    const h2 = await head(pg);
    say(h2.lang === 'zh-CN', `刷新以后还是中文：lang=${h2.lang}`);
    await pg.tap('[data-lang=en]');
    await pg.reload(); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
    const h3 = await head(pg);
    say(h3.lang === 'en', `点回 EN、刷新：lang=${h3.lang}`);
    rep.default = { first: h0, afterZh: h1, reloadZh: h2, backEn: h3 };
    await ctx.close();
  }

  for (const lang of ['en', 'zh']) {
    const S = STR[lang], R = rep[lang];
    const init = `localStorage.clear(); localStorage.setItem('tengchao.lang', '${lang}');`;
    console.log(`\n—— ${lang} ——`);
    // ---------------------------------------------------------------- 手机 390
    {
      const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, userAgent: IPHONE_UA });
      await ctx.addInitScript(init); await ctx.addInitScript(SHARE_MOCK);
      const pg = await ctx.newPage(); watch(pg, `${lang}-390`);
      await pg.goto(URL); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
      await pg.waitForTimeout(400);                                    // 缩略图 200ms 后画
      const h = await head(pg);
      say(h.lang === S.lang && h.title === S.title, `手机：lang=${h.lang} · title「${h.title}」`);
      await pg.screenshot({ path: path.join(OUT, `${lang}-empty-390.png`) });
      let bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `手机空纸：按钮、字、横向滚动 ${bad.length ? bad.join('；') : '都没毛病'}`);
      R.empty390 = bad;
      // 空纸上的两行提示字装得下（画在纸上，不折行）：9 个版式都量
      const hint = await pg.evaluate((s) => window.__teng.THEMES.map((t) => {
        const c = document.createElement('canvas').getContext('2d'); c.font = `400 ${t.size}px ${t.font}`;
        return { id: t.id, room: 390 - t.pad[1] - t.pad[3], w: Math.ceil(Math.max(c.measureText(s.hint1).width, c.measureText(s.hint2).width)) };
      }), { hint1: S.hint1, hint2: S.hint2 });
      const over = hint.filter((x) => x.w > x.room);
      say(!over.length, `空纸提示字 9 个版式都装得下${over.length ? '：超了 ' + JSON.stringify(over) : `（最宽 ${Math.max(...hint.map((x) => x.w))} / 最窄的地方 ${Math.min(...hint.map((x) => x.room))}）`}`);
      // 打字：点纸、打两行示例里的字
      await pg.tap('#paper-cv', { position: { x: 60, y: 50 } });
      await pg.keyboard.insertText(S.sample);
      await pg.evaluate(() => document.querySelector('#text').blur());
      await pg.waitForTimeout(400);
      const model = await pg.evaluate(() => window.__teng.model.blocks.map((x) => x.k));
      say(model[0] === 'title' && model.includes('rows'), `示例字认成 ${JSON.stringify(model)}`);
      const total = await pg.evaluate(() => { const r = window.__teng.model.blocks.find((x) => x.k === 'rows'); return r && r.items.filter((i) => i.total).map((i) => i.label); });
      say(total && total.length === 1, `合计行认出来（加粗、上面一道线）：${JSON.stringify(total)}`);
      await pg.screenshot({ path: path.join(OUT, `${lang}-result-390.png`) });
      bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `手机打完字：${bad.length ? bad.join('；') : '都没毛病'}`);
      R.result390 = bad;
      // 换版式（信笺：衬线、居中落款）→ 分享
      await pg.tap('.th[data-id=letter]');
      await pg.tap('#share');
      await pg.waitForFunction(() => window.__shared.length === 1);
      const sh = await pg.evaluate(() => window.__shared[0]);
      say(sh.name.startsWith(S.filePrefix + '_') && sh.type === 'image/png' && sh.size > 10000, `信笺 → 分享：${sh.name}（${sh.size} 字节）`);
      R.share = sh;
      // 出图落款：每个版式都是这门语言的名字；衬线版式字体不缺字
      const marks = await pg.evaluate(async (s) => {
        const T = window.__teng, out = {};
        for (const t of T.THEMES) {
          if (t.serif) await T.ensureFonts(t.id, s.sample);
          const L = T.layout(T.parse(s.sample), t);
          out[t.id] = L.ops.filter((o) => o.k === 'text' && o.id == null && (o.s === s.mark || o.s === s.markLetter)).map((o) => o.s + ' @ ' + o.font.split(',')[0]);
        }
        const fam = '"Noto Serif SC"';
        out.serifCheck = document.fonts.check(`400 11px ${fam}`, s.markLetter) && document.fonts.check(`700 24px ${fam}`, s.mark);
        out.serifLoaded = [...document.fonts].filter((f) => /Noto Serif SC/.test(f.family) && f.status === 'loaded').length;
        return out;
      }, { sample: S.sample, mark: S.mark, markLetter: S.markLetter });
      const allMarked = Object.entries(marks).filter(([k]) => !k.startsWith('serif')).every(([, v]) => v.length === 1);
      say(allMarked, `9 个版式落款都是「${S.mark}」：${JSON.stringify(Object.fromEntries(Object.entries(marks).filter(([k]) => !k.startsWith('serif')).map(([k, v]) => [k, v[0]])))}`);
      say(marks.serifCheck, `衬线落款字体不缺字（document.fonts.check）：${marks.serifCheck}，已下 Noto Serif SC ${marks.serifLoaded} 块`);
      R.marks = marks;
      // 9 个版式出图（3 倍）的落款那一截，竖着拼一张，放大看字形
      const strip = await pg.evaluate(async (sample) => {
        const T = window.__teng, cut = 64 * 3, parts = [];
        for (const t of T.THEMES) { const r = T.render(sample, t.id, 'auto', 3); const im = new Image(); im.src = r.url; await im.decode(); parts.push(im); }
        const c = document.createElement('canvas'); c.width = 1170; c.height = cut * parts.length;
        const g = c.getContext('2d');
        parts.forEach((im, i) => g.drawImage(im, 0, im.height - cut, 1170, cut, 0, i * cut, 1170, cut));
        return c.toDataURL('image/png');
      }, S.sample);
      fs.writeFileSync(path.join(OUT, `${lang}-marks.png`), Buffer.from(strip.split(',')[1], 'base64'));
      // 拍照认字（不贴钥匙 = 本机认）：状态那句是这门语言
      await pg.tap('#clear');
      await pg.setInputFiles('#pick-album', path.join(ROOT, 'tests', 'hand', 'h2.jpg'));
      await pg.waitForFunction(() => window.__teng.reading === false, null, { timeout: 300000 });
      const ocr = await pg.evaluate(() => ({ text: document.querySelector('#text').value, status: document.querySelector('#status').textContent, log: window.__teng.log.slice(-4) }));
      const want = lang === 'en' ? /^(Done\.|Couldn’t)/ : /^(认完了|没认成)/;
      say(ocr.text.includes('采购清单') && want.test(ocr.status), `相册 → 认字：${JSON.stringify(ocr.text.split('\n')[0])} · 「${ocr.status}」`);
      R.ocr = ocr;
      // 设置
      await pg.tap('#gear');
      await pg.waitForTimeout(300);
      await pg.screenshot({ path: path.join(OUT, `${lang}-settings-390.png`) });
      bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `手机设置：${bad.length ? bad.join('；') : '都没毛病'}`);
      R.settings390 = bad;
      await ctx.close();
    }
    // ---------------------------------------------------------------- 电脑 1280
    {
      const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
      await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new globalThis.URL(URL).origin });
      await ctx.addInitScript(init + 'delete Navigator.prototype.share; delete Navigator.prototype.canShare;');
      const pg = await ctx.newPage(); watch(pg, `${lang}-1280`);
      await pg.goto(URL); await pg.waitForFunction(() => window.__teng && window.__teng.ready);
      await pg.waitForFunction(() => document.querySelectorAll('.th').length === 9);   // 电脑上光标一开就在纸上，缩略图 600ms 后才画
      await pg.waitForTimeout(300);
      await pg.screenshot({ path: path.join(OUT, `${lang}-empty-1280.png`) });
      let bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `电脑空纸：${bad.length ? bad.join('；') : '都没毛病'}`);
      R.empty1280 = bad;
      await pg.keyboard.insertText(S.sample);          // 电脑上一打开光标就在纸上
      await pg.click('.th[data-id=mag]');
      await pg.waitForTimeout(400);
      const [dl] = await Promise.all([pg.waitForEvent('download'), pg.click('#save')]);
      const toast1 = await pg.textContent('#toast');
      // 文件名看页面给 <a download> 的那个（node 版 Playwright 报的 suggestedFilename 遇到中文会变成 download，python 版对）
      const saved = await pg.evaluate(() => window.__teng.saved);
      say(saved.name.startsWith(S.filePrefix + '_') && saved.size > 10000 && toast1 === S.savedDesktop, `保存：${saved.name}（${saved.size} 字节，下载 ${dl.suggestedFilename()}）「${toast1}」`);
      await pg.click('#share');
      await pg.waitForFunction(() => window.__teng.copied > 0, null, { timeout: 10000 });
      const toast2 = await pg.textContent('#toast');
      say(toast2 === S.copied, `分享（电脑没有分享面板）→ 图进剪贴板「${toast2}」`);
      await pg.mouse.move(0, 0);
      await pg.waitForTimeout(2800);                    // 等提示收掉再截图
      await pg.screenshot({ path: path.join(OUT, `${lang}-result-1280.png`) });
      bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `电脑打完字：${bad.length ? bad.join('；') : '都没毛病'}`);
      R.result1280 = bad; R.save = saved; R.toasts = [toast1, toast2];
      await pg.click('#gear');
      await pg.waitForTimeout(300);
      bad = await pg.evaluate(LAYOUT_CHECK);
      say(!bad.length, `电脑设置：${bad.length ? bad.join('；') : '都没毛病'}`);
      await ctx.close();
    }
  }
  say(!errors.length, `控制台、页面报错 ${errors.length} 条${errors.length ? '：\n  ' + errors.join('\n  ') : ''}`);
  rep.errors = errors; rep.fails = fails;
  fs.writeFileSync(path.join(OUT, 'bi.json'), JSON.stringify(rep, null, 1));
  await b.close(); srv.close();
  console.log(`\n${fails ? `✗ ${fails} 项没过` : '✓ 全过'}`);
  process.exit(fails ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(2); });
