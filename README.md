# 半档 / Halfstop

Android 上的胶片模拟应用。光谱计算和渲染都在手机 GPU 上跑，不联服务器，也不是套滤镜——胶片、相纸、放大机这一整套流程是算出来的。

| 编辑器 | 画幅、片边与日期后背 |
|---|---|
| ![编辑器](docs/screenshot-editor.png) | ![画幅](docs/screenshot-frame.png) |

## 功能

**胶片与相纸**

- 34 个 profile：25 款拍摄胶片、7 款相纸、2 款电影拷贝片
- 数据来自光谱实测，不是风格化的 LUT
- 相纸决定纸基色调与反差，拷贝片走先翻底再印片的路子
- 模拟强度可调，导出的 JPEG 按同一比例烘进去

**画幅与片边**

- 10 种画幅：135、半格、XPan、645、6×6、6×7、6×8、6×9、6×12、6×17
- 画幅框固定，双指缩放照片、单指拖动构图
- 片边：上下齿孔、片基外、边雾、漏光，条状或单张排布
- 五种片门形状，边字可改写，可打帧号和光圈
- 日期后背：三种字面、四角位置、字号、数据行

**调整**

- 曝光、品红与黄滤色、滤色强度，拖动时约 100 ms 出帧
- 亮度、对比、饱和、色温、色调
- 测光与一键自动曝光
- 场景宽容度：高光与暗部各自往纸的范围里收，也可按场景自动配
- 直方图，可在面板里固定显示
- 撤销 20 步
- 每张照片记住自己的胶片、画幅、片边与调色，换照片不会串
- 导出 JPEG，EXIF 带完整的拍摄参数

**导入**

- 相册图片：JPEG、PNG、WebP、BMP
- RAW：ARW、DNG、CR2、CR3、NEF、RAF、ORF 等，走 LibRaw 解码
- 首页列出最近导入；RAW 的缩略图用相机内嵌的预览，不用先解码

## 安装

从 [Releases](https://github.com/unnyXD/halfstop/releases) 下载 arm64 的 APK，Android 8.0 及以上。覆盖安装即可，导入缓存和设置都保留。

## 构建

需要 Flutter stable、JDK 17、Android SDK（platform 36）、NDK 28.2.13676358（要带 `glslc`）、CMake 3.22.1。

```powershell
# 工具链环境；或自行设置 SPK_TOOLCHAIN 指向含 flutter / jdk / android-sdk 的目录
. .\tool\env.ps1

# 拉引擎、编 shader（首次）
.\tool\fetch-engine.ps1
.\tool\build-shaders.ps1

# 打包
flutter build apk --release --target-platform android-arm64
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

调试用 `flutter run --release`。单元测试用 `flutter test`。

## 架构

```
┌─ Flutter (Dart) ────────────────────────────────────────────┐
│  lib/editor_page.dart   编辑器：预览、滑块、胶片与相纸      │
│  lib/engine_worker.dart 常驻 isolate：engine + session      │
│  lib/engine_bridge.dart 探针、一次性渲染、MethodChannel     │
│         │                                                   │
│         │  SendPort（命令 JSON / 像素 TransferableTypedData）│
│         ▼                                                   │
│  libspektrafilm.so                                          │
│  ├─ spk_mobile.cpp   探针与会话的 C ABI                     │
│  └─ engine/          spektrafilm core + pipeline + Vulkan   │
│         ├─ Vulkan compute（49 个 SPIR-V shader）            │
│         └─ assets/engine/** → filesDir/engine/**            │
└─────────────────────────────────────────────────────────────┘
```

引擎和 session 常驻在同一个 isolate，FFI 指针不跨 isolate；界面发 JSON 命令，像素用 `TransferableTypedData` 传回来，渲染不会堵住 UI。

引擎的参数走 JSON、像素走 buffer，所以加一个滑块不用改 FFI 签名。引擎本身不写文件，只返回 RGBA16，编码交给 Dart。调色那几项在 Flutter 侧用颜色矩阵做，不进引擎，滑块才跟得上手指。

## 许可

- 引擎、胶片模型与 profile：**GPL-3.0-or-later**（上游 spektrafilm 项目），分发版本须以 GPLv3 开源
- 胶片与相纸 profile、打印 LUT：**CC BY-SA 4.0**
- 本移植代码同样按 **GPL-3.0-or-later** 发布
