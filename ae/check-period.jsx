// check-period.jsx —— 在 AE 里读指定时间点的变换值，判断表达式是否真的周期
// 用法：打开合成，运行本脚本。结果写到桌面 ae_period.txt
(function () {
    var comp = app.project.activeItem;
    if (!(comp instanceof CompItem)) {
        alert("打开一个合成再运行。");
        return;
    }

    var times = [0.0, 0.4, 1.0, 2.2, 4.0, 5.8, 7.6];
    var out = [];
    out.push("comp: " + comp.name + "  fps=" + comp.frameRate);
    out.push("times(s): " + times.join(", "));
    out.push("");

    function v(layer, matchName, t) {
        try {
            var p = layer.property("ADBE Transform Group").property(matchName);
            if (!p) return "n/a";
            var x = p.valueAtTime(t, false);
            if (x instanceof Array) {
                var parts = [];
                for (var i = 0; i < x.length; i++) parts.push(x[i].toFixed(4));
                return parts.join(",");
            }
            return Number(x).toFixed(4);
        } catch (e) {
            return "err";
        }
    }

    for (var i = 1; i <= comp.numLayers; i++) {
        var L = comp.layer(i);
        var line = L.name + "  [3D=" + (L.threeDLayer ? "y" : "n") + "]";
        out.push(line);
        var props = ["ADBE Rotate X", "ADBE Rotate Y", "ADBE Rotate Z", "ADBE Position"];
        for (var k = 0; k < props.length; k++) {
            var vals = [];
            for (var j = 0; j < times.length; j++) {
                vals.push(v(L, props[k], times[j]));
            }
            out.push("    " + props[k] + " : " + vals.join(" | "));
        }
        out.push("");
    }

    var f = new File(Folder.desktop.fsName + "/ae_period.txt");
    f.encoding = "UTF-8";
    f.open("w");
    f.write(out.join("\n"));
    f.close();
    alert("已写到桌面 ae_period.txt");
})();
