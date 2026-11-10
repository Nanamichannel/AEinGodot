# 效果预制件怎么用

三个东西，覆盖 AE 里最常改外观的几类操作：

| 文件 | 干什么 |
|---|---|
| `shaders/preset_glow.tres` | 外发光 |
| `shaders/preset_tint.tres` | 调色 / 降饱和 / 变冷变暖 |
| `shaders/preset_displace.tres` | 湍流置换（需要一张噪声图） |
| `prefabs/particles_smoke.tscn` | 烟雾 / 漂浮粒子（循环） |
| `prefabs/particles_spark.tscn` | 迸溅光点（一次性） |

---

## 一、给任意图层加发光

1. 选中节点（`Sprite2D` / `AnimatedSprite2D` / `TextureRect` 都行）
2. 检查器 → `Material` → 点 `快速加载`（放大镜旁边那个向下箭头）→ 选
   `res://addons/ae_motion/shaders/preset_glow.tres`
3. 展开 Material，调三个参数：

| 参数 | 作用 | 起点 |
|---|---|---|
| `glow_amount` | 发光强度 | `1.4`，0 = 关 |
| `glow_color` | 发光颜色 | 暖黄 |
| `glow_radius` | 扩散范围 | `0.014`，越大越糊 |

**贴图四周要留透明边**，不然光晕会被图层边界切掉。

## 二、调色

同一个 shader，换 `preset_tint.tres`：

| 参数 | 作用 |
|---|---|
| `tint_amount` | 向目标色偏移多少（0~1） |
| `tint_color` | 目标色（暖橙、冷蓝自己选） |
| `saturation` | 1 = 原样，0 = 黑白，1.5 = 更艳 |

> `tint_amount = 1` + `saturation = 0` = 纯黑白，等价于 AE 的“去色”。

## 三、湍流置换

1. 挂 `preset_displace.tres`
2. 它需要一个噪声图：新建 `NoiseTexture2D`（`新建 Resource` → 搜 NoiseTexture2D），
   或者用你从 AE 导出的 flowmap PNG
3. 把这张图拖到 `noise_tex` 上
4. 调 `displace_amount`（0.01~0.05 起步）、`displace_scale`（越大纹越细）

没有噪声图时 `displace_amount = 0`，等于没开，不会报错。

## 四、粒子

**烟雾（持续冒）**

1. 把 `prefabs/particles_smoke.tscn` 拖进场景
2. 选中它，`texture` 拖一张粒子图进去（AE 导出的 PNG）
3. 调四个数：
   - `amount` 数量（30~80）
   - `lifetime` 存活秒数
   - `gravity`（方向向量，负 y = 往上飘）
   - `initial_velocity_min/max` 初速

**光点（迸一下）**

`particles_spark.tscn`，`one_shot = true`，用代码触发：

```gdscript
$SparkFX.restart()
```

## 五、组合

一个角色身上可以同时挂：发光材质 + 烟雾子节点 + 光点子节点。
它们互不干扰，因为改的是不同东西（像素运算 / 独立粒子）。

---

## 边界

这几个预制件**只做外观运算**，不懂 AE 的混合模式。需要 `SCREEN` / `ADD` /
`OVERLAY` 这类“和下面图层混合”的效果，仍然要用
`blend_modes.gdshaderinc`，那是另一个模式（需要 `BackBufferCopy`）。

先确认一件事：如果这个效果只是“让这层看起来更亮/更暖”，用这里的发光和调色就够，
不需要混合模式；只有“要吃掉下面的颜色”时才算混合。
