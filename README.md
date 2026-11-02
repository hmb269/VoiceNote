# 汀汀（VoiceNote）

iPhone + Apple Watch 录音，自动转文字，再用大模型整理成摘要 / 要点 / 待办。

## 功能

- **iPhone 录音**：锁屏也能继续录
- **手表录音**：录完自动传到 iPhone（手表上可开「打开就开始录」）
- **导入音频**：右上角导入，或在语音备忘录 / 文件 App 里「分享 → 汀汀」
- **转写**（苹果本机 / 硅基流动 / 阿里云 / 智谱 GLM-ASR / 自定义 Whisper）
  - 苹果本机（免费）：普通话效果好
  - 阿里云百炼 `qwen3-asr-flash`（约 0.12 元/小时）：粤普混说、方言更准
- **AI 整理**：智谱 GLM（默认 `glm-5.3-flash`）/ DeepSeek / 任意 OpenAI 兼容接口
- 搜索、播放、复制、分享文字和录音文件
- API Key 只存在手机钥匙串，请求直连各家接口

## 拿安装包

每次推送到 `main`，GitHub Actions 会自动编译，在 **Releases** 里放两个包：

- `VoiceNote.ipa`：带手表 App
- `VoiceNote-NoWatch.ipa`：只有 iPhone

都是未签名的，用签名工具签了再装。

> 手表 App 要求手表 App 的 `WKCompanionAppBundleIdentifier` 和手机 App 的 Bundle ID 一致（默认 `com.hmb269.voicenote`）。签名时如果改了 Bundle ID，手表可能装不上，这时可以在签名工具里保持原 Bundle ID，或者先用 NoWatch 版本。

## 设置

1. 设置 → 转写：选默认方式，开关「录完自动转写」「自动 AI 整理」
2. 阿里云百炼：到 bailian.console.aliyun.com 创建 API Key 填进去（只用本机转写可以不填）
3. AI 整理：智谱到 open.bigmodel.cn → API Keys 创建，填进去，点「测试连接」

## 本地开发

```bash
brew install xcodegen
xcodegen generate
open VoiceNote.xcodeproj
```
