# 红果短剧 倍速浮点插件（hongguospeed.dylib）

给红果短剧（`com.phoenix.video`）加一个半透明悬浮圆钮，点一下在 **1.0 → 1.25 → 1.5 → 2.0 → 1.0** 之间循环。
只做倍速，不碰广告、不碰会员字段。

## 现在这套文件里有什么

| 文件 | 作用 |
| --- | --- |
| `SpeedBadge.m` | 插件源码，全部逻辑在这一个文件里 |
| `Makefile` | Theos 编译配置（arm64，最低 iOS 14） |
| `hongguospeed.plist` | 目标 App 白名单，写死红果的 bundle id |
| `.github/workflows/build.yml` | 云端编译脚本，产出 `hongguospeed.dylib` |
| `push-to-github.bat` | 双击运行，把本工程推到你自己的 GitHub 仓库触发编译 |

## 一、编译（这台 Windows 上没有 iOS 编译环境，走云端）

1. 注册/登录 github.com，新建一个仓库，属性随意（建议 Private），不要勾选 "Add README"。
2. 双击 `push-to-github.bat`，按提示粘贴仓库地址（形如 `https://github.com/你的用户名/hongguo-speed.git`）。
   第一次推送会弹 GitHub 登录，用浏览器授权即可。
3. 打开仓库页面 → `Actions` 标签 → 等这次运行变绿（约 2–4 分钟）。
4. 点进这次运行，在页面底部 `Artifacts` 里下载 `hongguospeed-dylib`，解压得到 `hongguospeed.dylib`。

如果 Actions 变红：点进那次运行 → `dylib` 这个 job → 把最后几十行日志发我，我改代码或改脚本。

## 二、导入（巨魔注入器 / TrollFools）

1. 打开巨魔注入器，选中 **红果短剧**。
2. 添加 dylib：选刚下载的 `hongguospeed.dylib`。
   本插件不依赖 `CydiaSubstrate`，也**不需要** `libJailedShim.dylib` 一起导入。
3. 保存注入，重新打开红果。

## 三、使用

- 屏幕右侧偏上有个半透明圆钮，显示当前倍率数字。
- 点一下切换倍率，顺序 1 → 1.25 → 1.5 → 2 → 1。
- 按住拖动可以挪位置，松手不会切换倍率（拖动和点击是分开的）。
- 数字变成 1 时，恢复红果自己的原始速度，插件不再干预。
- **长按圆钮 0.6 秒**：弹出一块调试信息（12 秒后自动消失）。第一行是 `hook N | 实例 M`，
  下面列出红果里实际存在的倍速接口类名。**第一次用先看这个，截图发我就能定位问题。**

想要"一打开就默认 1.5"：把 `SpeedBadge.m` 第 14 行的 `static int gRateIndex = 0;` 改成 `= 2;`，重新走一遍编译。

## 四、已验证 / 未验证（务必看清）

已做的静态确认（依据你提供的脱壳包 `红果短剧-7.3.9..ipa`，只读分析、未安装）：
- 主程序 `cryptid=0`，确认是真脱壳；bundle id `com.phoenix.video`，版本 7.3.9.32，已写进白名单。
- 播放器是字节自研 **TTVideoEngine**，不是 `AVPlayer`。ObjC 符号表里明确存在
  `-setPlaySpeed:`（参数类型 `double`）、`-setPlaySpeedWithRate:`、`-defaultPlaySpeed` / `-setDefaultPlaySpeed:`（`NSString`）、`-playSpeedBtnAction`，
  以及 `BDAOVideoEngine`、`BDAOLandscapeSpeedSettingCell` 等倍速 UI 类。
- 主程序是单架构 **arm64**（不是 arm64e），和 `Makefile` 的 `ARCHS = arm64` 对得上，注入后能被加载。
- 所以本版把挂点从 `AVPlayer` 换成 `TTVideoEngine -setPlaySpeed:`（主），`BDAOVideoEngine`、`AVPlayer` 作兜底。
- 工作方式：红果每次把速度写回 1.0（起播、切集、重置）时，插件替换成圆钮当前倍率，所以切集后不用重新点。

**还没验证的部分（这台 Windows 无法验证，必须真机才清楚）**：
- 没有 iOS 编译环境，这个 dylib 还没被编译器碰过，源码可能有语法/链接错。第一步是 Actions 能不能编绿。
- `TTVideoEngine` 在运行时是否真的用这个名字（有没有被混淆/是子类），只有长按面板能告出来。
  症状区分：**长按面板 `hook 0`** = 挂点名字不对，把截图发我改；**`hook ≥1`、`实例` 在播放后仍是 0** = 类对但走的是另一条setter；**有实例但不变速** = 红果自己按 `defaultPlaySpeed` 字符串又覆盖了一次，需要再挂 `setDefaultPlaySpeed:`。
- 红果自带倍速菜单的数字可能和实际倍率对不上（插件在播放器层，App 自己不知道）。
- 倍速后服务端统计的观看时长与实际播放可能不一致，涉及金币/提现收益，先小额试。

## 五、回滚

巨魔注入器里删掉这条 dylib 注入并让红果重新签名，或直接从 App Store 重装红果。删除 `D:\学习\hongguo-speed` 整个目录即可清掉本地源码。
