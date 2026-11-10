# 给 AI 的提示词（AE 运动 + PNG 序列 + 混合模式）

适用：AE 里有变换动画，也有调色/发光/粒子这类像素效果。
运动层给 JSON，效果层给 PNG 序列，混合模式口头说明。

---

## 复制这段给 AI

```
【目标】在 Godot 4 里重建一个 AE 合成的效果，我给它数据和素材，你负责还原。

【输入】
1. res://ae_motion/<合成名>.json
   AE 导出的运动数据，格式说明在 res://ae_motion/ae-motion.md，先读它。
2. res://art/Motion/*.png
   运动层用的贴图，文件名对应 json 里 layers[].name。
3. res://art/Frames/<层名>/0000.png ~ NNNN.png
   效果层的序列帧，一层一个文件夹，60fps。
4. res://addons/ae_motion/blend_modes.gdshaderinc
   22 种 AE 混合模式的实现，直接用，不要自己写公式。

【A. 运动层（全部来自 json，不许自己算）】
A1. 坐标是父级空间：按 parent 字段建父子节点，子节点 position 用 json 原值。
    不要拍平，不要手动加父偏移，不要自己换算世界坐标。
A2. z 是 AE 图层序号，1 在最上面。Godot 里 z_index = -z，
    或按 z 从大到小添加节点（先加最底）。不许按"z 大在上"建。
A3. 贴图摆放只有这一条公式：
      sprite.centered = false
      sprite.offset = -(Vector2(anchor) - Vector2(Wjson - Wpng, Hjson - Hpng))
    anchor 可能是负数、可能落在图层边界外，原样代入，不许 clamp、不许取绝对值。
A4. 时间单位是毫秒，除以 1000 变秒。采样点已是最终结果，线性插值，
    不要再套贝塞尔。
A5. rotation 是度，乘 PI/180。scale 是比值（1.0 = 100%）。alpha 是 0..1。
A6. alpha 驱动 self_modulate.a，不许用 modulate（AE 不透明度不向下继承）。
A7. isStatic = true 的层整段不动，不要给它建动画轨道。
A8. inPoint / outPoint 之外的区间，不要让那层出现。

【B. 效果层（PNG 序列）】
B1. 一层一个 AnimatedSprite2D（或 Sprite2D + 手写换帧），帧率 60fps，
    文件名按 0000.png 递增。
B2. 序列帧的尺寸 = 合成尺寸（1920×1080），直接放在 (0,0)，
    centered = false，不要缩放。
B3. 循环的层设 loop，不循环的停在末帧。
B4. 序列帧占内存，不要一次性全部 preload，用 SpriteFrames 或按需加载。

【C. 混合模式层】
C1. blend.mode 不是 NORMAL 的层，必须：
      ColorRect / Sprite2D + ShaderMaterial(#include blend_modes.gdshaderinc)
      + 前面一个 BackBufferCopy（同一 CanvasLayer，树里排在它之前）
C2. 合成公式只能是：
      out = mix(backdrop, blend(backdrop, source), src_alpha * layer_opacity)
    透明度在混合之后插值。写成 blend(cb, cs * opacity) 是错的。
C3. channelPlan = "multiplier" 的层，纹理初始值填 1.0，不是 0.0。
C4. blend.group 相同的层属于同一个合成上下文，BackBufferCopy 按组插入。
C5. HUE / SATURATION / COLOR / LUMINOSITY 四族没有逐层实现，必须预合成。

【D. 层序】
D1. 同一份 json 里的层，按 z 排。
D2. 我口头给你的效果层，按我说的位置插进这个序列（例如"这两块纯色在最上面，
    z 比 json 里所有层都小"）。
D3. 最终顺序必须写成一张表给我确认。

【E. 先别写代码】
先输出两张表：
1. 层序表：从上到下 | 层名 | 来源(json/PNG序列) | 混合模式 | 节点类型 | 贴图/序列路径
2. 运动表：有动画的层 | 生成方式(导入JSON/手写) | 轨道数与关键帧数
我确认后再实现。

【F. 交付与自检】
- 一个场景，层级和上面两张表一致
- 一个 AnimationPlayer（运动层），AnimatedSprite2D 各自播（效果层）
- 自检逐条回答：节点数对不对｜贴图/序列全找到了吗｜父级链和 json 一致吗｜
  静态层有没有被误加轨道｜anchor 有没有被 clamp｜混合层前面有没有 BackBufferCopy
```

---

## 什么时候还是该用导入器

| 情况 | 建议 |
|---|---|
| 运动层 > 10 个，或关键帧 > 1000 | 用导入器。手搓必错，错在父子/锚点/z 序 |
| 3~5 个简单层，无父子 | 直接让 AI 写，省一步 |
| 有混合/序列帧 | 导入器不参与，反正都要 AI 补 |

导入器生成的是**骨架**，你照样可以在这个骨架上加效果层——两者不冲突，
不用二选一。

---

## 三个必须口头交代、json 里没有的东西

1. **效果层的 z 位置**：PNG 序列不在 json 里，它和运动层的上下关系只有你知道
2. **混合模式**：json 只记了 AE 的枚举，为什么这么叠、要不要近似，得你说
3. **循环与触发的时机**：哪段循环、哪段一次性、点击后播哪段
