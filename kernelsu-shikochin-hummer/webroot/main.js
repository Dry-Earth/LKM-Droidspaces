"use strict";

const MOD = "/data/adb/modules/droidspaces_hummer";
const DATA = "/data/adb/droidspaces_hummer";
const CMD_STATUS = `sh ${MOD}/service.sh status`;
const CMD_LOG = `tail -n 200 ${DATA}/load.log 2>/dev/null`;
const CMD_RETRY = `sh ${MOD}/service.sh reset; sh ${MOD}/service.sh load`;
const CMD_CLEAR = `: > ${DATA}/load.log`;

let seq = 0;
let busy = false;

function el(id) {
    const node = document.getElementById(id);
    if (!node) {
        throw new Error(`missing element #${id}`);
    }
    return node;
}

const out = el("log");
const statusBox = el("status");
const sub = el("sub");

// 第三个参数是回调函数名，不是函数本身；回调挂在 window 上由 JSBridge 调用。
function sh(command) {
    return new Promise((resolve) => {
        const bridge = window.ksu;
        if (!bridge || typeof bridge.exec !== "function") {
            resolve({ errno: -1, stdout: "", stderr: "WebUI API unavailable (KernelSU/APatch required)" });
            return;
        }
        const name = `ds_cb_${Date.now()}_${seq++}`;
        const holder = window;
        let timer = 0;
        let done = false;
        const finish = (errno, stdout, stderr) => {
            if (done) {
                return;
            }
            done = true;
            if (timer) {
                window.clearTimeout(timer);
            }
            delete holder[name];
            resolve({ errno: errno | 0, stdout: stdout || "", stderr: stderr || "" });
        };
        holder[name] = finish;
        try {
            bridge.exec(command, "{}", name);
        } catch (e) {
            finish(-1, "", String(e));
            return;
        }
        timer = window.setTimeout(() => finish(-1, "", "timeout after 15s"), 15000);
    });
}

function parseStatus(text) {
    const map = {};
    text.split("\n").forEach((raw) => {
        const line = raw.replace(/\r$/, "");
        if (!line) {
            return;
        }
        const eq = line.indexOf("=");
        if (eq < 0) {
            return;
        }
        map[line.slice(0, eq)] = line.slice(eq + 1);
    });
    return map;
}

function setBadge(id, text, cls) {
    const node = el(id);
    node.textContent = text;
    node.className = cls ? `badge ${cls}` : "badge";
}

function render(statusText, logText) {
    const m = parseStatus(statusText);
    const active = m.active === "1";
    const blocked = m.blocked === "1";
    const usernsKo = m.userns_ko === "1";
    const usernsCfg = m.userns_cfg === "1";
    const nativeUserns = m.native_userns === "1";

    let stateText = "未加载";
    let stateCls = "off";
    if (active) {
        stateText = "已激活";
        stateCls = "on";
    } else if (blocked) {
        stateText = "已阻断";
        stateCls = "warn";
    }
    setBadge("state", stateText, stateCls);

    el("kernel").textContent = m.kernel || "–";
    el("target").textContent = m.target || "–";
    el("manager").textContent = m.manager || "–";

    if (!usernsKo) {
        setBadge("userns", "包内缺失", "off");
    } else if (nativeUserns) {
        setBadge("userns", "禁止（原生已启用）", "off");
    } else if (usernsCfg) {
        setBadge("userns", "已配置", "on");
    } else {
        setBadge("userns", "未启用", "");
    }
    setBadge("native", nativeUserns ? "是" : "否", nativeUserns ? "warn" : "on");
    setBadge("blocked", blocked ? "是" : "否", blocked ? "warn" : "on");

    sub.textContent = `${m.version || ""} · droidspaces_hummer · ${m.manager || ""}`;

    const lines = [];
    if (m.status) {
        lines.push(m.status);
    }
    lines.push(`devtmpfs ko: ${m.devtmpfs_ko === "1" ? "有" : "无"}  netfilter ko: ${m.netfilter_ko === "1" ? "有" : "无"}`);
    lines.push(`auto: ${m.auto === "1" ? "开" : "关"}  userns=1: ${usernsCfg ? "是" : "否"}`);
    statusBox.textContent = lines.join("\n");
    out.textContent = (logText || "").trim() || "（空）";
}

function syncButtons() {
    ["btn-refresh", "btn-load", "btn-log"].forEach((id) => {
        el(id).disabled = busy;
    });
}

async function withBusy(label, task) {
    if (busy) {
        return;
    }
    busy = true;
    syncButtons();
    if (label) {
        out.textContent = label;
    }
    try {
        await task();
    } finally {
        busy = false;
        syncButtons();
    }
}

async function fetchAll() {
    const [status, log] = await Promise.all([sh(CMD_STATUS), sh(CMD_LOG)]);
    if (status.errno !== 0 && !status.stdout) {
        return `读取失败 (errno ${status.errno})\n${status.stderr}`;
    }
    render(status.stdout, log.stdout);
    return "";
}

function refresh() {
    return withBusy("", async () => {
        await fetchAll();
    });
}

el("btn-refresh").addEventListener("click", () => {
    void refresh();
});

el("btn-load").addEventListener("click", () => {
    void withBusy("解除阻断并重新加载 …", async () => {
        await sh(CMD_RETRY);
        await fetchAll();
    });
});

el("btn-log").addEventListener("click", () => {
    void withBusy("清空日志 …", async () => {
        await sh(CMD_CLEAR);
        await fetchAll();
    });
});

void refresh();
