# Disk usage scan: per top-level directory size + file count + newest/oldest LastWrite.
#
# Design notes (all learned the hard way, 2026-11-25):
#
# 1) Reparse points (junction / symlink) are SKIPPED, never followed. Following them
#    double-counts: E:\sing\04_...6.3\env is a junction to 6.2's env, which made a
#    22.70 GB tree look like 31.45 GB.
#
#    Skipping alone is not enough: a skip hides where the data went. So every skipped
#    reparse is RECORDED with its target path and the volume that target lives on, and
#    the summary splits them three ways:
#      same-volume      target on the scanned volume -> its bytes are already counted
#                       under another top-level dir (or under the target itself)
#      other-volume     target on a DIFFERENT volume -> those bytes are NOT in this
#                       scan at all; the tree is genuinely undercounted here
#      unresolved       target could not be read -> unknown, must be reported as such
#    "other-volume" and "unresolved" are the cases where skipping loses data.
#
# 2) Incompleteness is reported, not swallowed. `skipped` / `denied` / `reparse` /
#    `errors` counters are printed. Any non-zero value means every downstream
#    conclusion is partial. A partial scan presented as complete is the same lie as
#    "I found nothing" masquerading as "there is nothing".
#
# 3) LastWrite only, never LastAccess. This machine has LastAccess enabled, but the
#    scan itself refreshes it - so using it to judge "how long untouched" would be
#    measuring our own footprint. LastWrite is the honest signal, with a known
#    limitation: recent write vetoes deletion, old write does NOT authorize it.
#
# 4) FileInfo.Length is LOGICAL length, not disk usage. Hard links are counted once per
#    link, sparse files report their nominal size, NTFS-compressed files report the
#    uncompressed size. With -Physical the scan asks the filesystem instead
#    (GetCompressedFileSize for allocation) and de-duplicates hard links by file id, so
#    `logical` and `physical` can be compared side by side. -Physical costs one extra
#    syscall per file plus a hash lookup, so it is opt-in; use it on final candidates,
#    not on a whole drive.
#
# 5) Pure ASCII + CRLF. PowerShell 5.1 decodes a BOM-less script as GBK; any non-ASCII
#    byte in a header string breaks parsing (observed: `Unexpected token '<mojibake>'`,
#    i.e. a Chinese column header turned into garbage). Keep this file ASCII; put the
#    Chinese explanation in SKILL.md instead.
#
# Usage:
#   $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
#   & $ps -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Root 'E:\' -OutFile out.json
#   & $ps -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Root 'D:\anaconda3' -Physical
#
# -Root      drive root or any directory. Top-level children are scanned in parallel.
# -TopN      how many rows to print (default 40). JSON always holds every row.
# -OutFile   optional; rows as UTF-8 JSON (no BOM) for later diffing.
# -Aging     optional; also bucket the whole subtree by LastWrite age in 5 bands.
# -Physical  optional; also measure allocated bytes and de-duplicate hard links.
# -ReparseOut optional; write the full skipped-reparse list (path/target/volume) here.

param(
  [string]$Root = 'D:\',
  [int]$TopN = 40,
  [string]$OutFile = '',
  [switch]$Aging,
  [switch]$Physical,
  [string]$ReparseOut = ''
)

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public class ReparseRec {
    public string Path;
    public string Target;
    public string TargetVolume;
    public string Kind;      // same-volume | other-volume | unresolved
}

public class DirStat {
    public string Full;
    public string Name;
    public long Bytes;        // logical length sum
    public long PhysicalBytes; // allocated bytes sum (only with -Physical)
    public long HardlinkSaved; // bytes not added because the file id was already seen
    public long Files;
    public long SkippedDirs;
    public long Denied;
    public long Reparse;
    public long Errors;
    public DateTime MaxWrite = DateTime.MinValue;
    public DateTime MinWrite = DateTime.MaxValue;
    public List<ReparseRec> ReparseList = new List<ReparseRec>();
}

public class AgeBuckets {
    public long[] Bytes = new long[5];
    public long[] Files = new long[5];
}

