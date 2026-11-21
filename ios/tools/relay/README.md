# 一叶笺 ⇄ 大管家 信箱（施工单 065）的工具

接口见 `ios/docs/大管家接口.md` 的 v2 一节。

| 文件 | 干什么 |
|---|---|
| `dgj.mjs` | Node 版的两头：加解密（AES-256-GCM）、信封、连信箱。Node 22 自带 fetch / WebSocket / WebCrypto，不用装包 |
| `fake_butler.mjs` | 假掌机：`pair [relay]` 打一份新配对；`run '<配对>' [N]` 连上信箱，收到理顺请求就回结果（不叫大脑，只量时间） |
| `phone_probe.mjs` | 手机探针（Node 版）：`'<配对>' [N]` 交 N 个请求（每个带 400KB 的图），每段列时间 |
| `e2e.sh` | CI（`.github/workflows/ios-relay.yml`）跑的：假掌机 + YiyeKit 的 `LiveRelayTests`（app 里那套 MailClient、MailSocket）来回 10 次 |
| `luruseng-relay-dgj.patch` | 中转站这边的改动（luruseng-relay 加 `/dgj`）。065 那趟云端会话没拿到 luruseng-relay 的推送权限，代码和测试做完了，放在这里等推 |

## 把中转站补丁推上去（有 luruseng-relay 推送权限的会话做）

```
git clone https://github.com/QIANSHOULAB/luruseng-relay && cd luruseng-relay
git am ../qianye/ios/tools/relay/luruseng-relay-dgj.patch   # 补丁做在 8bb14c9 上
npm ci && npm test                                         # 23 个测试：录入僧 5、点钞机 9、信箱 9
git push origin HEAD:main                                  # Cloudflare 自己部署
curl https://luruseng-relay.lunzigeju.workers.dev/ping     # 「录入僧中转站：在。」
curl https://luruseng-relay.lunzigeju.workers.dev/dgj/00000000000000000000000000000000/state   # {"pc":false,...}
```

推上去以后，qianye 的 Actions 里手动跑一次「iOS 信箱」（ios-relay.yml），它会自己改成对着线上信箱跑 10 次。

本机试（不用 Cloudflare 账号）：在 luruseng-relay 里 `npx wrangler dev --port 8787`，然后

```
P=$(node fake_butler.mjs pair http://127.0.0.1:8787)
node fake_butler.mjs run "$P" 10 &
node phone_probe.mjs "$P" 10
```
