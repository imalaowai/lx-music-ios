# 栖页音乐 Web 2.9.3：顶部房间栏与下载修复

这里保存了本次 Web 修改的客户端源码、服务端补丁与 Chromium / WebKit 操作测试。完整 Web 项目及离线依赖包含在配套 `QiyeMusic-Web-v2.9.3-Header-Downloads-20261023.zip` 中。

- `js/`、`css/` 和 `share-player.*` 对应发布包 `public/music/` 内的同名文件。
- `patches/` 按完整 Web 项目的相对路径保存服务器、同步脚本与相关回归测试。
- `manifest.json` 校验这些源码与发布包的一致性。
- `QiyeMusic-Web-v2.9.3-upgrade.sh` 校验配套完整 ZIP，并调用保留数据的 Docker 升级器。

完整项目内运行 `npm run build`，再运行 `node --test --test-timeout=60000 test/*.test.cjs`；`scripts/package-release.py` 打包全部受管文件并校验每个文件的 SHA256。`scripts/sync-ipa-interface.py` 生成共享 App 页面，浏览器顶部房间栏与下载实现单独维护，避免被原生绑定覆盖。

`qiye-web-review.yml` 在 Chromium / WebKit 的桌面和手机尺寸验证顶部占位、成员头像、未读提示、下载选项、错误文件拒绝和实际下载字节。页面基础组件来自相同的已封装 UI，服务端使用固定测试音源。真实音源可用音质由其服务端返回结果决定。

配套 App 1.9.5 / build 88 仍使用自己的 UI、音乐房间、聊天和完整原生 CarPlay 集成。下载文件在 URLSession 回调内复制到 App 拥有的目录，再校验并原子保存；不重命名或删除系统 CFNetwork 临时来源文件。模拟器检查不能代替真实设备锁屏与不同车机验证。