public static class TopScan {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION info);

    static bool IsReparse(FileSystemInfo fsi) {
        try { return (fsi.Attributes & FileAttributes.ReparsePoint) != 0; } catch { return true; }
    }

    static long Allocated(string path, long logical) {
        uint high;
        uint low = GetCompressedFileSizeW(path, out high);
        if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return logical;
        long v = ((long)high << 32) + low;
        return v < 0 ? logical : v;
    }

    static uint LinkCount(FileInfo fi) {
        try {
            using (var fs = new FileStream(fi.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1, FileOptions.None)) {
                BY_HANDLE_FILE_INFORMATION info;
                if (GetFileInformationByHandle(fs.SafeFileHandle, out info)) return info.NumberOfLinks;
            }
        } catch {}
        return 1;
    }
    // Returns a stable identity for hard-link de-duplication, or null if unavailable.
    static string FileKey(string path) {
        try {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1, FileOptions.None)) {
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(fs.SafeFileHandle, out info)) return null;
                return info.VolumeSerialNumber.ToString("X8") + ":" +
                       info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
            }
        } catch { return null; }
    }

    static string VolumeOf(string path) {
        try {
            var root = Path.GetPathRoot(path);
            return string.IsNullOrEmpty(root) ? null : root.TrimEnd('\\');
        } catch { return null; }
    }

    static ReparseRec DescribeReparse(string path, string scannedVolume) {
        var rec = new ReparseRec { Path = path, Kind = "unresolved" };
        try {
            var di = new DirectoryInfo(path);
            string target = null;
            // .NET Framework has no LinkTarget; PowerShell exposes Target as a
            // NoteProperty, so resolution happens in the PS layer. Here we only
            // fall back to the cheap, always-available hint.
            var fsi = (FileSystemInfo)di;
            if (fsi.Exists) target = di.FullName;
            rec.Target = target;
            if (!string.IsNullOrEmpty(target)) {
                rec.TargetVolume = VolumeOf(target);
                rec.Kind = string.Equals(rec.TargetVolume, scannedVolume, StringComparison.OrdinalIgnoreCase)
                    ? "same-volume" : "other-volume";
            }
        } catch { rec.Kind = "unresolved"; }
        return rec;
    }

    static void Walk(string start, DirStat s, AgeBuckets age, object lockObj, string scannedVolume,
                     bool physical, HashSet<string> seenLinks) {
        long b = 0, pb = 0, hl = 0, f = 0, skipped = 0, denied = 0, reparse = 0, errors = 0;
        DateTime mx = DateTime.MinValue, mn = DateTime.MaxValue;
        long[] ab = new long[5];
        long[] af = new long[5];
        var reps = new List<ReparseRec>();
        DateTime now = DateTime.Now;

        var stack = new Stack<string>();
        stack.Push(start);
        while (stack.Count > 0) {
            var cur = stack.Pop();
            DirectoryInfo di;
            try { di = new DirectoryInfo(cur); }
            catch { errors++; continue; }

            try {
                foreach (var fi in di.EnumerateFiles()) {
                    try {
                        long len = fi.Length;
                        b += len; f++;
                        if (physical) {
                            long alloc = Allocated(fi.FullName, len);
                            bool counted = true;
                            if (LinkCount(fi) > 1) {
                                var key = FileKey(fi.FullName);
                                if (key != null) {
                                    lock (lockObj) { counted = seenLinks.Add(key); }
                                    if (!counted) hl += alloc;
                                }
                            }
                            if (counted) pb += alloc;
                        }
                        var t = fi.LastWriteTime;
                        if (t > mx) mx = t;
                        if (t < mn) mn = t;
                        if (age != null) {
                            double days = (now - t).TotalDays;
                            int band = days <= 30 ? 0 : days <= 90 ? 1 : days <= 180 ? 2 : days <= 365 ? 3 : 4;
                            ab[band] += len; af[band]++;
                        }
                    } catch (UnauthorizedAccessException) { denied++; }
                    catch { errors++; }
                }
            } catch (UnauthorizedAccessException) { denied++; }
            catch { skipped++; }

            try {
                foreach (var d in di.EnumerateDirectories()) {
                    // Never descend into a reparse point: it would double-count another tree.
                    // But do record where it points, so the skip can be judged instead of trusted.
                    if (IsReparse(d)) {
                        reparse++;
                        reps.Add(DescribeReparse(d.FullName, scannedVolume));
                        continue;
                    }
                    stack.Push(d.FullName);
                }
            } catch (UnauthorizedAccessException) { denied++; }
            catch { skipped++; }
        }

        lock (lockObj) {
            s.Bytes = b; s.PhysicalBytes = pb; s.HardlinkSaved = hl;
            s.Files = f; s.MaxWrite = mx; s.MinWrite = mn;
            s.SkippedDirs = skipped; s.Denied = denied; s.Reparse = reparse; s.Errors = errors;
            s.ReparseList = reps;
            if (age != null) { age.Bytes = ab; age.Files = af; }
        }
    }

    public static DirStat[] Run(string root, AgeBuckets age, bool physical) {
        var scannedVolume = VolumeOf(Path.GetFullPath(root));
        var dirs = new List<DirStat>();
        foreach (var d in Directory.GetDirectories(root)) {
            var di = new DirectoryInfo(d);
            if (IsReparse(di)) continue;          // a top-level junction is not our data
            dirs.Add(new DirStat { Full = d, Name = Path.GetFileName(d) });
        }
        var lk = new object();
        var seenLinks = new HashSet<string>(StringComparer.Ordinal);
        Parallel.ForEach(dirs, new ParallelOptions { MaxDegreeOfParallelism = 8 },
            s => Walk(s.Full, s, age, lk, scannedVolume, physical, seenLinks));
        return dirs.ToArray();
    }
}
'@

Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop

