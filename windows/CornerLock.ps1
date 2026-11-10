# Corner Lock for Windows
# Double-click CornerLock.bat to open. Pick 1 to 4 images (animated GIFs move), press "Lock for 24 hours".
# The images then sit in the four corners of every screen, click-through,
# and are relaunched every minute (also after a restart) until 24 hours have passed.

param([switch]$Overlay)

$AppDir   = Join-Path $env:LOCALAPPDATA 'CornerLock'
$LockFile = Join-Path $AppDir 'until.txt'
$Script   = Join-Path $AppDir 'CornerLock.ps1'
$Vbs      = Join-Path $AppDir 'run-overlay.vbs'
$TaskName = 'CornerLock'
$Hours    = 24
$MaxImages = 4

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-LockUntil {
    if (-not (Test-Path $LockFile)) { return $null }
    try {
        $s = (Get-Content -LiteralPath $LockFile -Raw).Trim()
        return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch { return $null }
}

function Remove-Lock {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

function Start-Overlay {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$Vbs`""
}

function Get-SavedImages {
    return @(Get-ChildItem -LiteralPath $AppDir -Filter 'image*.dat' -ErrorAction SilentlyContinue |
             Sort-Object Name | ForEach-Object { $_.FullName })
}

function Format-Left([datetime]$untilUtc) {
    $left = $untilUtc - [datetime]::UtcNow
    if ($left.TotalSeconds -lt 0) { $left = [TimeSpan]::Zero }
    $mins = [int][Math]::Ceiling($left.TotalMinutes)
    return ('{0}h {1}m' -f [int][Math]::Floor($mins / 60), ($mins % 60))
}

# ---------------------------------------------------------------- overlay mode
if ($Overlay) {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\CornerLockOverlay', [ref]$created)
    if (-not $created) { exit }   # already showing

    $until = Get-LockUntil
    if ($until -eq $null -or $until -le [datetime]::UtcNow) { Remove-Lock; exit }

    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CornerLock
{
    public class CornerForm : Form
    {
        const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
                  WS_EX_NOACTIVATE = 0x8000000, WS_EX_TOPMOST = 0x8;

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
            IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);

        public CornerForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        public void SetBitmap(Bitmap bmp, int x, int y)
        {
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr hBmp = IntPtr.Zero, oldBmp = IntPtr.Zero;
            try
            {
                hBmp = bmp.GetHbitmap(Color.FromArgb(0));
                oldBmp = SelectObject(memDc, hBmp);
                SIZE size = new SIZE { cx = bmp.Width, cy = bmp.Height };
                POINT src = new POINT { x = 0, y = 0 };
                POINT dst = new POINT { x = x, y = y };
                BLENDFUNCTION blend = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
                UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);
            }
            finally
            {
                ReleaseDC(IntPtr.Zero, screenDc);
                if (hBmp != IntPtr.Zero) { SelectObject(memDc, oldBmp); DeleteObject(hBmp); }
                DeleteDC(memDc);
            }
        }
    }

    /// <summary>Frames of one image (a still image has one frame), with per-frame delays in ms.</summary>
    public class Anim
    {
        public List<Bitmap> Frames = new List<Bitmap>();
        public List<int> Delays = new List<int>();
    }

    public class Corner
    {
        public CornerForm Form;
        public Anim Anim;
        public Point Pos;
        public int Frame;
        public int Due;
    }

    public static class Overlay
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;

        const int SourceMaxPx = 192;   // frames are kept at most this big
        const int MaxFrames = 200;

        static readonly List<Corner> corners = new List<Corner>();
        static readonly Dictionary<string, Anim> scaledCache = new Dictionary<string, Anim>();
        static List<Anim> sources;
        static string layout;
        static long untilTicks;

        public static void Run(string[] imagePaths, long untilUtcTicks)
        {
            SetProcessDPIAware();
            untilTicks = untilUtcTicks;
            sources = new List<Anim>();
            if (imagePaths != null)
            {
                foreach (string p in imagePaths)
                {
                    Anim a = LoadAnim(p);
                    if (a != null && a.Frames.Count > 0) sources.Add(a);
                    if (sources.Count == 4) break;
                }
            }
            if (sources.Count == 0) sources.Add(FallbackAnim());
            Build();

            // Housekeeping: end of lock, screen changes, stay on top.
            Timer t = new Timer();
            t.Interval = 2000;
            t.Tick += delegate
            {
                if (DateTime.UtcNow.Ticks >= untilTicks)
                {
                    t.Stop();
                    Clear();
                    Application.ExitThread();
                    return;
                }
                if (Layout() != layout) { Build(); return; }
                foreach (Corner c in corners)
                    SetWindowPos(c.Form.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            };
            t.Start();

            // Animation: each corner advances on its own GIF timing.
            Timer anim = new Timer();
            anim.Interval = 30;
            anim.Tick += delegate { Animate(); };
            anim.Start();

            Application.Run();
        }

        static void Animate()
        {
            int now = Environment.TickCount;
            foreach (Corner c in corners)
            {
                int n = c.Anim.Frames.Count;
                if (n < 2 || unchecked(now - c.Due) < 0) continue;
                int guard = 0;
                while (unchecked(now - c.Due) >= 0 && guard++ < n)
                {
                    c.Frame = (c.Frame + 1) % n;
                    c.Due = unchecked(c.Due + c.Anim.Delays[c.Frame]);
                }
                if (unchecked(now - c.Due) >= 0) c.Due = unchecked(now + c.Anim.Delays[c.Frame]);
                c.Form.SetBitmap(c.Anim.Frames[c.Frame], c.Pos.X, c.Pos.Y);
            }
        }

        static Anim LoadAnim(string path)
        {
            try
            {
                byte[] bytes = File.ReadAllBytes(path);
                using (MemoryStream ms = new MemoryStream(bytes))
                using (Image img = Image.FromStream(ms))
                {
                    Anim a = new Anim();
                    int n = 1;
                    try { n = img.GetFrameCount(FrameDimension.Time); } catch { n = 1; }
                    if (n < 1) n = 1;
                    byte[] delays = null;
                    if (n > 1) { try { delays = img.GetPropertyItem(0x5100).Value; } catch { delays = null; } }
                    int count = Math.Min(n, MaxFrames);
                    for (int i = 0; i < count; i++)
                    {
                        if (n > 1) img.SelectActiveFrame(FrameDimension.Time, i);
                        a.Frames.Add(Fit(img, SourceMaxPx, false));
                        int d = 100;
                        if (delays != null && delays.Length >= (i + 1) * 4)
                        {
                            d = BitConverter.ToInt32(delays, i * 4) * 10;
                            if (d < 20) d = 100;   // same rule browsers use for "as fast as possible" GIFs
                        }
                        a.Delays.Add(d);
                    }
                    return a;
                }
            }
            catch { return null; }
        }

        static Anim FallbackAnim()
        {
            // A plain white dot with a dark ring.
            Bitmap b = new Bitmap(64, 64, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillEllipse(Brushes.Black, 4, 4, 56, 56);
                g.FillEllipse(Brushes.White, 10, 10, 44, 44);
            }
            Anim a = new Anim();
            a.Frames.Add(b);
            a.Delays.Add(1000);
            return a;
        }

        static string Layout()
        {
            string s = "";
            foreach (Screen sc in Screen.AllScreens) s += sc.Bounds.ToString() + ";";
            return s;
        }

        static Bitmap Fit(Image src, int box, bool allowUpscale)
        {
            double k = Math.Min((double)box / src.Width, (double)box / src.Height);
            if (!allowUpscale && k > 1) k = 1;
            int w = Math.Max(1, (int)Math.Round(src.Width * k));
            int h = Math.Max(1, (int)Math.Round(src.Height * k));
            Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(src, 0, 0, w, h);
            }
            return b;
        }

        static Anim Scaled(int sourceIndex, int box)
        {
            string key = sourceIndex + ":" + box;
            Anim cached;
            if (scaledCache.TryGetValue(key, out cached)) return cached;
            Anim src = sources[sourceIndex];
            Anim a = new Anim();
            for (int i = 0; i < src.Frames.Count; i++)
            {
                a.Frames.Add(Fit(src.Frames[i], box, true));
                a.Delays.Add(src.Delays[i]);
            }
            scaledCache[key] = a;
            return a;
        }

        static void Clear()
        {
            foreach (Corner c in corners) { c.Form.Close(); c.Form.Dispose(); }
            corners.Clear();
            foreach (Anim a in scaledCache.Values)
                foreach (Bitmap b in a.Frames) b.Dispose();
            scaledCache.Clear();
        }

        static void Build()
        {
            Clear();
            layout = Layout();
            int now = Environment.TickCount;
            foreach (Screen sc in Screen.AllScreens)
            {
                Rectangle r = sc.Bounds;
                int box = Math.Max(32, (int)Math.Round(r.Height * 0.045));   // about 48 px on a 1080p screen
                int m = Math.Max(6, box / 6);
                // Clockwise from top-left, so with 2 images each pair sits on a diagonal.
                for (int k = 0; k < 4; k++)
                {
                    Anim a = Scaled(k % sources.Count, box);
                    Size s = a.Frames[0].Size;
                    Point p;
                    if (k == 0) p = new Point(r.Left + m, r.Top + m);
                    else if (k == 1) p = new Point(r.Right - m - s.Width, r.Top + m);
                    else if (k == 2) p = new Point(r.Right - m - s.Width, r.Bottom - m - s.Height);
                    else p = new Point(r.Left + m, r.Bottom - m - s.Height);

                    CornerForm f = new CornerForm();
                    f.Bounds = new Rectangle(p, s);
                    f.Show();
                    f.SetBitmap(a.Frames[0], p.X, p.Y);

                    Corner c = new Corner();
                    c.Form = f;
                    c.Anim = a;
                    c.Pos = p;
                    c.Frame = 0;
                    c.Due = unchecked(now + a.Delays[0]);
                    corners.Add(c);
                }
            }
        }
    }
}
'@

    [CornerLock.Overlay]::Run([string[]](Get-SavedImages), $until.Ticks)
    Remove-Lock
    $mutex.ReleaseMutex()
    exit
}

# ---------------------------------------------------------------- button window
$until = Get-LockUntil
if ($until -ne $null -and $until -gt [datetime]::UtcNow) {
    if (Test-Path $Vbs) { Start-Overlay }
    [System.Windows.Forms.MessageBox]::Show(
        "Corner Lock is on.`n`n$(Format-Left $until) left.", 'Corner Lock') | Out-Null
    exit
}

$here = Split-Path -Parent $PSCommandPath
$script:chosen = New-Object 'System.Collections.Generic.List[byte[]]'
$script:streams = New-Object System.Collections.ArrayList   # GIF previews need their streams kept open
$defaultImage = Join-Path $here 'image.png'
if (Test-Path $defaultImage) { $script:chosen.Add([IO.File]::ReadAllBytes($defaultImage)) }

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Corner Lock'
$form.ClientSize = New-Object System.Drawing.Size(340, 330)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$label = New-Object System.Windows.Forms.Label
$label.Text = "These go in the four corners of your screen for 24 hours.`nPick 1 image for all corners, or up to 4 (one per corner). Animated GIFs move."
$label.SetBounds(20, 15, 300, 65)
$form.Controls.Add($label)

$slots = @()
for ($i = 0; $i -lt $MaxImages; $i++) {
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SetBounds(20 + $i * 78, 90, 70, 70)
    $pb.SizeMode = 'Zoom'
    $form.Controls.Add($pb)
    $slots += $pb
}

function Show-Choice {
    for ($i = 0; $i -lt $MaxImages; $i++) {
        $pb = $slots[$i]
        if ($i -lt $script:chosen.Count) {
            $ms = New-Object IO.MemoryStream(,$script:chosen[$i])
            [void]$script:streams.Add($ms)
            $pb.Image = [System.Drawing.Image]::FromStream($ms)
            $pb.Visible = $true
        } else {
            $pb.Image = $null
            $pb.Visible = $false
        }
    }
}
Show-Choice

$choose = New-Object System.Windows.Forms.Button
$choose.Text = 'Choose images (1 to 4)...'
$choose.SetBounds(20, 180, 300, 40)
$choose.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $picked = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($f in ($dlg.FileNames | Select-Object -First $MaxImages)) {
        try {
            $bytes = [IO.File]::ReadAllBytes($f)
            $ms = New-Object IO.MemoryStream(,$bytes)
            [System.Drawing.Image]::FromStream($ms).Dispose()   # just checks it opens
            $ms.Dispose()
            $picked.Add($bytes)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Couldn't open:`n$f", 'Corner Lock') | Out-Null
            return
        }
    }
    if ($picked.Count -gt 0) {
        $script:chosen = $picked
        Show-Choice
    }
})
$form.Controls.Add($choose)

$lock = New-Object System.Windows.Forms.Button
$lock.Text = 'Lock for 24 hours'
$lock.SetBounds(20, 230, 300, 48)
$lock.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lock.Add_Click({
    if ($script:chosen.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Choose an image first.', 'Corner Lock') | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "The images will stay in your screen corners for 24 hours and come back if closed.`n`nLock now?",
        'Corner Lock', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    try {
        New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
        Get-SavedImages | ForEach-Object { Remove-Item -LiteralPath $_ -Force }
        for ($i = 0; $i -lt $script:chosen.Count; $i++) {
            [IO.File]::WriteAllBytes((Join-Path $AppDir ('image{0}.dat' -f ($i + 1))), $script:chosen[$i])
        }
        Copy-Item -LiteralPath $PSCommandPath -Destination $Script -Force
        $cmd = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""' +
               $Script + '"" -Overlay", 0, False'
        Set-Content -LiteralPath $Vbs -Value $cmd -Encoding Unicode
        [datetime]::UtcNow.AddHours($Hours).ToString('o') | Set-Content -LiteralPath $LockFile -Encoding ASCII
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Something went wrong:`n$($_.Exception.Message)", 'Corner Lock') | Out-Null
        return
    }

    # Relaunch every minute (covers closing it in Task Manager and restarts) until the lock ends.
    try {
        $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$Vbs`""
        $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                        -RepetitionInterval (New-TimeSpan -Minutes 1) `
                        -RepetitionDuration (New-TimeSpan -Hours ($Hours + 1))
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "The corners are on, but Windows wouldn't let me set up the auto-relaunch:`n$($_.Exception.Message)`n`nIf the overlay gets closed or the PC restarts, open Corner Lock again to bring it back.",
            'Corner Lock') | Out-Null
    }

    Start-Overlay
    $form.Close()
})
$form.Controls.Add($lock)

$form.ShowDialog() | Out-Null
