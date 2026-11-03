// 中英文字清单：node tests/strings_export.js → docs/strings-bi/en.txt、zh.txt（一行一条：键<Tab>字）。
// 动态的字拿一组示例参数跑出来；同一句换个情况（单复数、Mac / 别的电脑）的记成「键#2」。示例里的换行写成 ⏎，HTML 标签去掉。
'use strict';
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const STR = require(path.join(ROOT, 'strings.js'));
const OUT = path.join(ROOT, 'docs', 'strings-bi');
const ARGS = {
  tooLong: [['3:4']],
  clipDenied: [[false], [true]],
  ocrDl: [[25, 40]],
  ocrDead: [['']],
  http: [[400, 'API key not valid.']],
  netErr: [[180, ''], [0, 'Failed to fetch']],
  noReply: [['SAFETY']],
  allKeysOut: [['11-04 15:00']],
  minuteWait: [[12]],
  keyN: [[1, 'HTTP 400 …']],
  keyDayOut: [[1, 'HTTP 429 …']],
  keyMinute: [[2, 'HTTP 429 …']],
  retryIn: [['HTTP 503 …', 10]],
  bothFailed: [['HTTP 503 …']],
  doneMarks: [[1], [3]],
  fellBack: [['HTTP 503 …']],
  failed: [['…']],
};
const VER = (fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8').match(/const VERSION = '([\d.]+)'/) || [])[1];
const clean = (s) => String(s).replace(/<br>/g, ' ').replace(/<[^>]+>/g, '').replace(/\n/g, ' ⏎ ').trim();
fs.mkdirSync(OUT, { recursive: true });
for (const lang of ['en', 'zh']) {
  const S = STR[lang], rows = [];
  for (const [k, v] of Object.entries(S)) {
    if (typeof v === 'function') {
      const cases = ARGS[k];
      if (!cases) throw new Error(`${k} 没给示例参数`);
      cases.forEach((a, i) => rows.push(`${k}${i ? '#' + (i + 1) : ''}\t${clean(v(...a))}`));
    } else if (v && typeof v === 'object') {
      for (const [k2, v2] of Object.entries(v)) rows.push(`${k}.${k2}\t${clean(v2)}`);
    } else rows.push(`${k}\t${clean(v)}`);
  }
  const head = lang === 'en'
    ? `# Yiye ${VER} English UI copy, exported from strings.js. One per line: key<Tab>text. #2 = same string, other case. ⏎ = line break.`
    : `# 一叶笺 ${VER} 中文界面文字，从 strings.js 导出。一行一条：键<Tab>字。#2 = 同一句换个情况。⏎ = 换行。`;
  fs.writeFileSync(path.join(OUT, `${lang}.txt`), [head, ...rows].join('\n') + '\n');
  console.log(`${lang}: ${rows.length} 条 → ${path.relative(ROOT, path.join(OUT, lang + '.txt'))}`);
}