# FileInfo.NumberOfLinks does not exist on .NET Framework; patch it via an extension shim.
$ageBuckets = if ($Aging) { New-Object AgeBuckets } else { $null }

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = [TopScan]::Run($Root, $ageBuckets, [bool]$Physical)
$sw.Stop()

$total = ($r | Measure-Object Bytes -Sum).Sum
$files = ($r | Measure-Object Files -Sum).Sum
$sumReparse = ($r | Measure-Object Reparse -Sum).Sum
$sumDenied = ($r | Measure-Object Denied -Sum).Sum
$sumSkipped = ($r | Measure-Object SkippedDirs -Sum).Sum
$sumPhysical = ($r | Measure-Object PhysicalBytes -Sum).Sum
$sumHardSaved = ($r | Measure-Object HardlinkSaved -Sum).Sum

$drive = Split-Path -Qualifier $Root -ErrorAction SilentlyContinue
$driveInfo = if ($drive) { Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue } else { $null }

"scan {0:N1}s / dirs {1} / total {2:N2} GB (logical) / files {3}" -f $sw.Elapsed.TotalSeconds, $r.Count, ($total/1GB), $files
if ($driveInfo) {
  "{0} free {1:N2} GB / used {2:N2} GB" -f $drive, ($driveInfo.Free/1GB), ($driveInfo.Used/1GB)
}

# Reparse accounting: a skip is only harmless when the target is on the same volume
# (its bytes still exist somewhere the scan can see). Cross-volume targets mean this
# scan genuinely does not contain those bytes.
$allReps = @()
foreach ($row in $r) { if ($row.ReparseList) { $allReps += $row.ReparseList } }

# Read the raw Target via the PS note property; volume classification happens below.
$resolvedVols = @{}
foreach ($rep in $allReps) {
  if (-not $resolvedVols.ContainsKey($rep.Path)) {
    $t = $null
    try { $t = (Get-Item -LiteralPath $rep.Path -Force -ErrorAction Stop).Target } catch { $t = $null }
    if ($t) {
      if ($t -is [array]) { $t = $t[0] }
      $resolvedVols[$rep.Path] = @{ target = $t; volume = (Split-Path -Qualifier $t -ErrorAction SilentlyContinue) }
    } else { $resolvedVols[$rep.Path] = $null }
  }
  $rv = $resolvedVols[$rep.Path]
  if ($rv) { $rep.Target = $rv.target; $rep.TargetVolume = $rv.volume }
}

