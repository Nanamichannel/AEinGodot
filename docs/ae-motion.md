# ae-motion 1.0 —— AE 运动数据 → Godot 交接包

四个文件，各管一件事：

| 文件 | 是什么 | 能不能跑 |
|---|---|---|
| `ae\export-motion-engine.jsx` | AE 脚本，跑完直接写 JSON | 能，AE 里直接跑 |
| `blend_modes.gdshaderinc` | Godot 4 着色器函数库（22 种混合） | 能，`#include` 即用 |
| `ae-motion.md`（本文件） | 字段表 + 混合对照 + 接线方法 + 坑 | 文档 |
| `example_start_screen.json` | 一份格式样例，喂 AI 当参照 | 数据 |

**这份文档就是 schema。** 它规定字段名、单位、合法值。AI 读它 + 读 JSON + 读 shader，就能把动画接起来，不需要猜。

---

## 1. 怎么用

1. AE 里打开合成 → `文件 > 脚本 > 运行脚本文件` → 选 `ae\export-motion-engine.jsx`
2. 首次使用：`编辑 > 首选项 > 脚本和表达式` → 勾选**「允许脚本写入文件和访问网络」**
3. 跑完弹窗会给出完整路径，JSON 直接落在本目录：`AE-Motion-Export\<合成名>.json`（UTF-8 无 BOM，不需要碰剪贴板或记事本）
4. 采样率改脚本顶部 `CONFIG.sampleFps`（默认 60）；不要静态层就把 `includeStatic` 改 `false`；换输出目录改 `CONFIG.outputDir`

**一个合成 = 一个 clip。** 点击后的转场在 AE 里另做一个合成、另跑一次脚本，得到第二个 JSON。引擎侧按名字切 clip，不需要把整条时间线塞进一个文件。

---

## 2. 字段表

### 顶层

| 字段 | 类型 | 说明 |
|---|---|---|
| `format` | string | 固定 `"ae-motion/1"` |
| `mode` | string | 固定 `"engine"`（区别于 uSpec 给 Figma 用的表格模式） |
| `space` | string | `"parent"`：track 在父级空间，引擎要照原样重建层级，**不要拍平** |
| `clip.name` | string | 合成名，建议直接当动画名 |
| `clip.fps` | number | 合成帧率 |
| `clip.sampleFps` | number | 实际采样率。大合成会自动降采样，以这个为准 |
| `clip.length` | number | 秒 |
| `clip.comp` | `{width,height}` | 合成尺寸，换算坐标用 |
| `units` | object | px / deg / ratio / 0..1 / ms，全部写死在这里 |
| `layers` | array | 按 AE 图层顺序（1 = 最前/最上，数字越大越靠后） |
| `unsupported` | array | `{layer, feature, policy}`，**必读**：这些功能没导 |
| `notes` | array | 给 AI 的硬约束，原文照抄给它 |

### 图层

| 字段 | 说明 |
|---|---|
| `id` | `"<序号>-<图层名>"`，做引擎侧绑定键。改图层顺序会变，重导入要按名字对齐 |
| `index` / `z` | AE 图层序号，**1 在最上（最前）**，数字越大越靠后。Godot 里 z_index = -z，或按 z 从大到小添加子节点 |
| `name` | 图层名 |
| `type` | `image` / `precomp` / `text` / `shape` / `solid` / `null` / `adjustment` / `camera` / `light` |
| `parent` | 父层 `index` 或 `null` |
| `inPoint` / `outPoint` | 图层有效期（秒）。超出这个范围的层，引擎不要给它发动画指令 |
| `enabled` | AE 眼睛图标 |
| `asset` | `{source, left, top, width, height, anchor}`：源名、图层边界（`sourceRectAtTime` 的 left/top/宽/高）、锚点（源像素坐标）。`left/top` 通常是 0，文字层或带偏移的素材不为 0 |
| `origin` | 第 0 帧的位置，参考用；实际位置看 track |
| `blend` | 见下节 |
| `trackMatte` | `{type, source}`：`ALPHA` / `ALPHA_INVERTED` / `LUMA` / `LUMA_INVERTED`；source 是**上方**那层的 index |
| `neutral` | `{mul, add}`：乘数/加法通道的中性值。**初始化纹理必须填这个值** |
| `channelPlan` | `rgba` 整层 / `multiplier` 只走一通道乘数 |
| `isStatic` | true 表示整段不动，`tracks` 里只有 1 个采样点 |
| `firstLastDelta` | 首末帧差（px / deg / ratio / 0..1）。做循环时看它，不为 0 就会跳 |
| `threeD` / `timeRemap` / `effectCount` / `maskCount` | 特性标记，对应 `unsupported` 条目 |

