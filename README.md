# 半档 / Halfstop

Android 上的物理胶片模拟相机后期应用。Flutter 前端 + Spektrafilm 的 C++20 / Vulkan 渲染引擎，通过 `dart:ffi` 直接跑在手机上——没有 Python，没有服务端，没有 LUT 近似，光谱计算、coupler、颗粒、光晕全部在 GPU 上现场算。

| 编辑器（Portra 400 + 实时曝光滑块 + 测光） | 画幅：片门、片边与齿孔、日期后背 |
|---|---|
| ![编辑器](docs/screenshot-editor.png) | ![画幅](docs/screenshot-frame.png) |

## 功能

**胶片模拟**

- 28 个胶片 profile（光谱实测数据，非风格化 LUT）：25 款拍摄胶片、7 款相纸、2 款电影拷贝片（2383 / 2393）
- 相纸决定纸基色调与反差，拷贝片走「先翻底再印片」的电影流程——分类来自 profile 自带的 `stage` / `support` 字段
- 模拟强度：原图与成片线性混合，导出按同一算式烘进 JPEG，拖到 40% 导出的就是 40%

**画幅与构图**

- 10 种画幅：135 / 半格 / XPan / 645 / 6×6 / 6×7 / 6×8 / 6×9 / 6×12 / 6×17
- 裁切采用常规修图交互：画幅框固定不动，双指缩放照片、单指拖动构图，缩放倍率实时显示
- 开启「片边与齿孔」时画面自动回到片门形状（胶片边缘画出来时片门必须是真的）
- 片边与齿孔：整条胶片边缘、上下齿孔（白/黑）、片基外（无/黑场/透光）、边雾与漏光
- 片边排布（条状 / 单张）、五种片门形状（方形/圆角/带耳/带肩/踢角，或按画幅自动）
- 边字可改写（默认用胶卷自带的版式）、帧号、打印光圈；半格画幅可一格放两张
- 日期后背：日期 / 三种字面（液晶/点阵/数据）/ 四角位置 / 字号 / 数据行，落在画面内或片边上
- 片边画布超出显存时自动降档：按设备 `maxStorageBufferRange`（12 B/px）预算预览与导出的长边，界面上写明上限

**调整与输出**

- 打印层实时滑块：曝光、品/黄滤色、滤色强度，拖动约 100 ms 出帧（复用缓存底片，只重印）
- 调色层（Layer 2）：亮度/对比/饱和/色温/色调，GPU 颜色矩阵，不碰引擎
- 测光：每帧算平均亮度、高光与暗部裁切、建议曝光，一键「自动」落到曝光滑块
- 直方图：从当前帧采样 64k 像素，随调色实时重算
- 撤销 20 步，一次滑块拖动合并成一步
- 导出 JPEG 到相册，保留原始拍摄参数（EXIF：机身/镜头/ISO/快门/光圈/焦距/时间/GPS/署名）

**导入**

| 入口 | 解码 | 引擎看到的东西 |
|---|---|---|
| 相册图片（JPEG / PNG / WebP / BMP） | Dart `image` 包，纠 EXIF 方向，长边 ≤ 4096 | 线性 ProPhoto RGB float32 |
| RAW（ARW / DNG / CR2 / CR3 / NEF / RAF / ORF…） | LibRaw 0.22.2，NDK 原生编译，16 bit | 同上 |

两条路的汇合点是 `spk_open`：引擎本来就接受线性 RGB 缓冲，相册图片走 `spk_mobile_open_image_on` 跳过 LibRaw，之后的渲染链路完全一致。

首页的「最近导入」是缩略图网格：RAW 用相机内嵌的 JPEG 预览（LibRaw 的 `unpack_thumb`，只读文件头不解码），相册图片直接读原文件，都不需要渲染一次。没有内嵌预览的文件退回占位图标。

## 实时性怎么来的

引擎把参数分成两类，UI 按两类处理：

| 参数 | 路径 | 体感 |
|---|---|---|
| 曝光 / 滤色 | `spk_set_params` → `spk_reprint("live")` | 复用缓存底片只重印，拖动约 100 ms |
| 胶片 / 相纸 / 颗粒 / 光晕 | 同上 | 底片失效，松手才渲染 |
| 调色五项 | Layer 2 颜色矩阵（GPU） | 一次重绘，不进引擎 |

`EngineWorker` 把 engine 和 session 常驻在同一个 isolate，FFI 指针不跨 isolate；UI 发 JSON 命令，像素用 `TransferableTypedData` 传回，渲染永不堵 UI 线程。拖动时 90 ms 防抖 + 「只保留最新一帧」合并请求。

