// Run a command and kill its whole process tree on REAL memory danger, not on memory-mapped file cache:
//   * the system commit total (committed bytes) within <headroomGB> of the commit limit for 2 checks (the cause of the 2026-10-24 03:34 freeze), or
//   * available RAM under <thrashGB> for <sustainSec> seconds in a row (genuine thrash; short dips while Windows trims mapped model files are normal).
//   node guard-mem.cjs <headroomGB> <thrashGB> <sustainSec> <command> [args...]
// Logs the lowest available RAM and the highest commit seen to stderr, and a line every minute.
"use strict";
const cp = require("child_process"), os = require("os");
const [headroom, thrash, sustain, cmd, ...args] = process.argv.slice(2);
if (!cmd) { console.error("usage: node guard-mem.cjs <headroomGB> <thrashGB> <sustainSec> <command> [args...]"); process.exit(2); }
const child = cp.spawn(cmd, args, { stdio: "inherit", windowsHide: true });
let lowAvail = Infinity, hiCommit = 0, limit = 0, availLow = 0, commitHi = 0, killed = false, n = 0;
const ps = "$o=Get-CimInstance Win32_OperatingSystem; '{0}|{1}' -f [math]::Round(($o.TotalVirtualMemorySize-$o.FreeVirtualMemory)/1MB,1),[math]::Round($o.TotalVirtualMemorySize/1MB,1)";
function kill(why) { if (killed) return; killed = true; console.error("MEMGUARD KILL: " + why); try { cp.execFileSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { windowsHide: true }); } catch {} }
setInterval(() => { // every second: available RAM (cheap)
  const a = os.freemem() / 2 ** 30; lowAvail = Math.min(lowAvail, a); availLow = a < +thrash ? availLow + 1 : 0;
  if (availLow >= +sustain) kill("available RAM " + a.toFixed(2) + " GB under " + thrash + " GB for " + sustain + " s (thrash)");
}, 1000);
setInterval(() => { // every 5 s: commit total
  let out = ""; try { out = cp.execFileSync("powershell.exe", ["-NoProfile", "-Command", ps], { encoding: "utf8", timeout: 20000, windowsHide: true }).trim(); } catch { return; }
  const [c, l] = out.split("|").map(Number); if (!c || !l) return; limit = l; hiCommit = Math.max(hiCommit, c);
  commitHi = c > l - +headroom ? commitHi + 1 : 0;
  if (commitHi >= 2) kill("commit " + c + " of " + l + " GB is within " + headroom + " GB of the limit");
  if (++n % 12 === 0) console.error("MEMGUARD lowest available RAM " + lowAvail.toFixed(2) + " GB, highest commit " + hiCommit + " of " + limit + " GB");
}, 5000);
child.on("exit", (code) => { console.error("MEMGUARD done, lowest available RAM " + lowAvail.toFixed(2) + " GB, highest commit " + hiCommit + " of " + limit + " GB"); process.exit(killed ? 137 : code == null ? 1 : code); });
