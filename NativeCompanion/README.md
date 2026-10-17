# LX 原生播放与 CarPlay

iOS 15.0+ 独立 Swift App，针对现有 LX Music Sync Server 2.8.4/2.8.5 播放器接口。手机使用服务器现有网页，AVPlayer 负责音频，原生 URLSession/WebSocket 负责房间同步，CarPlay 使用系统音频模板。不会依赖网页在锁屏后继续执行 JavaScript。

## 安装和连接

1. 在本分支的 **LX Native Web + CarPlay IPA** 成功构建中，下载 `LX-Native-CarPlay-iOS15-TrollStore` 制品，解压后取得 `LX-Native-CarPlay.ipa`。
2. 使用 TrollStore 安装 IPA。启动“LX 音乐”，点击“服务器”，填写现有播放器完整网址（包含端口和路径），用现有账号登录。不需要升级 iOS 15.5。
3. 在手机原有歌单中选择歌曲。锁屏、耳机、方向盘按钮均由原生媒体命令处理，上一首/下一首使用 track 命令，关闭短时快进/快退命令，进度条仍可拖动。
4. 连接 CarPlay，在车机打开“LX 音乐”，可浏览播放队列和我的歌单、进入正在播放、控制当前一起听房间。创建/加入房间在手机进行；曾登录后，车机可以先于手机界面启动。

本包使用 `com.apple.developer.carplay-audio` entitlement，并经 ldid 伪签名，面向用户已有的 TrollStore 安装环境。普通 Apple ID 自签可能无法保留 CarPlay 权限；普通分发需 Apple 批准的权限及匹配的描述文件。安装后还需实际 iPhone/车机确认系统识别；编译与权限检查不能证明实车可用。

## 已实现

- 手机网页搜索、歌单和房间界面；选择、暂停、切歌、进度和音量转交原生层。
- 单一 AVPlayer 与后台 audio 模式；暂停保留当前媒体项；原生 Now Playing 封面、歌名、进度和媒体命令。
- 原生队列及列表循环、顺序、随机、单曲循环；提前解析下一首地址，缓存三分钟，不提前下载整首音频。
- 房间绑定、加入/离开、成员、时钟估计、状态回执、断线重连、控制端自动下一首。进度广播不会持续强拉正在播放设备的时间轴。
- 手机场景与 CarPlay 场景各自管理生命周期；进度更新不重建车机根页面。
- 登录令牌存在 Keychain；不读取网页登录密码；项目不包含服务器地址或账号。

## 音频路径和边界

在线音源由 iPhone 直连解析得到的原始地址；历史 `/api/music/download?url=` 代理地址会还原为上游。不新增连续流、转码、服务器音频中转服务。现有 OpenList 的 `/api/openlist/stream` 是服务器既有授权播放路径，仍遵循原服务行为，可能经过服务器；本 App 不会将这一路径声称为网盘直连。

设备文件在首次选择时，把当前队列中设备音频复制进 App 导入目录（单文件上限 500 MB），完成后锁屏和车机才能独立访问，不需要网页保活。重复选择复用已导入文件；复制占用设备存储。设备文件不能作为房间共享音源，其他设备无法读取本机文件。

原网页 Web Audio 音效、可视化不能作用于 AVPlayer，当前原生版不提供这些音效。来电/拔出耳机会按系统音频中断处理；从多任务界面强制关闭 App 会停止播放。原生播放需要音源本身可访问、格式可由 AVPlayer 解码，不承诺消除音源服务响应时间。

网页接入针对此服务器版本的界面函数；若后续服务器重写播放器入口，需要同步更新 Bridge.js。网页未加载或没有登录时，可从车机使用已保存的原生队列，但首次服务器配置和登录要在手机完成。

## 构建和验证

GitHub Actions 使用 macOS/Xcode 生成独立工程、执行原生队列/房间竞态/地址策略检查和网页桥接检查、编译 arm64 真机 App、编译并启动模拟器手机场景、校验最终 CarPlay entitlement 和链接框架、打包 IPA 并生成 SHA256。源码不依赖原仓库的 React Native/CocoaPods 构建。

本地 macOS：

```sh
cd NativeCompanion
python3 scripts/prepare.py
node --test Tests/bridge.test.cjs
xcrun swiftc Sources/Core.swift Tests/main.swift -o /tmp/lx-core-tests
/tmp/lx-core-tests
xcodebuild -project LXCompanion.xcodeproj -scheme LXCompanion -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

IPA 是针对 iOS 15.5/TrollStore 的候选版本。自动检查不涵盖物理锁屏、真实音源、长期后台房间或具体车型；这些不能标记为已验证。
