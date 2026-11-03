# 一叶笺

原名千叶，2026-11-03 改名（Song 圈定）；再往前 012 施工时叫誊抄僧。网址不变 https://qianshoulab.github.io/qianye/ ，本机文件夹还叫 誊抄僧。

**随手成画。** 手写拍照或打字粘贴，自动装裱成一张体面好图，拿去分享倍儿有面子。

手写的纸拍一张，或者把一坨字粘进来，自己认出标题、「名字＋数字」、清单、「时间：」这类行，排成一张好看的图，点「分享」弹手机的分享面板（发微信、发邮件），点「保存相册」存图。

整页只有一张纸（0.3.0 起，施工单 013）：写在这张纸上，看也在这张纸上。纸上的字直接就是排好版的样子（标题放大、数字对成一列、纸的底色和纹理都是），点哪改哪，长按一行这行当标题。底下一排版式，点哪个这张纸就换成哪个，字和光标都不动。分享出去的图就是这张纸，一个像素都不差。平时不画图，点「保存相册」「分享」那一下才画、才出文件。

- 网址：https://qianshoulab.github.io/qianye/
- 单文件 `index.html`，手机优先。打字到分享点 1 下，拍照、改一个黄字、分享点 3 下（手机上键盘弹着时底下那条收起来不挡字，所以先点键盘上的 ✓ 收键盘，各多 1 下）。
- 9 个版式：便签（默认）、白纸、信笺、牛皮纸、夜读、杂志、手账、大字、公告。比例跟着字 / 3:4 / 1:1，PNG / JPG（这两样在右上角齿轮里），按 3 倍屏画。
- 认手写：不贴钥匙就在浏览器里本地认（PP-OCRv5，模型从同一个网站的 `/pabiao/models/` 引，跟渡表僧共用一份缓存，不上传）；贴了谷歌钥匙借 Gemini 认两遍对答案。拿不准的字标黄，点一下就选中，直接改。

| 文件 | 干嘛的 |
|---|---|
| `index.html` | 整个网页 |
| `docs/痛点.md` | 谁在什么时候用，每个设计省了哪一步 |
| `docs/设计记录.md` | 为什么这么做 |
| `docs/版式候选.png` | 9 个版式同一段字的对比图 |
| `docs/落款_一叶笺.png` | 9 个版式出图的落款，3 倍图原样裁下 |
| `docs/截图_手机.png`、`docs/截图_电脑.png` | 手机 390、电脑 1280 打完字的样子 |
| `docs/参照/来源.md` | 参照的获奖作品和学了哪一点（图只在本机） |
| `docs/对比/记录.md` | 边做边比，每轮输在哪、怎么改的（图只在本机） |
| `tests/serve.py` | 本机服务：照线上路径摆，带假谷歌 |
| `tests/run_layout.py` | 20 段打字测试：标题、结构、对齐、出图用时 |
| `tests/run_ocr.py` | 6 张手写拍照样本的认字准确率 |
| `tests/run_gemini.py` | 贴钥匙那条路：认对、对答案、额度、断网、钥匙无效、模型不存在、回来的不是 JSON |
| `tests/run_paper.py` | 纸和图逐像素比：20 段 × 9 版式 × 3 比例，3 倍屏、2 倍屏 |
| `tests/run_phone.py` | iPhone 尺寸真点一遍：点几下、换版式光标丢没丢、打字跳不跳、拼音组字、微信、电脑、假键盘弹着时底下那条收没收 |
| `tests/compare_ui.py` | 界面跟苹果参照并排的对比图 |
| `tests/make_hand.py` | 造手写拍照样本（手写体字体 + 拍照效果） |

跑测试：

```
python -m venv .venv
.venv\Scripts\pip install playwright pillow
.venv\Scripts\python tests\run_layout.py
.venv\Scripts\python tests\run_ocr.py
.venv\Scripts\python tests\run_gemini.py
.venv\Scripts\python tests\run_paper.py
.venv\Scripts\python tests\run_phone.py
```

本机测试要 `F:\songchengmin\扒表僧\models\` 在（服务把 `/pabiao/` 指到那里），浏览器用本机 Edge，没有就用 Playwright 自带的 Chromium（`.venv\Scripts\playwright install chromium`）。

制作人：千手院方丈释手 · [千手院总舵](https://qianshoulab.github.io/) · oilsongchengmin@gmail.com
