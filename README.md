# 誊抄僧

施主乱写，贫僧誊抄。

手写的纸拍一张，或者把一坨字粘进来，自己认出标题、「名字＋数字」、清单、「时间：」这类行，排成一张好看的图，点「分享」就弹手机的分享面板（存相册、发微信都在里面）。

- 网址（打算）：https://qianshoulab.github.io/tengchao/
- 单文件 `index.html`，手机优先。打字到发出去点 1 下，拍照到发出去点 2 下。
- 9 个版式：便签（默认）、白纸、信笺、牛皮纸、夜读、杂志、手账、大字、公告。比例跟着字 / 3:4 / 1:1，PNG / JPG，按 3 倍屏画。
- 认手写：不贴钥匙就在浏览器里本地认（PP-OCRv5，模型从同一个网站的 `/pabiao/models/` 引，跟渡表僧共用一份缓存，不上传）；贴了谷歌钥匙借 Gemini 认两遍对答案。拿不准的字标黄，点一下就选中，直接改。

| 文件 | 干嘛的 |
|---|---|
| `index.html` | 整个网页 |
| `docs/痛点.md` | 谁在什么时候用，每个设计省了哪一步 |
| `docs/设计记录.md` | 为什么这么做 |
| `docs/版式候选.png` | 9 个版式同一段字的对比图 |
| `docs/参照/来源.md` | 参照的获奖作品和学了哪一点（图只在本机） |
| `docs/对比/记录.md` | 边做边比，每轮输在哪、怎么改的（图只在本机） |
| `tests/serve.py` | 本机服务：照线上路径摆，带假谷歌 |
| `tests/run_layout.py` | 20 段打字测试：标题、结构、对齐、出图用时 |
| `tests/run_ocr.py` | 6 张手写拍照样本的认字准确率 |
| `tests/run_gemini.py` | 贴钥匙那条路：认对、对答案、额度、断网、钥匙无效、模型不存在、回来的不是 JSON |
| `tests/run_phone.py` | iPhone 尺寸真点一遍、数点了几下、第一次打开下载多大 |
| `tests/make_hand.py` | 造手写拍照样本（手写体字体 + 拍照效果） |

跑测试：

```
python -m venv .venv
.venv\Scripts\pip install playwright pillow
.venv\Scripts\python tests\run_layout.py
.venv\Scripts\python tests\run_ocr.py
.venv\Scripts\python tests\run_gemini.py
.venv\Scripts\python tests\run_phone.py
```

本机测试要 `F:\songchengmin\扒表僧\models\` 在（服务把 `/pabiao/` 指到那里），浏览器用本机 Edge。

制作人：千手院方丈释手 · [千手院总舵](https://qianshoulab.github.io/) · oilsongchengmin@gmail.com
