# LX 本机音乐与 CarPlay

iOS 15.0+ 独立 Swift App。1.2.0 将完整界面、搜索/歌单 SDK、歌词和洛雪音源执行引擎内置到 IPA；AVPlayer 负责音频。首次打开可以直接使用本机音乐库，连接 LX Music Sync Server 是可选项。服务器用于账号同步、一起听和服务器配置的 OpenList 网盘。

## 1.2.1：歌词、车机和首页修复

- 修正歌词小数解析：`12.50` 秒正确解析为 12500ms，支持一位/两位/三位小数与整秒。行高亮和逐字进度统一使用原生媒体时钟，遵循歌词 offset，补偿快照传递延迟并忽略过时快照。播放选项增加当前歌曲的“歌词校准”，不改变音频播放位置。
- CarPlay 同时实现音频回调与带窗口回调，保留连接、窗口和根模板；先填充本机内容再设置根页面，分页菜单失败时回退至简洁列表。设置中的“车机连接诊断”可导出不含账号令牌的连接状态。
- 首页歌单与热搜独立显示、独立缓存；最新歌单失败后尝试推荐歌单，空列表不会被缓存为成功。首页与歌单页共用并行请求时，避免 SDK 相互取消。

参考用户提供的 `LX_Music_1.8.4_CarPlay_v11_native_now_playing(1).ipa`，SHA256 `ca6e8331816d69f42e41a22bdb10a3efc18df66b58b0a4e1cda4a900e2e1eb9e`。静态检查确认其 `CarPlaySupport.dylib` 实现带窗口的连接/断开回调，并保留窗口和界面控制器。新版采用对应的生命周期兼容路径，不复制或分发参考包的二进制，也不改变当前播放器所有权。

自动验证包含真实打包歌词解析器、桥接时钟、首页延迟/失败场景、车机回调选择器和模板回退，以及原有连播检查。车机模板检查使用模拟器内的主机替身，不代表已经在具体车型验证；实车黑屏是否消失仍需用户复测。

## 安装与使用

1. 在本分支 **LX Native Web + CarPlay IPA** 的成功构建中下载 `LX-Native-CarPlay-iOS15-TrollStore` 制品，解压取得 IPA，使用 TrollStore 覆盖安装。沿用 `net.minyue.lxcompanion`，无需升级 iOS 15.5。
2. 底部入口为 **首页 / 歌单 / 一起听 / 我的**。首页顶部搜索，下方为热搜、收藏与最新歌单；顶部网站导航已移除，账号、设置、音源、睡眠定时入口收进“我的”和播放选项。
3. 在线播放前，在 **我的 → 音源管理** 导入自有的洛雪 `.js` 音源文件或链接。脚本仅保存在设备，由独立 JavaScriptCore 队列执行，不上传源码仓库。搜索、歌单、歌词由内置 SDK 直接请求平台，音源脚本解析播放地址，音频仍需联网获取。
4. 旧账号已配置服务器音源时，未导入本地脚本可暂用旧服务器解析；“兼容旧服务器音源”可关闭。服务器通过链接导入的音源可以迁移；只上传过文件的音源需在手机重新选择原 `.js` 文件。
5. **我的 → 已下载** 可导入设备音频，以及同名 `.lrc` 和封面图片。播放页选项可“保存离线”，下载完成后直接播放，读取已保存封面与歌词，可通过系统分享歌曲和附件。在线歌曲是否能保存歌词/封面取决于上游是否提供；界面明确显示已保存资源。
6. **我的 → 账号与同步** 连接原服务器并登录，公网地址使用 HTTPS；局域网可使用 HTTP。一起听中点开创建/加入卡片后再填写，加入后进入聊天；上方显示成员头像，选项中查看全部成员或退出。内置 200 个常用 Unicode 表情，无需下载表情目录；不含第三方图片贴纸包。
7. CarPlay 可浏览原生播放队列、歌单、已下载歌曲、正在播放和房间控制。创建/加入房间在手机操作。耳机和方向盘使用上一首/下一首命令；进度条可拖动。

## 性能和连续播放

