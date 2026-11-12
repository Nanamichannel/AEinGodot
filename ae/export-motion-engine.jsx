/*
 * export-motion-engine.jsx
 *
 * Exports the ACTIVE composition as "ae-motion/1" JSON for a game engine
 * (written for Godot 4, usable elsewhere). Unlike the uSpec script, this one
 * is built for playback, not for a Figma annotation table:
 *
 *   - per-frame sampled transform tracks (position / rotation / scale / alpha)
 *   - layers that never animate are included, so the engine knows where things sit
 *   - blend mode, track matte, anchor, source size, z order, parenting
 *   - explicit neutral values for multiply-style channels
 *   - an "unsupported" list instead of silently dropping features
 *
 * Usage:
 *   File > Scripts > Run Script ...  (a composition must be active)
 *   Writes <CONFIG.outputDir>/<composition name>.json  (UTF-8, no BOM)
 *   and shows a summary alert with the exact path.
 *
 * Requirements:
 *   Edit > Preferences > Scripting & Expressions >
 *     "Allow Scripts to Write Files and Access Network"  must be ON
 *
 * Units and space (see ae-motion.md):
 *   position px, rotation degrees, scale ratio (1.0 = 100%), alpha 0..1
 *   tracks are in PARENT space (AE's own transform semantics), so the engine
 *   can rebuild the same node hierarchy instead of flattening it.
 *
 * Version: 1.0  (flat layer list; precomps are not recursed into)
 */

