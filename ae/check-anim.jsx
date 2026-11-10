/*
 * check-anim.jsx —— 诊断用，不改任何东西。
 * 列出当前合成每个图层的关键帧数量，写到桌面 ae_check.txt。
 * 用法：文件 > 脚本 > 运行脚本文件
 */

(function () {

    var comp = app.project.activeItem;
    if (!(comp instanceof CompItem)) {
        alert("check-anim\n\n先打开一个合成。");
        return;
    }

    var lines = [];
    lines.push("comp: " + comp.name + "  " + comp.frameRate + "fps  " + comp.duration + "s  layers=" + comp.numLayers);
    lines.push("");

    var props = [
        ["ADBE Position", "pos"],
        ["ADBE Position_0", "posX"],
        ["ADBE Position_1", "posY"],
        ["ADBE Rotate Z", "rotZ"],
        ["ADBE Scale", "scl"],
        ["ADBE Opacity", "op"],
        ["ADBE Anchor Point", "anc"]
    ];

    for (var i = 1; i <= comp.numLayers; i++) {
        var L = comp.layer(i);
        var tr = null;
        try {
            tr = L.property("ADBE Transform Group");
        } catch (e) {
            tr = null;
        }

        var line = "L" + i + "\t" + L.name + "\tparent=" + (L.parent ? L.parent.index : "-");
        if (!tr) {
            lines.push(line + "\tNO_TRANSFORM");
            continue;
        }

        for (var k = 0; k < props.length; k++) {
            var p = null;
            try {
                p = tr.property(props[k][0]);
            } catch (e) {
                p = null;
            }
            if (p) {
                var nk = -1;
                try {
                    nk = p.numKeys;
                } catch (e) {
                    nk = -1;
                }
                line += "\t" + props[k][1] + "=" + nk;
            }
        }

        try {
            if (tr.property("ADBE Position_0") || tr.property("ADBE Position_1")) {
                line += "\tSEPARATED";
            }
        } catch (e) {}

        lines.push(line);
    }

    var out = new File(Folder.desktop.fsName + "/ae_check.txt");
    out.encoding = "UTF-8";
    if (out.open("w")) {
        out.write(lines.join("\n"));
        out.close();
        alert("check-anim\n\n已写到桌面：ae_check.txt\n\n" + lines.slice(0, 6).join("\n"));
    } else {
        alert("check-anim\n\n桌面写不进去，检查脚本权限。");
    }

})();
