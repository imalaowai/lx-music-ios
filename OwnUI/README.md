# 自有界面、房间与参考原生播放核心整合

1.9.3（Build 86）增加右上角账号头像菜单，复用个人资料/头像并增加修改密码入口；需配套 Web/服务端 2.9.1。手动同步等待账号拉取和原生歌单缓存确认，不再等 30 秒轮询；前台定时同步仍作兜底。聊天只由本地壳控制可见视口，输入聚焦禁止滚动外层，离开页面先失焦，表情面板在输入区下方并限制高度。Web 桌面侧栏增加收藏、已下载、本地/网盘。

本次无 Swift/Objective-C 变更，可用 `OwnUI/scripts/update-resources.py` 更新完整自有 v15 底包；该流程保留全部原有文件和原生代码段，更新界面资源、版本与资源签名。新增密码接口和同步接口由 Web 源码包提供。浏览器窄屏检查和 Node 回归不代表 iPhone 输入法动画或物理车机实测。

1.9.2（Build 85）修复 CarPlay 重复进入及重连的控制器生命周期：按连接隔离菜单、屏蔽旧连接的断开和异步完成事件、回到前台时只恢复缺失的根页面。音频与窗口两类回调均包装已有实现，分页菜单被系统拒绝或无完成通知时有一次普通列表回退。诊断保留最近 120 条跨进程事件和连接编号，导出时附带实时场景状态。`check-carplay.sh` 在 iOS Simulator 中使用实际生产 Objective-C 生命周期代码与可控的控制器回调验证重连、迟到事件、菜单回退及前台恢复；这不代表物理车机验证。

这条构建以用户自己的本地 UI 为默认手机入口。首页、歌单、一起听（房间和聊天）、我的、已下载、音源和设置使用 `NativeCompanion` 中的实际界面与原生接口，界面和音源解析 SDK 随 IPA 离线安装，服务器用于账号、歌单同步、房间和聊天。

`OwnUI/index.js` 注册自有原生容器，不启动参考版手机界面。`OwnUI/Sources/Player.swift` 保留本机播放队列、房间控制和离线音乐的协调逻辑，`ReferenceAudio` 通过 RN 事件桥调用参考底包中的 TrackPlayer 与 StreamingFlacPlayerModule；不创建第二个 AVPlayer，不启用网页音频。锁屏和 CarPlay 都操作同一个自有播放队列。快速选歌通过代际编号丢弃旧请求，EOF 去重，并保留末秒停滞恢复。

参考底包仅提供其原生二进制能力与 CarPlay 场景连接实现。原生代码段、Hermes 和旧资源仍做逐字节保留验证，业务入口替换为自有 UI 的桥接入口，新增全部本地界面、音源引擎和 Swift/ObjC 集成。最低系统 iOS 15.0。

浏览器界面回归覆盖底部四个导航、自有首页推荐与回退、我的入口、离线封面歌词分享、房间创建加入折叠、默认聊天、成员头像、内置表情和键盘视口。音频路由回归覆盖 TrackPlayer/FLAC 选择、暂停恢复、快速切歌、旧事件隔离和 EOF 去重。真实服务器端到端同步、实机发热和物理 CarPlay 仍需真实设备验证；编译和静态检查不等于这些验证已通过。

构建流程 `.github/workflows/lx-own-ui.yml`，公开源码组件与本地参考 IPA 通过 `FullReference/scripts/package.py` 合成最终安装包。输入参考二进制不上传公开仓库。

## 栖页音乐 1.9.1 · Build 84

The home screen embeds the complete featured-playlist catalog. Personal sections retain their entry page for back navigation. The player detail and collection sheet close synchronously; the queue uses an opaque surface and its own backdrop. Chat retains its header/member geometry as the native keyboard guide moves, and emoji selection/sending never focuses the text input. Room unread counts appear on the bottom navigation.

Offline selections use `playDownload` and the native library's stable record ID. The audio adapter opens on-device files with `AVAudioPlayer`; online audio continues to use the reference TrackPlayer/streaming-FLAC modules. Chinese filenames, real FLAC decode, advancing position, pause, seek, EOF and shareable file lookup are checked in the iOS Simulator host. A quality/content picker controls audio, LRC and cover downloads. Branding is rendered from editable paths and compiled by `actool` into a new app-icon catalog.

`NativeCompanion/WebOverrides` contains the readable edited UI modules; `prepare.py` validates the original packed page before applying these modules, then hashes the actual packaged output. Room synchronization policy is unchanged. Foreground resume depends on accepted room command reasons; background delivery without active playback is limited by iOS suspension.

The home catalog requests cards independently of categories, caches the last 12 successful result pages, and falls back across providers when the initial provider fails. Explicit user source selections are respected.

Packaging also renders/replaces the legacy standalone CarPlay icon PNGs. Install Pillow 11.3.0 in the Python environment used for packaging; the packager runs `OwnUI/Brand/generate.py` to regenerate these files from source.
