// Crash-rate test: an agent-like long session against the running server (OpenAI API on 127.0.0.1:8097). Multi-turn conversations grow by 1-4k tokens a turn (prefix reused),
// reach about 100k tokens, then a new conversation starts (a cold prompt, like a compaction). It counts engine failures, waits for the engine to come back, and logs to
// ./longsession-<label>.log (or $LONGSESSION_LOGDIR). usage: node longsession.cjs <minutes> <label>
const fs = require("fs");
const MIN = +(process.argv[2] || 30), LABEL = process.argv[3] || "run", LOG = (process.env.LONGSESSION_LOGDIR || ".") + "/longsession-" + LABEL + ".log";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (s) => { const l = new Date().toLocaleTimeString() + " " + s; console.log(l); fs.appendFileSync(LOG, l + "\n"); };
let seed = 12345; const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
const words = ["image", "mask", "sobel", "blob", "contour", "threshold", "matrix", "kernel", "pixel", "region", "offset", "scale", "filter", "buffer", "stride", "window", "vector", "config", "feature", "corner"];
const line = () => { const a = words[(rnd() * words.length) | 0], b = words[(rnd() * words.length) | 0], n = (rnd() * 9000) | 0; return "static int " + a + "_" + b + "_" + n + "(const Img* src, int x, int y) { return (src->data[y * src->stride + x] * " + (n % 31) + ") ^ 0x" + (n * 2654435761 >>> 0).toString(16) + "; } // " + a + " " + b; };
const block = (tokens) => { const out = []; let t = 0; while (t < tokens) { out.push(line()); t += 38; } return out.join("\n"); };
const health = async () => { try { return (await (await fetch("http://127.0.0.1:8097/health", { signal: AbortSignal.timeout(3000) })).json()).status === "ok"; } catch { return false; } };
async function chat(messages, maxTok) {
  const r = await fetch("http://127.0.0.1:8097/v1/chat/completions", { method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(1500000),
    body: JSON.stringify({ model: "x", messages, max_tokens: maxTok, temperature: 0.6 }) });
  return r.json();
}
(async () => {
  const t0 = Date.now(), end = t0 + MIN * 60000; let reqs = 0, fails = 0, convs = 0, tokens = 0, ctxMax = 0;
  log("start " + LABEL + " for " + MIN + " min");
  while (Date.now() < end) {
    convs++; const msgs = [{ role: "system", content: "You are a coding agent. Session " + convs + ".\n" + block(6000) }, { role: "user", content: "Task: review the helper functions below and explain what they compute.\n" + block(1500) }];
    log("conversation " + convs + " starts");
    for (let turn = 0; Date.now() < end; turn++) {
      const t1 = Date.now(); let r;
      try { r = await chat(msgs, 300 + ((rnd() * 900) | 0)); } catch (e) { r = { error: { message: String(e).slice(0, 120) } }; }
      reqs++;
      if (!r.usage) {
        fails++; log("FAIL #" + fails + " request " + reqs + " conv " + convs + " turn " + turn + ": " + JSON.stringify(r.error || r).slice(0, 140));
        for (let i = 0; i < 60 && !(await health()); i++) await sleep(10000);
        await sleep(45000); log("engine back; new conversation"); break;
      }
      const pt = r.usage.prompt_tokens; ctxMax = Math.max(ctxMax, pt); tokens += r.usage.completion_tokens;
      if (turn % 5 === 0) log("conv " + convs + " turn " + turn + " prompt " + pt + " out " + r.usage.completion_tokens + " in " + ((Date.now() - t1) / 1000).toFixed(1) + " s");
      msgs.push({ role: "assistant", content: (r.choices[0].message.content || "(no text)").slice(0, 6000) });
      if (pt > 100000) { log("context " + pt + ": starting a new conversation (like a compaction)"); break; }
      msgs.push({ role: "user", content: "Tool result:\n" + block(1000 + ((rnd() * 3000) | 0)) + "\nContinue." });
    }
  }
  log("DONE " + LABEL + ": minutes " + ((Date.now() - t0) / 60000).toFixed(1) + ", requests " + reqs + ", engine failures " + fails + ", conversations " + convs + ", max prompt " + ctxMax + ", output tokens " + tokens);
})();
