# 半档 / Halfstop

Android 上的物理胶片模拟相机后期应用。Flutter 前端 + Spektrafilm 的 C++20 / Vulkan 渲染引擎，通过 `dart:ffi` 直接跑在手机上——没有 Python，没有服务端，没有 LUT 近似，光谱计算、coupler、颗粒、光晕全部在 GPU 上现场算。

![引擎自检](docs/engine-selftest.png)

## 功能

**胶片模拟**

- 28 个胶片 profile（光谱实测数据，非风格化 LUT）：25 款拍摄胶片、7 款相纸、2 款电影拷贝片（2383 / 2393）
- 相纸决定纸基色调与反差，拷贝片走「先翻底再印片」的电影流程——分类来自 profile 自带的 `stage` / `support` 字段
- 模拟强度：原图与成片线性混合，导出按同一算式烘进 JPEG，拖到 40% 导出的就是 40%

**画幅与构图**

- 10 种画幅：135 / 半格 / XPan / 645 / 6×6 / 6×7 / 6×8 / 6×9 / 6×12 / 6×17
- 裁切采用常规修图交互：画幅框固定不动，双指缩放照片、单指拖动构图，缩放倍率实时显示
- 开启「片边与齿孔」时画面自动回到片门形状（胶片边缘画出来时片门必须是真的）
- 片边与齿孔：整条胶片边缘、上下齿孔（白/黑）、片基外（无/黑场/透光）、边雾与漏光；边字与帧号来自 profile，不是画的
- 日期后背：把日期烧进画面或片边，三种字面（液晶/点阵/数据）

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