(function () {

    // ------------------------------------------------------------------
    // CONFIG
    // ------------------------------------------------------------------

    var CONFIG = {
        sampleFps: 60,      // 30 / 60 / 120 - bake rate
        includeStatic: true, // keep layers that never animate
        maxSamples: 6000,   // down-sample above this many frames
        // One JSON per composition lands here, named after the composition.
        outputDir: "N:/媒体/AfterEffects/AE-Motion-Export"
    };

    // ------------------------------------------------------------------
    // 1. Validate
    // ------------------------------------------------------------------

    var comp = app.project.activeItem;
    if (!(comp instanceof CompItem)) {
        alert("export-motion-engine\n\nNo active composition found.\nOpen a composition and run the script again.");
        return;
    }

    // ------------------------------------------------------------------
    // 2. Small helpers
    // ------------------------------------------------------------------

    function flattenShape(shape) {
        if (!shape || !shape.vertices) return [];
        var v = shape.vertices;
        var it = shape.inTangents;
        var ot = shape.outTangents;
        var closed = shape.closed;
        var out = [];
        var n = v.length;
        var segs = closed ? n : n - 1;
        var TOL = 0.4;          // 允许的最大偏差（像素）
        var MAX_DEPTH = 7;

        function subdivide(p0, c1, c2, p3, depth) {
            var dx = p3[0] - p0[0], dy = p3[1] - p0[1];
            var len2 = dx * dx + dy * dy;
            // 控制点到弦的距离，够平就直接收
            function dist(pt) {
                if (len2 < 1e-9) {
                    var ax = pt[0] - p0[0], ay = pt[1] - p0[1];
                    return Math.sqrt(ax * ax + ay * ay);
                }
                var t2 = ((pt[0] - p0[0]) * dx + (pt[1] - p0[1]) * dy) / len2;
                t2 = Math.max(0, Math.min(1, t2));
                var qx = p0[0] + t2 * dx, qy = p0[1] + t2 * dy;
                var ex = pt[0] - qx, ey = pt[1] - qy;
                return Math.sqrt(ex * ex + ey * ey);
            }
            if (depth >= MAX_DEPTH || (dist(c1) <= TOL && dist(c2) <= TOL)) {
                out.push([Math.round(p3[0] * 10) / 10, Math.round(p3[1] * 10) / 10]);
                return;
            }
            // de Casteljau 一分为二
            var m01 = [(p0[0] + c1[0]) / 2, (p0[1] + c1[1]) / 2];
            var m12 = [(c1[0] + c2[0]) / 2, (c1[1] + c2[1]) / 2];
            var m23 = [(c2[0] + p3[0]) / 2, (c2[1] + p3[1]) / 2];
            var m012 = [(m01[0] + m12[0]) / 2, (m01[1] + m12[1]) / 2];
            var m123 = [(m12[0] + m23[0]) / 2, (m12[1] + m23[1]) / 2];
            var mid = [(m012[0] + m123[0]) / 2, (m012[1] + m123[1]) / 2];
            subdivide(p0, m01, m012, mid, depth + 1);
            subdivide(mid, m123, m23, p3, depth + 1);
        }

        for (var i = 0; i < segs; i++) {
            var i2 = (i + 1) % n;
            var p0 = v[i], p3 = v[i2];
            var c1 = [p0[0] + ot[i][0], p0[1] + ot[i][1]];
            var c2 = [p3[0] + it[i2][0], p3[1] + it[i2][1]];
            out.push([Math.round(p0[0] * 10) / 10, Math.round(p0[1] * 10) / 10]);
            subdivide(p0, c1, c2, p3, 0);
        }
        // 着色器 uniform 上限 512，超过就等间隔抽稀
        if (out.length > 480) {
            var step2 = out.length / 480;
            var slim = [];
            for (var k = 0; k < 480; k++) slim.push(out[Math.floor(k * step2)]);
            out = slim;
        }
        return out;
    }

    function maskModeName(maskGroup) {
        try {
            var m = maskGroup.property("ADBE Mask Mode");
            if (!m) return "ADD";
            var v = m.value;
            if (v === MaskMode.SUBTRACT) return "SUBTRACT";
            if (v === MaskMode.INTERSECT) return "INTERSECT";
            if (v === MaskMode.LIGHTEN) return "LIGHTEN";
            if (v === MaskMode.DARKEN) return "DARKEN";
            if (v === MaskMode.DIFFERENCE) return "DIFFERENCE";
            return "ADD";
        } catch (e) { return "ADD"; }
    }

    function maskInverted(maskGroup) {
        try {
            var inv = maskGroup.property("ADBE Inverted Mask");
            return inv ? (inv.value === true) : false;
        } catch (e) { return false; }
    }

    function layerNameList(list) {
        var names = [];
        for (var i = 0; i < list.length; i++) {
            var nm = list[i].name;
            var flag = "";
            try { if (list[i].enabled === false) flag = "  [hidden]"; } catch (e) {}
            names.push((i + 1) + ". " + nm + flag);
            if (i >= 13) { names.push("... total " + list.length); break; }
        }
        return names.join("\n");
    }

    function r4(n) {
        if (typeof n !== "number" || isNaN(n) || !isFinite(n)) return 0;
        return Math.round(n * 10000) / 10000;
    }

    function quote(str) {
        var s = String(str);
        var out = "\"";
        for (var i = 0; i < s.length; i++) {
            var c = s.charAt(i);
            var code = s.charCodeAt(i);
            if (c === "\"") out += "\\\"";
            else if (c === "\\") out += "\\\\";
            else if (c === "\n") out += "\\n";
            else if (c === "\r") out += "\\r";
            else if (c === "\t") out += "\\t";
            else if (code < 32) out += "\\u" + ("0000" + code.toString(16)).slice(-4);
            else out += c;
        }
        return out + "\"";
    }

    function isArr(v) {
        return v instanceof Array;
    }

    function isNumberRow(v) {
        if (!isArr(v)) return false;
        for (var i = 0; i < v.length; i++) {
            if (typeof v[i] !== "number") return false;
        }
        return true;
    }

    function isNumberRowArray(v) {
        if (!isArr(v) || v.length === 0) return false;
        for (var i = 0; i < v.length; i++) {
            if (!isNumberRow(v[i])) return false;
        }
        return true;
    }

    // Minimal JSON writer (AE runs ES3: no native JSON).
    function toJson(v, depth) {
        var pad = "";
        var i;
        for (i = 0; i < depth; i++) pad += "  ";
        var pad2 = pad + "  ";

        if (v === null || typeof v === "undefined") return "null";
        if (typeof v === "number") return String(r4(v));
        if (typeof v === "boolean") return v ? "true" : "false";
        if (typeof v === "string") return quote(v);

        if (isArr(v)) {
            if (v.length === 0) return "[]";
            // sample tracks: [[t,a,b],...] and [[t,a],...] stay on one line
            if (isNumberRowArray(v)) {
                var rows = [];
                for (i = 0; i < v.length; i++) {
                    var row = [];
                    for (var j = 0; j < v[i].length; j++) row.push(String(r4(v[i][j])));
                    rows.push("[" + row.join(",") + "]");
                }
                return "[" + rows.join(",") + "]";
            }
            var items = [];
            for (i = 0; i < v.length; i++) items.push(pad2 + toJson(v[i], depth + 1));
            return "[\n" + items.join(",\n") + "\n" + pad + "]";
        }

        var keys = [];
        for (var k in v) {
            if (v.hasOwnProperty(k)) keys.push(k);
        }
        if (keys.length === 0) return "{}";
        var lines = [];
        for (i = 0; i < keys.length; i++) {
            lines.push(pad2 + quote(keys[i]) + ": " + toJson(v[keys[i]], depth + 1));
        }
        return "{\n" + lines.join(",\n") + "\n" + pad + "}";
    }

    function propValue(group, matchName, t) {
        var p = null;
        try {
            p = group.property(matchName);
        } catch (e) {
            return null;
        }
        if (!p) return null;
        try {
            return p.valueAtTime(t, false);
        } catch (e) {
            return null;
        }
    }

    function propStatic(group, matchName, fallback) {
        var p = null;
        try {
            p = group.property(matchName);
        } catch (e) {
            return fallback;
        }
        if (!p) return fallback;
        try {
            return p.value;
        } catch (e) {
            return fallback;
        }
    }

    // ------------------------------------------------------------------
    // 3. Enums -> strings
    // ------------------------------------------------------------------

    var BLEND_NAMES = [
        "NORMAL", "DISSOLVE", "DARKEN", "MULTIPLY", "COLOR_BURN",
        "CLASSIC_COLOR_BURN", "LINEAR_BURN", "DARKER_COLOR", "LIGHTEN",
        "SCREEN", "COLOR_DODGE", "CLASSIC_COLOR_DODGE", "LINEAR_DODGE",
        "LIGHTER_COLOR", "OVERLAY", "SOFT_LIGHT", "HARD_LIGHT",
        "LINEAR_LIGHT", "VIVID_LIGHT", "PIN_LIGHT", "HARD_MIX",
        "DIFFERENCE", "CLASSIC_DIFFERENCE", "EXCLUSION", "SUBTRACT",
        "DIVIDE", "HUE", "SATURATION", "COLOR", "LUMINOSITY",
        "STENCIL_ALPHA", "STENCIL_LUMA", "SILHOUETTE_ALPHA",
        "SILHOUETTE_LUMA", "ALPHA_ADD", "ADD"
    ];

    var BLEND_ROLES = {
        NORMAL: "normal",
        DISSOLVE: "special",
        DARKEN: "multiply",
        MULTIPLY: "multiply",
        COLOR_BURN: "multiply",
        CLASSIC_COLOR_BURN: "multiply",
        LINEAR_BURN: "multiply",
        DARKER_COLOR: "multiply",
        LIGHTEN: "screen",
        SCREEN: "screen",
        COLOR_DODGE: "screen",
        CLASSIC_COLOR_DODGE: "screen",
        LINEAR_DODGE: "screen",
        LIGHTER_COLOR: "screen",
        ADD: "screen",
        OVERLAY: "contrast",
        SOFT_LIGHT: "contrast",
        HARD_LIGHT: "contrast",
        LINEAR_LIGHT: "contrast",
        VIVID_LIGHT: "contrast",
        PIN_LIGHT: "contrast",
        HARD_MIX: "contrast",
        DIFFERENCE: "difference",
        CLASSIC_DIFFERENCE: "difference",
        EXCLUSION: "difference",
        SUBTRACT: "difference",
        DIVIDE: "difference",
        HUE: "color",
        SATURATION: "color",
        COLOR: "color",
        LUMINOSITY: "color",
        STENCIL_ALPHA: "special",
        STENCIL_LUMA: "special",
        SILHOUETTE_ALPHA: "special",
        SILHOUETTE_LUMA: "special",
        ALPHA_ADD: "special"
    };

    function blendNameOf(value) {
        for (var i = 0; i < BLEND_NAMES.length; i++) {
            var n = BLEND_NAMES[i];
            if (typeof BlendingMode[n] !== "undefined" && BlendingMode[n] === value) return n;
        }
        return "UNKNOWN_" + String(value);
    }

    function blendRoleOf(name) {
        return BLEND_ROLES[name] || "special";
    }

    function matteNameOf(value) {
        try {
            if (value === TrackMatteType.ALPHA) return "ALPHA";
            if (value === TrackMatteType.ALPHA_INVERTED) return "ALPHA_INVERTED";
            if (value === TrackMatteType.LUMA) return "LUMA";
            if (value === TrackMatteType.LUMA_INVERTED) return "LUMA_INVERTED";
        } catch (e) {}
        return "NONE";
    }

    // ------------------------------------------------------------------
    // 4. Layer introspection
    // ------------------------------------------------------------------

    function layerTypeOf(layer) {
        try {
            if (layer instanceof CameraLayer) return "camera";
            if (layer instanceof LightLayer) return "light";
            if (layer instanceof TextLayer) return "text";
            if (layer instanceof ShapeLayer) return "shape";
        } catch (e) {}
        try {
            if (layer.adjustmentLayer === true) return "adjustment";
            if (layer.nullLayer === true) return "null";
        } catch (e) {}
        try {
            if (layer.source instanceof CompItem) return "precomp";
        } catch (e) {}
        try {
            if (layer.source && layer.source.mainSource instanceof SolidSource) return "solid";
        } catch (e) {}
        return "image";
    }

    function sourceInfo(layer) {
        var info = { source: null, left: 0, top: 0, width: 0, height: 0, anchor: [0, 0] };
        try {
            if (layer.source) info.source = String(layer.source.name);
        } catch (e) {}
        try {
            var rect = layer.sourceRectAtTime(0, false);
            info.left = r4(rect.left);
            info.top = r4(rect.top);
            info.width = r4(rect.width);
            info.height = r4(rect.height);
        } catch (e) {}
        try {
            var tr = layer.property("ADBE Transform Group");
            // t=0 anchor: this is the baseline the baked position track uses
            var anc = propValue(tr, "ADBE Anchor Point", 0);
            if (anc) info.anchor = [r4(anc[0]), r4(anc[1])];
        } catch (e) {}
        return info;
    }

    function cameraZoomAt(layer, t) {
        var z = 0;
        try {
            var g = layer.property("ADBE Camera Options Group");
            if (g) z = g.property("ADBE Camera Zoom").valueAtTime(t, false);
        } catch (e) { z = 0; }
        if (!z || z <= 0) z = readCameraZoom(layer);
        return z;
    }

    function readCameraZoom(layer) {
        var z = 0;
        try {
            var g = layer.property("ADBE Camera Options Group");
            if (g) z = g.property("ADBE Camera Zoom").value;
        } catch (e) { z = 0; }
        if (!z || z <= 0) {
            try {
                var p = layer.property("ADBE Transform Group").property("ADBE Position").value;
                z = -p[2];
            } catch (e2) { z = 0; }
        }
        return z;
    }

    function effectNames(layer) {
        var names = [];
        try {
            var parade = layer.property("ADBE Effect Parade");
            if (!parade) return names;
            for (var i = 1; i <= parade.numProperties; i++) {
                var fx = parade.property(i);
                names.push(String(fx.name));
            }
        } catch (e) {}
        return names;
    }

    function maskCount(layer) {
        try {
            return layer.mask ? layer.mask.numProperties : 0;
        } catch (e) {
            return 0;
        }
    }

    // ------------------------------------------------------------------
    // 5. Sampling
    // ------------------------------------------------------------------

    function effectiveFps(duration) {
        var frames = Math.floor(duration * CONFIG.sampleFps) + 1;
        if (frames <= CONFIG.maxSamples) return CONFIG.sampleFps;
        var fps = CONFIG.maxSamples / Math.max(duration, 0.001);
        return Math.max(1, Math.floor(fps));
    }

    function sampleLayer(layer, fps, duration) {
        var tr = null;
        try {
            tr = layer.property("ADBE Transform Group");
        } catch (e) {
            tr = null;
        }

        var tracks = { position: [], rotation: [], scale: [], alpha: [], rot3d: [], posZ: [] };
        if (!tr) return tracks;

        // The anchor point can be animated (that is how an image "moves"
        // without touching Position). We bake it into the position track so
        // the engine only needs one transform: pos(t) - anchor(t) + anchor(0).
        var anc0 = propValue(tr, "ADBE Anchor Point", 0);
        var ax0 = anc0 ? anc0[0] : 0;
        var ay0 = anc0 ? anc0[1] : 0;

        var step = 1 / fps;
        var count = Math.floor(duration * fps) + 1;

        for (var i = 0; i < count; i++) {
            var t = i * step;
            if (t > duration) t = duration;
            var ms = Math.round(t * 1000);

            var P = propValue(tr, "ADBE Position", t);
            var ANC = propValue(tr, "ADBE Anchor Point", t);
            var R = propValue(tr, "ADBE Rotate Z", t);
            var S = propValue(tr, "ADBE Scale", t);
            var A = propValue(tr, "ADBE Opacity", t);

            var is3D = false;
            try { is3D = (layer.threeDLayer === true); } catch (e) {}
            if (is3D) {
                var RX = propValue(tr, "ADBE Rotate X", t);
                var RY = propValue(tr, "ADBE Rotate Y", t);
                tracks.rot3d.push([ms, r4(RX === null ? 0 : RX), r4(RY === null ? 0 : RY)]);
                var PZ = propValue(tr, "ADBE Position", t);
                tracks.posZ.push([ms, r4((PZ && PZ.length > 2) ? PZ[2] : 0)]);
            }

            var px = (P && P.length > 0) ? P[0] : 0;
            var py = (P && P.length > 1) ? P[1] : 0;
            var ax = (ANC && ANC.length > 0) ? ANC[0] : ax0;
            var ay = (ANC && ANC.length > 1) ? ANC[1] : ay0;

            tracks.position.push([ms, r4(px - ax + ax0), r4(py - ay + ay0)]);

            tracks.rotation.push([ms, r4(R === null ? 0 : R)]);

            var sx = (S && S.length > 0) ? S[0] / 100 : 1;
            var sy = (S && S.length > 1) ? S[1] / 100 : sx;
            tracks.scale.push([ms, r4(sx), r4(sy)]);

            tracks.alpha.push([ms, r4(A === null ? 1 : A / 100)]);
        }
        return tracks;
    }


    // Collapse a track that never changes to a single sample.
    function compressStatic(track) {
        if (track.length <= 2) return track;
        var first = track[0];
        for (var i = 1; i < track.length; i++) {
            for (var j = 1; j < first.length; j++) {
                if (Math.abs(track[i][j] - first[j]) > 0.0005) return track;
            }
        }
        return [first];
    }

    function delta(a, b) {
        return r4(Math.abs(a - b));
    }

    function channelSeam(track) {
        if (track.length < 2) return 0;
        var f = track[0];
        var l = track[track.length - 1];
        var max = 0;
        for (var i = 1; i < f.length; i++) {
            var d = delta(f[i], l[i]);
            if (d > max) max = d;
        }
        return max;
    }

    // True when every sample equals the first one (first==last is not enough:
    // a sine wave returns to its start but still animates).
    function isFlat(track) {
        if (track.length < 2) return true;
        var first = track[0];
        for (var i = 1; i < track.length; i++) {
            for (var j = 1; j < first.length; j++) {
                if (Math.abs(track[i][j] - first[j]) > 0.0005) return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------
    // 6. Build the document
    // ------------------------------------------------------------------

    var duration = comp.duration;
    var fps = effectiveFps(duration);
    var layers = [];
    var unsupported = [];
    var groupId = 1;
    var doc_has_camera = false;
    var prevRole = "normal";

    for (var li = 1; li <= comp.numLayers; li++) {
        var layer = comp.layer(li);
        var type = layerTypeOf(layer);
        var src = sourceInfo(layer);
        var bName = "NORMAL";
        try {
            bName = blendNameOf(layer.blendingMode);
        } catch (e) {}
        var role = blendRoleOf(bName);

        var enabled = true;
        try {
            enabled = (layer.enabled !== false);
        } catch (e) {}

        if (role !== "normal" && prevRole === "normal") groupId++;
        prevRole = role;

        var entry = {
            id: li + "-" + String(layer.name),
            index: li,
            name: String(layer.name),
            type: type,
            z: li,
            parent: layer.parent ? layer.parent.index : null,
            enabled: enabled,
            inPoint: 0,
            outPoint: 0,
            asset: {
                source: src.source,
                left: src.left,
                top: src.top,
                width: src.width,
                height: src.height,
                anchor: src.anchor
            },
            blend: {
                mode: bName,
                role: role,
                group: groupId,
                preserveAlpha: false,
                classic: true
            },
            neutral: { mul: 1.0, add: 0.0 },
            channelPlan: "rgba",
            effectCount: effectNames(layer).length,
            maskCount: maskCount(layer),
            threeD: false,
            timeRemap: false,
            trackMatte: null,
            tracks: null,
            isStatic: false,
            firstLastDelta: null
        };

        // 名字里带 #fx 的层当作"序列帧层"：像素由外部 PNG 序列提供，
        // 位置/层级/时间窗仍然吃这份 json。
        var framesDir = "";
        var framesLoop = true;
        var rawName = String(layer.name);
        if (rawName.indexOf("#fx") >= 0) {
            // #fx-once 优先：播一遍停在末帧；#fx 则循环
            if (rawName.indexOf("#fx-once") >= 0) {
                framesLoop = false;
                framesDir = rawName.split("#fx-once").join("");
            } else {
                framesDir = rawName.split("#fx").join("");
            }
            framesDir = framesDir.replace(/^\s+|\s+$/g, "");
        }
        entry.frames = framesDir;
        entry.framesLoop = framesLoop;

        // 蒙版：把路径采样成多边形（只导第一帧；动的蒙版会标记 animated）
        try {
            var mp = layer.property("ADBE Mask Parade");
            if (mp && mp.numProperties > 0) {
                var masks = [];
                for (var mi = 1; mi <= mp.numProperties; mi++) {
                    var mg = mp.property(mi);
                    var mshape = mg.property("ADBE Mask Shape");
                    if (!mshape) continue;
                    var m0 = mshape.valueAtTime(0, false);
                    var m1 = mshape.valueAtTime(duration * 0.6, false);
                    var animated = false;
                    if (m0 && m1 && m0.vertices && m1.vertices &&
                        m0.vertices.length === m1.vertices.length) {
                        for (var vi = 0; vi < m0.vertices.length; vi++) {
                            if (Math.abs(m0.vertices[vi][0] - m1.vertices[vi][0]) > 0.5 ||
                                Math.abs(m0.vertices[vi][1] - m1.vertices[vi][1]) > 0.5) {
                                animated = true;
                                break;
                            }
                        }
                    } else if (m0 && m1) {
                        animated = true;
                    }
                    var pts = flattenShape(m0);
                    // 动蒙版：逐帧采样，只在形状变化时存一帧（稀疏）
                    var mframes = [];
                    if (animated) {
                        var mstep = 1 / fps;
                        var mcount = Math.floor(duration * fps) + 1;
                        var lastKey = "";
                        for (var fi = 0; fi < mcount; fi++) {
                            var ft = fi * mstep;
                            if (ft > duration) ft = duration;
                            var fshape = mshape.valueAtTime(ft, false);
                            var fpts = flattenShape(fshape);
                            var sig = fpts.length + ":";
                            for (var si = 0; si < fpts.length; si += 3) {
                                sig += Math.round(fpts[si][0]) + "," + Math.round(fpts[si][1]) + ";";
                            }
                            if (sig !== lastKey) {
                                lastKey = sig;
                                mframes.push([Math.round(ft * 1000), fpts]);
                            }
                        }
                    }
                    masks.push({
                        name: String(mg.name),
                        mode: maskModeName(mg),
                        inverted: maskInverted(mg),
                        animated: animated,
                        points: pts,
                        frames: mframes
                    });
                }
                entry.masks = masks;
            }
        } catch (em) {}

        // 相机层：导入端靠它还原透视
        if (type === "camera") {
            try {
                var cp = layer.property("ADBE Transform Group").property("ADBE Position").value;
                var poi = layer.property("ADBE Transform Group").property("ADBE Anchor Point").value;
                entry.camera = {
                    position: [r4(cp[0]), r4(cp[1]), r4(cp[2])],
                    interest: [r4(poi[0]), r4(poi[1])],
                    zoom: r4(readCameraZoom(layer))
                };
                // 逐帧采样：位置 / 目标点 / 焦距 / 滚转
                var cTracks = { position: [], interest: [], zoom: [], roll: [] };
                var camGroup = layer.property("ADBE Transform Group");
                var camStep = 1 / fps;
                var camCount = Math.floor(duration * fps) + 1;
                for (var ci = 0; ci < camCount; ci++) {
                    var ct = ci * camStep;
                    if (ct > duration) ct = duration;
                    var cms = Math.round(ct * 1000);
                    var cpos = propValue(camGroup, "ADBE Position", ct);
                    var cpoi = propValue(camGroup, "ADBE Anchor Point", ct);
                    var czoom = cameraZoomAt(layer, ct);
                    if (cpos) cTracks.position.push([cms, r4(cpos[0]), r4(cpos[1]), r4(cpos[2])]);
                    if (cpoi) cTracks.interest.push([cms, r4(cpoi[0]), r4(cpoi[1]), r4(cpoi[2])]);
                    cTracks.zoom.push([cms, r4(czoom)]);
                }
                entry.cameraTracks = cTracks;
                doc_has_camera = true;
            } catch (ec) {}
        }

        // 纯色层：没有图片，导出填充色（引擎侧用白图染色）
        try {
            if (layer.source && layer.source.mainSource && layer.source.mainSource.color) {
                var col = layer.source.mainSource.color;
                entry.asset.color = [r4(col[0]), r4(col[1]), r4(col[2])];
                entry.asset.solid = true;
            }
        } catch (ecol) {}

        // flags
        try {
            entry.threeD = (layer.threeDLayer === true);
        } catch (e) {}
        try {
            entry.inPoint = r4(layer.inPoint);
            entry.outPoint = r4(layer.outPoint);
        } catch (e) {}
        try {
            entry.timeRemap = (layer.timeRemapEnabled === true);
        } catch (e) {}
        try {
            entry.blend.preserveAlpha = (layer.preserveTransparency === true);
        } catch (e) {}

        // track matte (the matte source is the layer directly above)
        try {
            var mt = layer.trackMatteType;
            if (mt !== TrackMatteType.NO_TRACK_MATTE) {
                entry.trackMatte = { type: matteNameOf(mt), source: (li + 1 <= comp.numLayers) ? (li + 1) : null };
            }
        } catch (e) {}

        // sampler
        var tracks = sampleLayer(layer, fps, duration);
        var p0 = tracks.position;
        var r0 = tracks.rotation;
        var s0 = tracks.scale;
        var a0 = tracks.alpha;

        var seam = {
            position: channelSeam(p0),
            rotation: channelSeam(r0),
            scale: channelSeam(s0),
            alpha: channelSeam(a0)
        };

        var r3 = tracks.rot3d;
        var pz = tracks.posZ;
        var isStatic = (isFlat(p0) && isFlat(r0) && isFlat(s0) && isFlat(a0) && isFlat(r3) && isFlat(pz));

        if (!CONFIG.includeStatic && isStatic) continue;

        if (isStatic) {
            entry.tracks = {
                position: compressStatic(p0),
                rotation: compressStatic(r0),
                scale: compressStatic(s0),
                alpha: compressStatic(a0),
                rot3d: compressStatic(r3),
                posZ: compressStatic(pz)
            };
            entry.isStatic = true;
        } else {
            entry.tracks = {
                position: p0,
                rotation: r0,
                scale: s0,
                alpha: a0,
                rot3d: r3,
                posZ: pz
            };
        }
        entry.firstLastDelta = seam;
        entry.origin = [entry.tracks.position[0][1], entry.tracks.position[0][2]];

        // Blend families that consume a single channel can ship a multiplier.
        if (role === "multiply") entry.channelPlan = "multiplier";

        // unsupported feature bookkeeping
        if (entry.threeD) unsupported.push({ layer: entry.name, feature: "3D layer (X/Y rotation, camera projection)", policy: "bake_2d_projection" });
        if (entry.timeRemap) unsupported.push({ layer: entry.name, feature: "Time remap", policy: "bake_sequence" });

        var fx = effectNames(layer);
        for (var fi = 0; fi < fx.length; fi++) {
            var low = fx[fi].toLowerCase();
            if (low.indexOf("particular") >= 0) {
                unsupported.push({ layer: entry.name, feature: "Trapcode Particular", policy: "bake_sequence_or_gpuparticles" });
            } else if (low.indexOf("glow") >= 0) {
                unsupported.push({ layer: entry.name, feature: "Glow", policy: "bake_or_shader" });
            } else if (low.indexOf("fractal") >= 0 || low.indexOf("turbulent") >= 0) {
                unsupported.push({ layer: entry.name, feature: fx[fi], policy: "bake_sequence" });
            }
        }
        if (entry.maskCount > 0) unsupported.push({ layer: entry.name, feature: "Masks (" + entry.maskCount + ")", policy: "bake_or_polygon" });
        if (type === "text") unsupported.push({ layer: entry.name, feature: "Text layer", policy: "render_to_image_or_rebuild" });
        if (type === "precomp") unsupported.push({ layer: entry.name, feature: "Precomp (not recursed)", policy: "flatten_in_ae_or_export_children" });
        if (type === "shape") unsupported.push({ layer: entry.name, feature: "Shape layer", policy: "render_to_image_or_rebuild" });
        if (role === "color" && bName !== "NORMAL") unsupported.push({ layer: entry.name, feature: "Colour-space blend " + bName, policy: "precompose" });

        layers.push(entry);
    }

    if (layers.length === 0) {
        alert("export-motion-engine\n\nNothing to export in \"" + comp.name + "\".");
        return;
    }

    var doc = {
        format: "ae-motion/1",
        mode: "engine",
        space: "parent",
        clip: {
            name: String(comp.name),
            fps: comp.frameRate,
            sampleFps: fps,
            length: r4(duration),
            comp: { width: comp.width, height: comp.height },
            hasCamera: doc_has_camera
        },
        units: {
            position: "px",
            rotation: "deg",
            scale: "ratio (1.0 = 100%)",
            alpha: "0..1",
            time: "ms"
        },
        layers: layers,
        unsupported: unsupported,
        notes: [
            "Tracks are parent-space. Rebuild the same node hierarchy, do not flatten.",
            "AE layer opacity does not inherit: drive self_modulate, not modulate.",
            "channelPlan=multiplier: neutral value is 1.0, never 0.0.",
            "blend.group: layers sharing a group form one compositing context.",
            "Precomps are not recursed into; nested animation must be flattened in AE."
        ]
    };

    var jsonStr = toJson(doc, 0);

    // ------------------------------------------------------------------
    // 7. Write the file (UTF-8, no BOM: BOM breaks JSON parsers)
    // ------------------------------------------------------------------

    function safeFileName(name) {
        var s = String(name);
        var bad = "\\/:*?\"<>|";
        var out = "";
        for (var i = 0; i < s.length; i++) {
            var c = s.charAt(i);
            out += (bad.indexOf(c) >= 0) ? "_" : c;
        }
        out = out.replace(/^\s+|\s+$/g, "");
        if (out.length > 80) out = out.substring(0, 80);
        if (out === "") out = "clip";
        return out;
    }

    var outFolder = new Folder(CONFIG.outputDir);
    if (!outFolder.exists) {
        if (!outFolder.create()) {
            alert("export-motion-engine\n\nCould not create the output folder:\n" + CONFIG.outputDir +
                  "\n\nEdit CONFIG.outputDir at the top of this script.");
            return;
        }
    }

    var outFile = new File(outFolder.fsName + "/" + safeFileName(comp.name) + ".json");
    outFile.encoding = "UTF-8";
    if (!outFile.open("w")) {
        alert("export-motion-engine\n\nCould not open the output file for writing:\n" + outFile.fsName +
              "\n\nEnable \"Allow Scripts to Write Files and Access Network\"\n" +
              "in Preferences > Scripting & Expressions.");
        return;
    }
    outFile.write(jsonStr);
    outFile.close();

    var staticCount = 0;
    for (var ci = 0; ci < layers.length; ci++) {
        if (layers[ci].isStatic) staticCount++;
    }

    alert(
        "export-motion-engine\n\n" +
        "Written as ae-motion/1 JSON:\n" + outFile.fsName + "\n\n" +
        "Composition: " + comp.name + "   (comp id " + comp.id + ")\n" +
        "Layer count: " + layers.length + "\n" +
        "Size: " + comp.width + " x " + comp.height + " @ " + comp.frameRate + " fps\n" +
        "Length: " + r4(duration) + " s\n" +
        "Sample rate: " + fps + " fps\n" +
        "Layers: " + layers.length + " (" + staticCount + " static)\n" +
        "Layer names:\n" + layerNameList(layers) + "\n" +
        "Unsupported features flagged: " + unsupported.length
    );

})();
