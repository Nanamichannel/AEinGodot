# AE in Godot

把 After Effects 里做好的动画，变成 Godot 里能直接播放的场景。

核心思路：**AE 里做动画，Godot 里做交互。** AE 的表达式、缓动、父子、锚点这些东西，不在引擎里重算，而是逐帧烘焙成数值——引擎只负责按时播放和响应鼠标。

- 支持：位置 / 旋转 / 缩放 / 不透明度动画，任意父子层级，任意表达式，锚点动画
- 不支持（会明确标注）：预合成内部动画、混合模式、3D 图层、粒子
- 引擎：Godot 4.4+（开发和验证用的是 4.7.2）

---

## 组成

| 路径 | 是什么 |
|---|---|
| `ae/export-motion-engine.jsx` | AE 脚本，把当前合成导成 JSON |
| `ae/check-anim.jsx` | 诊断脚本，列出每个图层的关键帧数量（排查"动画导不出来"） |
| `addons/ae_motion/` | Godot 插件，读 JSON 生成场景 + AnimationPlayer |
| `addons/ae_motion/blend_modes.gdshaderinc` | 22 种 AE 混合模式的 GLSL 实现（插件不自动用，交给 AI/手工） |
| `docs/ae-motion.md` | 数据格式说明：字段、单位、坐标、贴图摆放公式 |
| `docs/AI规则.md` | 交给 AI 时的常驻约束（把踩过的坑全写进去了） |

---

## 快速开始

### 1. AE 导出

1. AE 里打开要导的合成（**合成面板里当前显示的那个**，不是项目面板里选中的）
2. 首次：`编辑 > 首选项 > 脚本和表达式` → 勾选「允许脚本写入文件和访问网络」
3. `文件 > 脚本 > 运行脚本文件` → 选 `ae/export-motion-engine.jsx`

JSON 会写到脚本里 `CONFIG.outputDir` 指定的目录（默认：桌面的 `AE-Motion-Export`），文件名 = 合成名。

### 2. Godot 装插件

1. 把 `addons/ae_motion` 复制到你的工程根目录（和 `project.godot` 同级）
2. `项目 > 项目设置 > 插件` → 启用 **AE Motion**
3. 编辑器右侧出现「AE Motion」面板

> 文件夹必须在 `addons/` 下面。放在工程根目录的 `ae_motion/` 是认不出来的。

### 3. 面板里选三项

| 行 | 选什么 |
|---|---|
| AE 导出的 json | 上一步生成的 json，可以在工程外面 |
| 素材目录（项目内） | PNG 所在文件夹，必须在 `res://` 下 |
| 输出场景（项目内） | 自动填 `res://generated/<名字>.tscn`，可以改 |

三项齐了自动生成，生成完自动打开，`F6` 播放。

素材必须在工程内，因为 Godot 只能加载导入过的纹理。先把 PNG 文件夹复制进工程，等导入完成再选。

---

## 数据长什么样

```json
{
  "format": "ae-motion/1",
  "clip": { "name": "开始界面", "fps": 60, "length": 30.0, "comp": { "width": 1920, "height": 1080 } },
  "layers": [{
    "index": 6, "z": 6, "name": "人物3", "parent": 5,
    "asset": { "source": "人物3/开始页面.psd", "left": 0, "top": 0, "width": 255, "height": 382, "anchor": [127.5, 191] },
    "blend": { "mode": "NORMAL", "role": "normal", "group": 1 },
    "isStatic": false,
    "tracks": {
      "position": [[0, 228.5, 740.07], [17, 228.4, 731.2]],
      "rotation": [[0, 0]],
      "scale": [[0, 1, 1]],
      "alpha": [[0, 1]]
    }
  }]
}
```

几个关键约定（完整见 `docs/ae-motion.md`）：

- 时间单位 **毫秒**，playback 时除以 1000
- 坐标是**父级空间**，按 `parent` 重建层级，不要拍平
- `z` 是 AE 图层序号，**1 在最上面**，引擎里用 `z_index = -z`
- 旋转是**度**，缩放是**比值**（1.0 = 100%），透明度是 0..1
- 采样点已经是最终结果，**线性插值**即可，不要再套贝塞尔

---

## 为什么要烘焙，而不是导出关键帧曲线

AE 的缓动用「影响 / 速度」表示，Godot 用贝塞尔控制点，Unity 用 inSlope/outSlope——四套语义互不通，任何"翻译"都会在多维属性上翻车。