- Tailwind 在构建时编译，安装版不启动运行时样式编译器。
- 聊天默认渲染最近 60 条，可加载更早消息；复用未变化的消息节点，关闭聊天时不更新隐藏消息列表。下载进度仅更新现有行。
- WKWebView 使用 iOS 15 键盘布局引导，内部聊天独立滚动；输入字号 16px，焦点不滚动整个页面。键盘弹起时收起底部导航、迷你播放栏和头像条，保留消息和输入区。
- 默认减少背景模糊、发光和持续动画；设置可开启增强视觉效果。歌词用本地单调时钟补间，暂停/缓冲/拖动重新校准，高亮不改变行高。
- 原生进度每 0.5 秒更新，锁屏元数据和 CarPlay 页面仅在有关状态变化时刷新。底部播放状态使用实际播放状态。
- EOF 按当前媒体代次处理一次；缺失结束通知且末秒停滞 4 秒时恢复切歌。房间 EOF 在后台任务保护内请求服务器推进，必要时重试和重新同步。

## 数据与网络边界

页面、字体、图标、音乐库、导入音源与下载文件都在手机。热搜、搜索、新歌单、未下载的音频和歌词仍需联网。无需同步服务器不等于所有在线内容都可断网获取。

音源引擎没有文件系统、Keychain 或同步令牌接口；脚本可访问网络、定时器、Buffer 和兼容的 crypto/zlib API。仅导入自己信任的脚本。不同脚本依赖的非标准 Node 模块可能不受支持。ATS 保持开启，仅对内置平台历史 HTTP 接口设置域名例外；其他音源接口需提供 HTTPS，不关闭证书校验。

在线音频直接读取解析得到的原始地址；历史 `/api/music/download?url=` 会还原为上游。现有 OpenList `/api/openlist/stream` 保留服务器授权路径，可能经过服务器。本 App 不新增连续流或转码服务。

设备文件不能作为跨设备房间音源。已下载的在线歌曲仍保留原平台标识，房间内其他设备使用自己的可用音源。下载使用原生后台 URLSession；强制结束 App 会停止播放，系统也可能延后或中断下载。

原网页 Web Audio 音效不能作用于 AVPlayer。播放格式仍受系统解码能力和上游可用性限制。

## 完整源码与构建

`Sources/` 为原生源码，`Resources/AppShell.js`、`AppShell.css`、`Bridge.js` 为本机界面与桥接源码。`Resources/WebUI.html.xz` 是完整可读 HTML/JS/CSS 的压缩源文件，Python `lzma.decompress` 可直接查看每段 `data-source`；不是远程加载器。`Resources/WebUI.manifest.json` 记录每段来源和校验值。

`Engine/src/`、`build.cjs`、锁定的 `package-lock.json` 与 `vendor.tar.xz` 包含本机引擎和 SDK 源码。构建对酷我 JSON 辅助函数应用 iOS 15 正则兼容补丁；原始厂商代码及 LICENSE 保留在归档中。依赖许可证随 App 的 `ThirdPartyNotices.txt` 分发。仓库不包含用户音源、账号、下载音乐或私有服务器配置。

正常构建直接校验并解压已提交资源，不依赖 npm、CocoaPods 或 React Native。GitHub Actions 执行桥接、引擎、Swift 队列/房间/EOF 单元检查、实际 JavaScriptCore + URLSession 测试、Chromium/WebKit 界面回归、arm64 真机构建，以及模拟器 UI 重载和 AVPlayer 连播 8 首离线音频（含封面/歌词/分享文件验证）。最后通过 ldid 伪签名、校验 CarPlay entitlement 并生成 IPA/SHA256。

macOS 构建：

```sh
cd NativeCompanion
python3 scripts/prepare.py
node --test Tests/bridge.test.cjs Tests/engine.test.cjs
xcrun swiftc Sources/Core.swift Tests/main.swift -o /tmp/lx-core-tests
/tmp/lx-core-tests
xcrun swiftc Sources/Core.swift Sources/LocalEngine.swift Tests/engine-native.swift -o /tmp/lx-engine-tests
node Tests/engine-http.cjs /tmp/lx-engine-tests
xcodebuild -project LXCompanion.xcodeproj -scheme LXCompanion -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

重新生成音源引擎：`cd Engine && npm ci && npm run build`。从服务器工作区重新生成基础界面：先安装 Engine 锁定依赖，再运行 `python3 scripts/bundle_web.py SERVER_SOURCE_ROOT`，最后 `prepare.py`。基础界面源码已随压缩 HTML 提交，日常 IPA 构建无需服务器源码。

本包含 `com.apple.developer.carplay-audio`，面向已有 TrollStore 环境；普通分发需要 Apple 批准的权限及匹配描述文件。自动检查不能替代真实 iOS 15.5、长期锁屏、真实音源、多设备房间及具体车型的测试，也不代表已测得真机温度或帧率。