# Re-classify AFTER resolution: the C# layer can only guess, the PS layer has the real target.
# Two target shapes need normalising before the volume test:
#   - pnpm / npm global links report "Global\D:\path" -> the "Global\" prefix is not a volume
#   - relative symlinks (common in Xilinx/Vivado trees) -> resolve against the link's parent
foreach ($rep in $allReps) {
  $tv = $rep.Target
  if ([string]::IsNullOrEmpty($tv)) { $rep.Kind = 'unresolved'; continue }

  # Strip the npm/pnpm "Global\" marker.
  if ($tv.StartsWith('Global\')) { $tv = $tv.Substring(7) }

  # Resolve a relative target against the directory that holds the link.
  if (-not [System.IO.Path]::IsPathRooted($tv)) {
    try {
      $parent = Split-Path -Parent $rep.Path
      $tv = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($parent, $tv))
    } catch { $rep.Kind = 'unresolved'; continue }
  }

  $rep.Target = $tv
  $rep.TargetVolume = Split-Path -Qualifier $tv -ErrorAction SilentlyContinue
  if ([string]::IsNullOrEmpty($rep.TargetVolume)) { $rep.Kind = 'unresolved' }
  elseif ($drive -and $rep.TargetVolume.TrimEnd(':') -eq $drive.TrimEnd(':')) { $rep.Kind = 'same-volume' }
  else { $rep.Kind = 'other-volume' }
}
$sameVol = @($allReps | Where-Object { $_.Kind -eq 'same-volume' }).Count
$otherVol = @($allReps | Where-Object { $_.Kind -eq 'other-volume' })
$unresolved = @($allReps | Where-Object { $_.Kind -eq 'unresolved' }).Count

if ($Physical) {
  "physical: allocated {0:N2} GB / hardlink-dedup saved {1:N2} GB" -f ($sumPhysical/1GB), ($sumHardSaved/1GB)
  "  (logical {0:N2} GB vs allocated {1:N2} GB - difference = sparse/compressed/hardlink)" -f ($total/1GB), ($sumPhysical/1GB)
} else {
  "physical: not measured (pass -Physical to compare logical length with allocated bytes)"
}

"completeness: reparse-skipped={0} denied={1} unreadable-dirs={2}" -f $sumReparse, $sumDenied, $sumSkipped
"reparse targets: same-volume={0} other-volume={1} unresolved={2}" -f $sameVol, $otherVol.Count, $unresolved
if ($otherVol.Count -gt 0) {
  "WARNING: {0} reparse target(s) live on OTHER volumes - this scan does not contain their bytes." -f $otherVol.Count
}
if ($unresolved -gt 0) {
  "WARNING: {0} reparse target(s) could not be resolved - their bytes are unaccounted." -f $unresolved
}
if (($sumReparse + $sumDenied + $sumSkipped) -gt 0) {
  "WARNING: scan is PARTIAL. Do not present totals as complete."
}

""
"{0,-40} {1,9} {2,8} {3,-11} {4,-11} {5,7} {6,7}" -f 'DIR','GB','FILES','LASTWRITE','FIRSTWRITE','REPARSE','DENIED'
$r | Sort-Object Bytes -Descending | Select-Object -First $TopN | ForEach-Object {
  $last  = if ($_.MaxWrite -gt [datetime]'1971-01-01') { $_.MaxWrite.ToString('yyyy-MM-dd') } else { '' }
  $first = if ($_.MinWrite -lt [datetime]'2099-01-01') { $_.MinWrite.ToString('yyyy-MM-dd') } else { '' }
  "{0,-40} {1,9:N2} {2,8} {3,-11} {4,-11} {5,7} {6,7}" -f $_.Name, ($_.Bytes/1GB), $_.Files, $last, $first, $_.Reparse, $_.Denied
}

if ($Aging -and $ageBuckets) {
  ""
  "aging by LastWrite (whole subtree):"
  $labels = @('0-30d','31-90d','91-180d','181-365d','>365d')
  for ($i = 0; $i -lt 5; $i++) {
    "{0,-10} {1,10:N2} GB  {2,9} files" -f $labels[$i], ($ageBuckets.Bytes[$i]/1GB), $ageBuckets.Files[$i]
  }
}

if ($OutFile) {
  $rows = $r | Sort-Object Bytes -Descending | ForEach-Object {
    [pscustomobject]@{
      name = $_.Name
      full = $_.Full
      gb = [math]::Round($_.Bytes/1GB, 3)
      bytes = $_.Bytes
      physicalBytes = if ($Physical) { $_.PhysicalBytes } else { $null }
      hardlinkSaved = if ($Physical) { $_.HardlinkSaved } else { $null }
      files = $_.Files
      lastWrite = if ($_.MaxWrite -gt [datetime]'1971-01-01') { $_.MaxWrite.ToString('yyyy-MM-dd') } else { $null }
      firstWrite = if ($_.MinWrite -lt [datetime]'2099-01-01') { $_.MinWrite.ToString('yyyy-MM-dd') } else { $null }
      reparseSkipped = $_.Reparse
      denied = $_.Denied
      unreadableDirs = $_.SkippedDirs
    }
  }
  $json = $rows | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
  "saved: $OutFile"
}

if ($ReparseOut) {
  $reps = @($allReps | Sort-Object Kind, Path | ForEach-Object {
    [pscustomobject]@{ kind = $_.Kind; path = $_.Path; target = $_.Target; targetVolume = $_.TargetVolume }
  })
  $json = $reps | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($ReparseOut, $json, (New-Object System.Text.UTF8Encoding($false)))
  "saved reparse list: $ReparseOut ({0} entries)" -f $reps.Count
}