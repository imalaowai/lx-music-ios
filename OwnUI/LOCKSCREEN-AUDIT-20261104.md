# 锁屏、CarPlay 控制和封面修复

## 用户反馈与根因

1. 1.9.10 的上一首、下一首有独立原生 target，但播放、暂停、停止和拖动仍借用 TrackPlayer 的 target。无损和离线解码并不依赖 TrackPlayer 当前项，控制能力因此不一致。
2. 协调器明确禁用了 togglePlayPause，并按 wanted 互斥启用 play/pause。系统、蓝牙和车机可使用不同命令；缓冲时实际 rate=0 与 wanted=true 组合会让系统所选按钮变灰。
3. 锁屏封面只读取 img，没有 picUrl 等字段兼容，也没有使用本机 provider SDK 补取缺失封面。旧模块覆盖系统 metadata 后，本地缓存的字典相同，协调器还会跳过修复。
4. 原有测试检查了部分 enabled 标志和 next/previous 投递，没有验证播放/暂停 target 的注册和实际音频响应。

## 修改

- 七个系统 transport 命令统一由原生协调器注册并直接交给 Swift Player；play、pause、toggle 在会话有效时均可用。TrackPlayer capabilities 为空，SDK emitter 和 JS 不重复投递控制。
- 注册幂等，退出时只移除本应用的 target；保留输出断开暂停、时间戳过滤和用户主动恢复的约束。seek 验证事件类型与有限非负位置。
- 原生解析 img、picUrl 等字段、协议相对地址、封面尺寸模板、本地文件和内嵌图片；缺图或下载失败时，经本机 provider SDK 单次补取，包含规范/数字歌曲 ID 转换。
- 图片下载独立于 WKWebView；限制压缩数据大小及解码尺寸，校验 HTTP 状态，丢弃过期封面回调。新歌未准备好时保留完整旧卡片，新歌准备好后使用新封面或占位图。
- 再次发布时比较系统实际 metadata，恢复被旧模块清掉的封面；补取返回同一地址也允许重试一次。
- 图标改为薄荷绿耳机小猫；同一 PNG 母版输出 iPhone、iPad、CarPlay 各尺寸，构建和 IPA 打包都必须应用新资产。

## 回归与边界

自动检查包括 42 项 JS 回归、生产 Swift Core/Room、实际 WebKit/native bridge、provider SDK 封面解析、七个原生 target 的投递和生命周期、图片解码/系统 artwork 请求及 metadata 被覆盖后的恢复。手机模拟器通过已注册 target 检查真实 AVAudioPlayer 播放、暂停、两次 toggle、停止与输出断开后恢复。

这些检查不等于真实 iPhone 锁屏、真实蓝牙协议或车机的实测。设备安装后仍需确认当前 iOS、车机型号及第三方封面 CDN 的表现；构建记录与原始报告用于区分自动验证和真机验证。

## 图标来源

源文件：`OwnUI/Brand/CartoonIcon.png`。通过内置图像生成创建，随后只使用 Pillow 导出 iOS 所需尺寸。生成提示：可爱卡通奶白小猫，薄荷绿头戴耳机，粉色脸颊，开心闭眼；柔和薄荷绿满版方形背景，无文字、外框及预置圆角，缩小后仍清晰。
