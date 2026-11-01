# amd-od8.ps1 - command-line access to the AMD driver's Overdrive8 tuning (what Adrenalin > Performance > Tuning sets) for the RX 7900 XTX.
#   amd-od8.ps1              list every Overdrive8 setting: id, min, max, default, current
#   amd-od8.ps1 -Set 9=-10   set setting id 9 to -10 (several: -Set 9=-10,0=2300); ids come from the list
#   amd-od8.ps1 -Reset       reset all tuning to the driver defaults
# Uses atiadlxx.dll (ADL, installed with the AMD driver). Settings do not survive a reboot or a driver reset; re-apply at logon.
param([string[]]$Set, [switch]$Reset)
$src = @"
using System;
using System.Runtime.InteropServices;
public static class Od8 {
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr Alloc(int size);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Main_Control_Create(Alloc cb, int enumConnected, out IntPtr ctx);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Main_Control_Destroy(IntPtr ctx);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Adapter_NumberOfAdapters_Get(IntPtr ctx, out int n);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Adapter_Active_Get(IntPtr ctx, int a, out int active);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Overdrive_Caps(IntPtr ctx, int a, out int supported, out int enabled, out int version);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Overdrive8_Init_Setting_Get(IntPtr ctx, int a, IntPtr buf);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Overdrive8_Current_Setting_Get(IntPtr ctx, int a, IntPtr buf);
  [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Overdrive8_Setting_Set(IntPtr ctx, int a, IntPtr set, IntPtr current);
  static Alloc keep = s => Marshal.AllocHGlobal(s);
  static IntPtr ctx;
  public static string Err = "";
  public static int Adapter = -1;
  public static int Caps, N;
  public static int[] Id, Def, Min, Max, Cur;
  public static bool Open() {
    if (ADL2_Main_Control_Create(keep, 1, out ctx) != 0) { Err = "ADL init failed"; return false; }
    int n; ADL2_Adapter_NumberOfAdapters_Get(ctx, out n);
    for (int a = 0; a < n; a++) {
      int act; if (ADL2_Adapter_Active_Get(ctx, a, out act) != 0 || act == 0) continue;
      int sup, en, ver; int rc = ADL2_Overdrive_Caps(ctx, a, out sup, out en, out ver);
      Err += "[adapter " + a + ": active, caps rc " + rc + " supported " + sup + " version " + ver + "] ";
      if (rc != 0 || sup == 0) continue;
      Adapter = a; if (Load()) return true;
    }
    Err += "no adapter answered Overdrive8"; return false;
  }
  public static bool Load() {
    N = 30;   // the driver's OD8 table size for this card (fixed-size API; the X2 variant returns ADL_ERR_NULL_POINTER here)
    IntPtr ib = Marshal.AllocHGlobal(8 + N * 16), cb = Marshal.AllocHGlobal(4 + N * 4);
    try {
      for (int i = 0; i < 8 + N * 16; i += 4) Marshal.WriteInt32(ib, i, 0);
      for (int i = 0; i < 4 + N * 4; i += 4) Marshal.WriteInt32(cb, i, 0);
      Marshal.WriteInt32(ib, 0, N); Marshal.WriteInt32(cb, 0, N);
      int r = ADL2_Overdrive8_Init_Setting_Get(ctx, Adapter, ib);
      if (r != 0) { Err = "Init_Setting_Get " + r; return false; }
      r = ADL2_Overdrive8_Current_Setting_Get(ctx, Adapter, cb);
      if (r != 0) { Err = "Current_Setting_Get " + r; return false; }
      Caps = Marshal.ReadInt32(ib, 4);
      Id = new int[N]; Def = new int[N]; Min = new int[N]; Max = new int[N]; Cur = new int[N];
      for (int i = 0; i < N; i++) {   // ADLOD8SingleInitSetting as this driver fills it: featureID, min, max, default
        Id[i] = Marshal.ReadInt32(ib, 8 + i * 16); Min[i] = Marshal.ReadInt32(ib, 12 + i * 16);
        Max[i] = Marshal.ReadInt32(ib, 16 + i * 16); Def[i] = Marshal.ReadInt32(ib, 20 + i * 16);
        Cur[i] = Marshal.ReadInt32(cb, 4 + i * 4);
      }
      return true;
    } finally { Marshal.FreeHGlobal(ib); Marshal.FreeHGlobal(cb); }
  }
  // ids/values: settings to change; reset: every setting back to default. Returns the ADL result code.
  public static int Apply(int[] ids, int[] vals, bool reset) {
    int size = 4 + N * 12;
    IntPtr set = Marshal.AllocHGlobal(size), cur = Marshal.AllocHGlobal(4 + N * 4);
    try {
      for (int i = 0; i < size; i += 4) Marshal.WriteInt32(set, i, 0);
      for (int i = 0; i < 4 + N * 4; i += 4) Marshal.WriteInt32(cur, i, 0);
      Marshal.WriteInt32(set, 0, N); Marshal.WriteInt32(cur, 0, N);
      for (int i = 0; i < N; i++) {          // keep every current value, request only the ones asked
        Marshal.WriteInt32(set, 4 + i * 12, Cur[i]);
        Marshal.WriteInt32(cur, 4 + i * 4, Cur[i]);
        if (reset) { Marshal.WriteInt32(set, 4 + i * 12 + 4, 1); Marshal.WriteInt32(set, 4 + i * 12 + 8, 1); }
      }
      if (!reset) for (int k = 0; k < ids.Length; k++) {
        int i = ids[k]; if (i < 0 || i >= N) return -999;
        Marshal.WriteInt32(set, 4 + i * 12, vals[k]);
        Marshal.WriteInt32(set, 4 + i * 12 + 4, 1);
      }
      return ADL2_Overdrive8_Setting_Set(ctx, Adapter, set, cur);
    } finally { Marshal.FreeHGlobal(set); Marshal.FreeHGlobal(cur); }
  }
  public static void Close() { ADL2_Main_Control_Destroy(ctx); }
}
"@
if (-not ('Od8' -as [type])) { Add-Type -TypeDefinition $src }
if (-not [Od8]::Open()) { Write-Output "error: $([Od8]::Err)"; exit 1 }
try {
  if ($Reset -or $Set) {
    $ids = @(); $vals = @()
    foreach ($s in ($Set -join ',').Split(',', [StringSplitOptions]::RemoveEmptyEntries)) { $p = $s.Split('='); $ids += [int]$p[0]; $vals += [int]$p[1] }
    $r = [Od8]::Apply([int[]]$ids, [int[]]$vals, [bool]$Reset)
    Write-Output ("Setting_Set result: {0} ({1})" -f $r, $(if ($r -eq 0) { 'ok' } else { 'failed' }))
    [void][Od8]::Load()
  }
  Write-Output ("adapter {0}, capabilities 0x{1:X}, {2} settings" -f [Od8]::Adapter, [Od8]::Caps, [Od8]::N)
  for ($i = 0; $i -lt [Od8]::N; $i++) {
    if ([Od8]::Min[$i] -eq 0 -and [Od8]::Max[$i] -eq 0 -and [Od8]::Def[$i] -eq 0 -and [Od8]::Cur[$i] -eq 0) { continue }
    Write-Output ("  id {0,2}  feature {1,3}  min {2,6}  max {3,6}  default {4,6}  current {5,6}" -f $i, [Od8]::Id[$i], [Od8]::Min[$i], [Od8]::Max[$i], [Od8]::Def[$i], [Od8]::Cur[$i])
  }
} finally { [Od8]::Close() }
