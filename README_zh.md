# iDownloader

适用于 HTTP、BitTorrent、FTP、流媒体和文件托管站的下载管理器。
由 [Subham Subhasis Patra](https://github.com/SubhamSubhasisPatra) 维护。

![Banner](.github/assets/banner.webp)

iDownloader 运行于 Windows、macOS、Linux、Android、iPhone 和 iPad。浏览器扩展可以把当前页面上的媒体交给桌面端下载。

## 能下载什么

- HTTP，分段下载，连接复用
- Magnet 与 BitTorrent
- FTP 与 FTPS
- HLS（M3U8）与 MPEG-DASH
- eD2k
- YouTube 与 Bilibili，包括片段、字幕和播放列表
- GitHub 与 Hugging Face，支持镜像加速

## 平台

| 平台 | 版本 | 架构 |
|:--|:--|:--|
| Windows | 10+ | x86_64、arm64 |
| macOS | 13+ | x86_64、arm64 |
| Linux | glibc 2.35+ | x86_64、arm64 |
| Android | 11+ | arm64-v8a |
| iOS / iPadOS | 16+ | arm64 |

iPhone、iPad 和 Mac Catalyst 客户端在 [`ios/`](ios/README.md)。桌面端和 Android 共用 Python 引擎。

## 浏览器扩展

[`browser_extension/`](browser_extension/) 抓取页面中的媒体，并发送到桌面端。

## 运行桌面端

```bash
uv sync
uv run python iDownloader.py
```

## 许可证

iDownloader 以 GNU GPL v3 发布。见 [LICENSE](LICENSE)。
版权与第三方声明见 [NOTICE.md](NOTICE.md)。
