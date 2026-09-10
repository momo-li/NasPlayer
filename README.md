# NasPlayer
<<<<<<< HEAD

基于 HarmonyOS（ArkTS/ArkUI）的 NAS 视频播放器：自动发现局域网中的 SMB 主机，也支持通过 IPv6 或域名连接远程主机，浏览共享目录并直接播放视频文件，无需挂载或下载。

## 功能特性

- 局域网扫描：并发探测本机 IPv4 网段内 445 端口的 SMB 主机，并识别 SMB 协议版本
- 远程主机连接：手动输入公网 IPv4 / IPv6 / 域名即可连接（需目标 445 端口可达）
- IPv6 支持：兼容完整与 `::` 压缩写法、`[fe80::1%wlan0]` 方括号与作用域标识，链路本地地址自动补全接口名
- 域名解析：主机名经 DNS 解析，优先使用 IPv6 地址，并按顺序尝试多个解析结果
- 连接配置：地址、用户名与密码本地缓存，下次自动填充
- 共享与目录浏览：列出共享、文件夹与视频文件，支持多级目录返回
- 视频播放：自实现 SMB2 客户端 + 本地 HTTP Range 代理，AVPlayer 流式播放
- 播放控制：播放/暂停、进度拖拽、0.75x ~ 2x 倍速、适应/裁剪缩放模式、屏幕亮度调节
- 手势操作：上下滑切换上/下一部、左右滑快进/快退 10s、长按 X2 倍速、单击显示/隐藏控制栏
- 屏幕适配：横竖屏自动旋转、全屏沉浸、挖孔屏与系统导航栏避让

## 技术架构

```
┌──────────┐   ┌───────────┐   ┌──────────────┐   ┌──────────┐
│ ArkUI 页面 │ → │ SmbService │ → │  SmbClient    │ → │ SMB 服务器 │
│ (播放/浏览) │   │  (单例)    │   │ (自实现 SMB2) │   │  (NAS)   │
└──────────┘   └───────────┘   └──────────────┘   └──────────┘
      ↑                ↑
      │          ┌─────────────┐
      └───────── │ StreamServer │ 本地 HTTP Range 代理
        AVPlayer │  127.0.0.1   │
                 └─────────────┘
```

AVPlayer 通过 `http://127.0.0.1:<port>/stream?f=<path>` 拉流，`StreamServer` 将 Range 请求转换为 SMB 的 `readRange` 读取，实现边下边播。

## 目录结构

```
entry/src/main/ets
├── entryability/          # 应用入口 Ability
├── pages/
│   ├── Index.ets          # 主机发现 / 手动连接
│   ├── ShareListPage.ets  # 共享列表
│   ├── BrowserPage.ets    # 目录与文件浏览
│   └── PlayerPage.ets     # 视频播放页
├── smb/                   # SMB2 协议实现
│   ├── SmbClient.ets      # 连接、readdir/getSize/readRange
│   ├── SmbSession.ets     # 会话与重连管理
│   ├── SmbPacket.ets      # 协议报文编解码
│   ├── SmbSocket.ets      # TCP 通道
│   ├── SmbCrypto.ets      # 签名与加密
│   └── Ntlm.ets           # NTLM 认证
├── service/
│   ├── StreamServer.ets   # 本地 HTTP Range 流媒体代理
│   ├── SmbService.ets     # SMB 业务单例
│   ├── NeighborScanner.ets# 局域网主机扫描
│   ├── ConfigStore.ets    # 主机/凭据持久化
│   ├── MediaUtil.ets      # 视频格式、大小与时间格式化
│   └── NetUtil.ets        # IPv4/IPv6/域名校验、解析与规范化
└── model/                 # 数据模型
```

## 环境要求

- DevEco Studio（支持 HarmonyOS SDK）
- HarmonyOS SDK：6.1.1(24)，`compatibleSdkVersion` 同版本
- 设备：Phone（`deviceTypes: ["phone"]`）；局域网直连或远程访问均可

## 构建与运行

1. 使用 DevEco Studio 打开工程根目录
2. 在 `File > Project Structure > Signing Configs` 中配置自动签名
3. 连接真机或启动模拟器，点击 Run

## 远程主机与 IPv6

「手动输入主机地址」不限于局域网，支持以下任意形式：

| 类型 | 示例 | 说明 |
|------|------|------|
| IPv4 | `192.168.1.10`、`203.0.113.5` | 内网或公网地址 |
| IPv6 | `2408:8216::1`、`[fe80::1%wlan0]` | 完整/压缩写法均可，`[ ]` 可选 |
| 域名 | `nas.example.com` | 经 DNS 解析，优先取 IPv6 地址 |

- 远程连接：公网 IPv4 需在路由器上映射 445 端口（或走 VPN），公网 IPv6 地址可直接连接
- 域名解析：解析结果按「IPv6 优先」排序，最多尝试 3 个候选地址，逐个失败后依次重试
- 链路本地地址：`fe80::` 开头且未写作用域时，自动补全当前网络接口名（如 `%wlan0`）
- 地址格式错误会即时提示；自动扫描仅覆盖本机 IPv4 网段，IPv6 与远程主机请使用手动输入

## 使用说明

1. 打开应用后自动扫描网段内的 SMB 主机；远程主机或 IPv6 地址请点击「手动输入主机地址」
   （IPv6 示例：`2408:8216::1` 或 `[fe80::1%wlan0]`）
2. 选择主机，输入用户名与密码后连接（凭据会被保存，下次自动填充）
3. 选择共享目录，进入文件夹找到视频文件
4. 点击视频开始播放，点击画面显示控制栏；上下滑切换视频，左右滑快进/快退，长按 X2 倍速

## 支持的视频格式

mp4、mkv、avi、mov、ts、m2ts、webm、wmv、flv、m4v、3gp、rmvb、rm、mpg、mpeg、vob

实际可播放性取决于设备解码能力与文件封装（如部分 RMVB、H.265 依赖硬件解码支持）。

## 权限说明

| 权限 | 用途 |
|------|------|
| `ohos.permission.INTERNET` | 连接 SMB 服务器、启动本地流媒体代理 |
| `ohos.permission.GET_NETWORK_INFO` | 获取本机 IP 以扫描局域网主机 |
=======
原生鸿蒙app,基于SMB3共享技术
播放nas中的视频
支持ipv6,支持主机解析
>>>>>>> db309860f39d035b942fdfe970375bdffa258345