**曝光方向别搞反**：引擎的 `print_exposure` 是放大机曝光倍率，值越大印出来越暗（`print_exposure = 2^-stops`）。界面滑块是「亮度」语义，发过去的参数是 `2^-EV`。

## 架构

```
┌─ Flutter (Dart) ────────────────────────────────────────────┐
│  lib/editor_page.dart   编辑器：预览 / 滑块 / 胶片相纸      │
│  lib/engine_worker.dart 常驻 isolate：engine + session      │
│  lib/engine_bridge.dart 探针 + 一次性渲染 + MethodChannel   │
│         │                                                   │
│         │  SendPort（命令 JSON / 像素 TransferableTypedData）│
│         ▼                                                   │
│  libspektrafilm.so                                          │
│  ├─ spk_mobile.cpp   探针 + 会话/参数/渲染 C ABI            │
│  └─ engine/          spektrafilm core + pipeline + Vulkan   │
│         ├─ Vulkan compute (49 个 SPIR-V shader)             │
│         └─ assets/engine/** → filesDir/engine/**           │
└─────────────────────────────────────────────────────────────┘
```

三条来自上游引擎的关键约定，也是 Android 移植能这么薄的原因：

- **参数走 JSON，像素走 buffer**——界面加滑块不需要改 FFI 签名
- **引擎不写文件**——只返回 RGBA16 像素，Dart 侧自己编码
- **两层渲染**——Layer 1（胶片/相纸/放大机）在引擎里，Layer 2（调色）留给 Flutter，滑块才能跟手

## 图标

图标是一张钢笔线条的相机插画：`design/icon/artwork.png`（裁到机身，去掉外圈文字与水印），
`python tool/gen-icon.py` 把它排到纸色底版上，一次缩放出所有密度。

| 输出 | 用途 |
|---|---|
| `design/icon/halfstop-1024.png` | 母版与商店用图 |
| `mipmap-*/ic_launcher.png` | 旧启动器（全出血方块） |
| `mipmap-*/ic_launcher_round.png` | 旧圆形启动器 |
| `mipmap-*/ic_launcher_foreground.png` | 自适应前景（透明，相机收在安全圆内） |
| `mipmap-*/ic_launcher_monochrome.png` | Android 13+ 主题图标（按墨色覆盖率反出白色线条） |

底版是插画自己的纸色 `#F2EADC`，写在 `values/colors.xml` 的 `ic_launcher_background` 里；
前景四周做了 5% 羽化，贴在纸色底上不会露出矩形接缝。所有尺寸都从插画一次性缩下来，
不要在小尺寸上重画细节——48 px 下齿孔和刻字只剩几颗点。

## 构建

需要 Flutter stable、JDK 17、Android SDK（platform 36）、**NDK 28.2.13676358**（必须带 `glslc`）、CMake 3.22.1。

```powershell
# 1. 工具链环境（或自行设置 SPK_TOOLCHAIN 指向含 flutter/ jdk/ android-sdk/ 的目录）
. .\tool\env.ps1

# 2. 拉引擎 + 编 shader（固定到上游 Windows_Linux 分支的一个 commit）
.\tool\fetch-engine.ps1      # 首次
.\tool\build-shaders.ps1     # 49 个 .comp -> SPIR-V；Gradle 也会自动跑

# 3. 跑
flutter run --release
# 或
flutter build apk --release --target-platform android-arm64
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

release（arm64）产物约 **33.6 MB**：引擎约 3.3 MB、Flutter 约 11 MB、Dart 约 4 MB、引擎数据（profile + SPIR-V + 打印 LUT）约 12 MB。

测试：`flutter test`（39 条，覆盖画幅/裁切几何、调色矩阵、测光、导入、目录）。

## 已验证

| | |
|---|---|
| 设备 | Xiaomi Redmi K40（Snapdragon 870） |
| GPU | Adreno 650，Vulkan 1.1.295，driver 512.837.7 |
| 结果 | 引擎就绪，`math=probed`，实时滑块 ~100 ms，135+片边+日期 1666×1539 约 2.1 s |

## Roadmap

- [ ] 导出 TIFF / DNG
- [ ] 曲线、色轮（Flutter fragment shader）
- [ ] 多机型验证（Mali / PowerVR / 其他 Adreno）
- [ ] 低端机降级（按 `max_storage_buffer_range` 限像素，自动降 `preview_long_edge`）

## 许可

- 引擎、胶片模型、profile：**GPL-3.0-or-later**（上游 spektrafilm 项目），任何分发版本必须以 GPLv3 开源
- 胶片/相纸 profile 与打印 LUT：**CC BY-SA 4.0**
- 本移植代码同样按 **GPL-3.0-or-later** 发布，保留上游署名