逐帧采样是唯一无损、且不需要引擎做任何判断的表示方式。代价是文件大一点（30 秒 × 24 层 ≈ 300 KB），换来的是"打开就对"。

---

---

## 序列帧层（效果 / 粒子 / 辉光）

有些东西参数化不了，只能在 AE 里做成像素。这类层用命名约定标记，**像素走 PNG 序列，运动和层级照样走 json**：

1. AE 里把图层改名，结尾加 `#fx`，例如 `粒子_风#fx`
2. 渲染 PNG 序列（RGB+Alpha、直通 alpha、60fps、`0000.png` 递增），放进
   `res://<素材目录>/Frames/粒子_风/`
3. 导出 json —— 这一层会带 `"frames": "粒子_风"`

插件遇到带 `frames` 的层会建 `AnimatedSprite2D`：帧率取 `clip.sampleFps`、循环播放、
`centered = false`、`offset = -anchor`，然后 position / rotation / scale / alpha 轨道照常套用。

面板上「序列帧目录」留空时默认是 `<素材目录>/Frames`。

> 渲染时记得：只渲染这一层（其他层独奏关闭）、用区域渲染裁到效果边界。全屏烘帧会爆显存：
> 1920×1080 RGBA 每帧 8.3MB，60 帧就是 500MB。

## 效果预制件

AE 里那些“只是让画面变好看”的操作，不用烘帧，挂材质就行：

| 想做的事 | 用什么 |
|---|---|
| 外发光 | `shaders/preset_glow.tres`，调 `glow_amount` |
| 调色 / 去色 | `shaders/preset_tint.tres`，调 `tint_amount` + `saturation` |
| 湍流置换 | `shaders/preset_displace.tres` + 一张噪声图 |
| 烟雾飘散 | `prefabs/particles_smoke.tscn`（循环） |
| 迸溅光点 | `prefabs/particles_spark.tscn`（`restart()` 触发） |

用法：选中节点 → 检查器 Material → 快速加载 → 选预设 → 调参数。
详见 `addons/ae_motion/FX使用说明.md`。

判断标准只有一条：**这层的像素会不会自己“长”出新形状？**
不会 → 挂材质；会 → 粒子或短循环序列帧。
## 已知限制

| 限制 | 说明 |
|---|---|
| 预合成不递归 | `type: "precomp"` 的层只导外层变换，内部动画要在 AE 里摊平 |
| 混合模式 | 导出端记录 `blend.mode`，但插件**不实现**。生成时会在日志里警告。要用就自己接 `blend_modes.gdshaderinc` |
| 锚点动画 + 旋转 | 锚点动画已烘进位置轨道，但旋转轴心没跟着变，两者同时动会有偏差 |
| 3D 图层 | 只取 Z 轴旋转，X/Y 旋转和摄像机投影不处理 |
| 粒子 / 辉光 / 湍流 | 外观是运行时生成的，只能烘帧序列或在引擎里重写 |

---

## 排错

| 现象 | 原因 |
|---|---|
| 插件列表是空的 | `addons/ae_motion/plugin.cfg` 不在 `addons/` 下；或者复制后没 `项目 > 重新加载当前项目` |
| `Parse Error` | 用记事本改过 `.gd`，把制表符变成了空格；或者字符串里写了 `N:\...`（`\` 是转义符，要用 `res://` 或正斜杠） |
| 动画层数量不对 | AE 那边的问题：跑一次 `ae/check-anim.jsx`，它会列出每层的关键帧数 |
| 人物不动 | 动画可能做在**锚点**上而不是位置上。本脚本会把锚点动画烘进位置轨道，但旧版 JSON 没有 |
| 贴图全是空白 | 图层名和 PNG 文件名对不上。插件会做归一化（去空格/横线/下划线/点）并列出缺的名字 |
| 画面被裁掉一半 | 项目窗口尺寸和合成不一致，`项目设置 > 显示 > 窗口` 设成同样尺寸，拉伸模式 `canvas_items`、比例 `keep` |
| 生成的场景会被覆盖 | 设计如此。要加东西就外层包一个主场景，用「实例化子场景」引用它 |

---

## 和 AI 配合

`docs/` 里两份文档就是给 AI 的：

- `ae-motion.md` —— 数据格式、单位、贴图摆放公式
- `AI规则.md` —— 表现层的硬约束：锚点不能 clamp、透明度用 `self_modulate`、时间要除 1000、静态层不建轨道、别自己发明交互

喂 AI 时连同 json 和 PNG 一起给，然后用人话提需求。规则文件里每一条都是从真实的返工里挖出来的。

---

## License

MIT
