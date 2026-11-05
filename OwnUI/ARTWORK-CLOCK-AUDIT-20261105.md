# 1.9.11 封面与进度反馈复查

## 已确认的时间接口错误

保留的原生 RNTrackPlayer / SwiftAudioEx 返回秒；锁定的 JavaScript fork 在 `src/trackPlayer.ts` 的 `getPosition`、`getDuration` 中统一除以 1000。`OwnUI/index.js` 直接把该 fork 对象交给音频驱动，因此 180.5 秒会报告为 0.1805 秒，12.25 秒会报告为 0.01225 秒。系统进度据此计算会过早到头、缺失或在后续快照到达时跳动。

证据来自已交付的 1.9.11/build 99 IPA，而非仅凭源码推测：SHA-256 `d9f1e33fed00b443722719fe3eb21752707e7fc55bd9d405504f8b346c130bb3`。保留的主程序中 `RNTrackPlayer.getDuration` 位于 `0x1002f6ce0`，`getPosition` 位于 `0x1002f70a0`，各 116 字节，直接桥接底层 Double，没有乘 1000。SwiftAudioEx 的底层时间使用 CMTimeGetSeconds。锁定 fork 为 `bfe33933793460e7588d4d8f38eddf7910806f29`。

修复只让这两个读取方法使用 `NativeModules.TrackPlayerModule` 的原生秒值。`seekTo` 本来已经按秒传递，保持其现有行为。无损流及 AVAudioPlayer 本地文件的时间路径保持原有秒单位。缺少解码器时长时，解析歌曲 interval 的秒数、mm:ss 或 hh:mm:ss，尽早提供有效总时长。

15 秒的 metadata 纠偏间隔本身不等于 UI 应当每 15 秒跳动。正常播放时，系统应根据正确的 elapsedTime、duration 和正播放速率连续推进；暂停及缓冲时才冻结。没有用更频繁的 JS 轮询掩盖单位错误。

## 已确认的封面接口缺陷及证据边界

1.9.11 的 `MPMediaItemArtwork` requestHandler 无论系统请求什么尺寸，都返回原始缩略图。改为按请求尺寸渲染 scale=1 的图片，并明确发布有限时长的音频类型。Apple 的 imageWithSize 可复用较大的缓存表示，测试区分了回调尺寸合同与缓存行为。

这证明存在需要修正的接口缺陷，但不能据此宣称用户真实歌曲的封面缺失已完全定位。此前测试主要验证字典中有 Artwork、能取到非空 UIImage；没有验证请求尺寸，也未验证普通 URL 的下载到系统卡片的完整链路。新增 NSURLSession/URLProtocol 回归覆盖有效图片、403、无效图像响应及缓存。

保留的 CarPlaySupport 库中 `refreshNowPlayingInfo` 和 `startNowPlayingMonitor` 入口已是 RET，因此不能把当前问题简单归咎于该旧监控器。没有修改系统 UIKit/MediaPlayer 方法，也没有增加定时覆盖系统 metadata 的全局钩子。

## 现场诊断

现有“车机连接诊断 → 导出连接诊断”增加 nowPlaying 节点：图片请求的 HTTP 状态和字节数、解码状态、系统请求图片尺寸、是否占位图，以及系统 duration/elapsed/rate。runtime 同时保留原生 audio duration/rate/state，以区分数据源、图片解码、系统 metadata 和 UI 展示环节。不导出媒体 URL、账号凭据或歌曲名称；闲置时读取诊断不初始化系统媒体会话。

## 验证

- 新增 4 项 iOS clock ABI 边界回归，明确保留旧 fork 的 /1000 行为作为对照，验证生产驱动中的完整时长、连续进度、暂停、EOF 和秒单位 seek。
- 原有 42 项 JavaScript 回归继续执行，总计 46 项。
- Swift Core 验证时长格式与非法值隔离。
- 原生系统卡片测试覆盖取图尺寸、真实 HTTP 解码路径、有限音频时长及正播放速率、诊断和闲置状态。

自动验证不能代替用户 iPhone、车机或真实歌曲 CDN 的测试。未经现场数据确认的封面原因不标为已验证。
