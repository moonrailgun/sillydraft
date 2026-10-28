# SillyDraft Logo

- `logo.svg`：正式矢量稿，字形已转为路径，无需安装字体，也不包含嵌入位图。
- `logo.png`：从 SVG 导出的 2048 × 2048 PNG，白色圆角方形底，圆角外透明。
- 上层「Silly」为暖橙 `#CF4A10`，下层「Draft」为酒红 `#88141B`。源自选定的「11-18 双层双色」方案，保留双层字形与排列。

更新 SVG 后，同步导出 2048 × 2048 的透明背景 PNG，再在仓库根目录运行：

```sh
flutter test tool/generate_icons.dart
```

脚本从 PNG 生成全部原生平台图标。Android、macOS、Windows 和 Linux 保留白色圆角底及外侧透明留白；iOS 使用不带透明通道的白底，由系统裁切圆角。
