# LX Music iOS — CarPlay (TrollStore)

本分支包含原生 CarPlay 音乐界面，目标是 TrollStore 自用安装。

## 实现方式

- CarPlay UI 使用 Apple `CarPlay.framework` 原生模板，不渲染 React Native 页面。
- CarPlay 连接后同步设置 `CPListTemplate` 根模板，避免等待 RN / 网络 / 自定义源导致空白或黑屏。
- 手机端与 CarPlay 共用同一套 LX 播放器，不创建第二个 `AVPlayer`。
- CarPlay 只发送 `listId + musicId` 播放请求给 JS；实际取播放 URL、FLAC、音效、队列、后台播放都继续走现有 LX 播放器。
- 我的收藏、试听列表、自建歌单、最近播放会同步成本地 CarPlay 快照。
- 快照写入 Application Support；CarPlay 冷启动会先读取上一次成功快照，再异步让 RN 刷新。
- 歌曲列表按 `CPListTemplate.maximumItemCount` 自动分页，兼容不同车机的 UI 限制。
- 搜索使用 `CPSearchTemplate`，直接搜索已同步的本地歌单快照，不依赖车机界面等待网络请求。
- 正在播放使用系统 `CPNowPlayingTemplate` + `MPNowPlayingInfoCenter`，与锁屏、方向盘按键共用状态。

## Entitlements

`ios/LxMusicMobile/LxMusicMobile.entitlements` 包含：

- `com.apple.developer.carplay-audio`
- `com.apple.developer.playable-content`

正常 App Store / 开发者证书分发时，CarPlay entitlement 必须由 Apple 授权。本项目的 TrollStore 构建流程会在 CI 中使用 `ldid` 将 entitlement 写入主程序，并在打包前重新读取校验。

## 最稳的安装方式

GitHub Actions 成功后下载：

`LXMusic-iOS-<version>-CarPlay-TrollStore.ipa`

优先直接用 TrollStore 安装这个 IPA。不要再经过会重新签名并删除 entitlement 的普通签名工具。

如果必须使用其他签名工具，请确认签名后主程序仍包含 `com.apple.developer.carplay-audio = true`。

## CarPlay 首次使用

1. 安装后至少打开一次手机端 LX Music，让歌单快照完成首次同步。
2. 连接 CarPlay。
3. CarPlay 首页应立即出现 `正在播放 / 我的收藏 / 试听列表 / 我的歌单 / 搜索音乐 / 刷新音乐库` 中可用的项目。
4. CarPlay 中选择歌曲后，播放请求会进入现有 LX 播放器；自定义源、音效、FLAC 等继续由手机端播放器处理。

## 稳定性设计

- CarPlay scene 不依赖网络才能建立根界面。
- RN 尚未完成初始化时，CarPlay action 会在原生侧排队，Bridge 开始监听后自动补发。
- CarPlay 断开时清理 interface controller；重新连接时重新建立原生根模板。
- 音乐库变更与播放状态变化只更新已有根模板，不重新创建手机端 UI。
- CarPlay 搜索与列表显示不会直接调用自定义源，因此自定义源超时不会造成 CarPlay UI 黑屏。