### tracks

四种通道，都是 `[[毫秒, 值...], ...]` 的数组：

| 通道 | 每行 | 单位 |
|---|---|---|
| `position` | `[t, x, y]` | px（父级空间，原点在父级左上角） |
| `rotation` | `[t, deg]` | 度，顺时针为正（AE 与 Godot 2D 同向，**不用取负**） |
| `scale` | `[t, sx, sy]` | 比值，`1.0 = 100%`（AE 的 100 已经除过了） |
| `alpha` | `[t, a]` | `0..1`（AE 的 100 已经除过了） |

引擎侧一律**线性插值**即可——采样点已经是最终结果，不要再套贝塞尔。

---

## 3. 混合模式对照表

`blend.mode` 是 AE 原名，`blend.role` 是家族分类（写代码按家族分派少出错），`shader` 是 `blend_modes.gdshaderinc` 里的常量名。

| AE 模式 | role | shader 常量 | 备注 |
|---|---|---|---|
| 正常 Normal | normal | `AE_BLEND_NORMAL` | Godot 原生 `blend_mix` 就够，不必上 shader |
| 正片叠底 Multiply | multiply | `AE_BLEND_MULTIPLY` | 也可走 `channelPlan=multiplier` 一通道 |
| 滤色 Screen | screen | `AE_BLEND_SCREEN` | Godot 原生 `blend_add` 近似，但不完全等价 |
| 叠加 Overlay | contrast | `AE_BLEND_OVERLAY` | 必须 shader |
| 柔光 Soft Light | contrast | `AE_BLEND_SOFT_LIGHT` | W3C 公式 |
| 强光 Hard Light | contrast | `AE_BLEND_HARD_LIGHT` | = overlay 参数互换 |
| 亮光 Vivid Light | contrast | `AE_BLEND_VIVID_LIGHT` | |
| 线性光 Linear Light | contrast | `AE_BLEND_LINEAR_LIGHT` | |
| 点光 Pin Light | contrast | `AE_BLEND_PIN_LIGHT` | |
| 实色混合 Hard Mix | contrast | `AE_BLEND_HARD_MIX` | |
| 变暗 Darken | multiply | `AE_BLEND_DARKEN` | |
| 变亮 Lighten | screen | `AE_BLEND_LIGHTEN` | |
| 颜色加深 Color Burn | multiply | `AE_BLEND_COLOR_BURN` | |
| 线性加深 Linear Burn | multiply | `AE_BLEND_LINEAR_BURN` | 你上次用过的那种 |
| 颜色减淡 Color Dodge | screen | `AE_BLEND_COLOR_DODGE` | |
| 线性减淡 Linear Dodge | screen | `AE_BLEND_LINEAR_DODGE` | = 相加 |
| 差值 Difference | difference | `AE_BLEND_DIFFERENCE` | |
| 排除 Exclusion | difference | `AE_BLEND_EXCLUSION` | |
| 减去 Subtract | difference | `AE_BLEND_SUBTRACT` | |
| 划分 Divide | difference | `AE_BLEND_DIVIDE` | |
| 较暗 Color Darker | multiply | `AE_BLEND_DARKER_COLOR` | 按亮度选通道 |
| 较亮 Color Lighter | screen | `AE_BLEND_LIGHTER_COLOR` | |
| 色相/饱和度/颜色/明度 | color | **没有** | 逐层做不对，必须在 AE 里预合成 |
| Classic_* 变体 | 同基名 | 同基名 | 只是色彩空间不同，见第 5 节 |
| 模板 Alpha/亮度、轮廓 Alpha/亮度 | special | **没有** | 用 `CanvasGroup` + 蒙版实现 |
| 溶解 Dissolve | special | **没有** | 随机噪点，建议烘帧 |

---

## 4. Godot 侧怎么接

### 节点结构

```
BlendedSprite (Sprite2D)          ← 挂 shader，读 screen_tex
BackBufferCopy                    ← 必须在这层之前，同 canvas 内，copy_mode = Rect
```

`BackBufferCopy` 缺失时 `hint_screen_texture` 采到的是空白/上一帧，表现为“整块变黑或变亮”——这是这类效果最常见的翻车点。

### 写一个混合 sprite 的 shader

```glsl
shader_type canvas_item;
#include "res://addons/ae_motion/blend_modes.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform int blend_mode = 3;        // AE_BLEND_OVERLAY
uniform float layer_opacity = 1.0;

void fragment() {
    vec4 src = texture(TEXTURE, UV) * COLOR;
    vec3 bg  = texture(screen_tex, SCREEN_UV).rgb;
    vec3 out_rgb = ae_composite(bg, src.rgb, src.a * layer_opacity, blend_mode);
    COLOR = vec4(out_rgb, 1.0);    // 已经合成完了，alpha 给 1
}
```

### 公式顺序（写错必发灰）

```
out = mix(backdrop, blend(backdrop, source), src_alpha * layer_opacity)
```

透明度在**混合之后**插值。写成 `blend(cb, cs * opacity)` 就是错的。

### 裁剪 PNG 的摆放（left/top 在这里用）

PS 里按图层导出 PNG 时会裁掉空白，图变成 `width×height`。摆放公式只有一条：

```gdscript
sprite.centered = false
sprite.offset = -(Vector2(anchor) - Vector2(left, top))   # left/top 通常为 0
sprite.position = 位移动画值
```

`anchor` 可能落在图层边界外面（AE 里可以把锚点拖出去），公式照样成立，不要自己 clamp。
**前提：PNG 的尺寸必须等于 json 里的 `width×height`**。导出后随便挑一张对一下尺寸，不一致就是裁剪方式和 AE 不一致。
### 透明度继承

AE 的图层 Opacity **不向下继承**，Godot 的 `modulate` **会**。所以 alpha track 请驱动 `self_modulate.a`，不要驱动 `modulate.a`。

### 预算

每个读屏幕的图层要多一次全屏 copy。5 个混合层在 1080p 桌面端无所谓，Web 导出会掉帧。混合层控制在 3 层以内，其余要么预合成，要么用 `CanvasGroup` 打包。

---

## 5. 五个必踩的坑

1. **色彩空间**：AE 2024+ 默认线性空间混合，Godot 2D 默认 sRGB。同一个 Overlay 两边肉眼看得出差别。**AE 里统一用 Classic 变体**（脚本已经把 `blend.classic` 置 true），别混着用。
2. **中性值必须是 1.0**：`channelPlan=multiplier` 的层，纹理初始化填 `1.0`。填 0 就是整屏黑——你上次“换段黑一帧”就是这个。脚本已经在 `neutral.mul` 里写死 1.0。
3. **采样率**：默认 60。引擎若跑 120Hz，60 的采样线性插值依然平滑；但快速旋转的弧线在 30 采样下会看出折线。做飞行轨迹建议 60。
4. **预合成不递归**：`type=precomp` 的层只导外层变换，内部图层动画拿不到。要做角色绑定，先在 AE 里把内部动画烘成一层，或者按图层拆成多个导出。
5. **`firstLastDelta` 不为 0 就是循环跳帧**。待机循环类 clip 交付前检查这一项，比进引擎肉眼看快得多。

---

## 6. 验收清单（照抄你复盘里的习惯）

- [ ] JSON 能被解析，`format` 是 `ae-motion/1`
- [ ] 层数和 AE 图层面板一致（含隐藏层，看 `enabled`）
- [ ] 每个动了的通道，`tracks` 采样数 ≈ `clip.length × clip.sampleFps`
- [ ] 静止层 `isStatic=true` 且只有 1 个采样点
- [ ] `unsupported` 每一条都确认过处理方式（放弃 / 烘帧 / 重写）
- [ ] 待机循环 clip 的 `firstLastDelta` 全为 0（或已确认可接受）
- [ ] Godot 里第一帧不是黑屏（`neutral` 生效）
- [ ] 混合层切 clip 时无一帧闪黑（BackBufferCopy 在树中的位置正确）
- [ ] 1080p 下 ≥200fps（混合层多了会掉）
