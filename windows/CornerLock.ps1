# Corner Lock for Windows
# Double-click CornerLock.bat to open. Pick an image, press "Lock for 24 hours".
# The image then sits in all four corners of every screen, click-through,
# and is relaunched every minute (also after a restart) until 24 hours have passed.

param([switch]$Overlay)

$AppDir   = Join-Path $env:LOCALAPPDATA 'CornerLock'
$LockFile = Join-Path $AppDir 'until.txt'
$ImgFile  = Join-Path $AppDir 'image.png'
$Script   = Join-Path $AppDir 'CornerLock.ps1'
$Vbs      = Join-Path $AppDir 'run-overlay.vbs'
$TaskName = 'CornerLock'
$Hours    = 24

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

function Test-Locked {
    $u = Get-LockUntil
    return ($u -ne $null -and $u -gt [datetime]::UtcNow)
}

function Remove-Lock {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

function Start-Overlay {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$Vbs`""
}

function Read-ImageNoLock([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    $copy = New-Object System.Drawing.Bitmap($img)
    $img.Dispose(); $ms.Dispose()
    return $copy
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

    public static class Overlay
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;

        static readonly List<CornerForm> forms = new List<CornerForm>();
        static Bitmap source;
        static string layout;
        static long untilTicks;

        public static void Run(string imagePath, long untilUtcTicks)
        {
            SetProcessDPIAware();
            untilTicks = untilUtcTicks;
            source = LoadImage(imagePath);
            Build();

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
                foreach (CornerForm f in forms)
                    SetWindowPos(f.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            };
            t.Start();
            Application.Run();
        }

        static Bitmap LoadImage(string path)
        {
            if (File.Exists(path))
            {
                try
                {
                    using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path)))
                    using (Image img = Image.FromStream(ms))
                        return new Bitmap(img);
                }
                catch { }
            }
            // Fallback: a plain white dot with a dark ring.
            Bitmap b = new Bitmap(64, 64, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillEllipse(Brushes.Black, 4, 4, 56, 56);
                g.FillEllipse(Brushes.White, 10, 10, 44, 44);
            }
            return b;
        }

        static string Layout()
        {
            string s = "";
            foreach (Screen sc in Screen.AllScreens) s += sc.Bounds.ToString() + ";";
            return s;
        }

        static Bitmap Fit(Bitmap src, int box)
        {
            double k = Math.Min((double)box / src.Width, (double)box / src.Height);
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

        static void Clear()
        {
            foreach (CornerForm f in forms) { f.Close(); f.Dispose(); }
            forms.Clear();
        }

        static void Build()
        {
            Clear();
            layout = Layout();
            foreach (Screen sc in Screen.AllScreens)
            {
                Rectangle r = sc.Bounds;
                int box = Math.Max(32, (int)Math.Round(r.Height * 0.045));   // about 48 px on a 1080p screen
                int m = Math.Max(6, box / 6);
                using (Bitmap bmp = Fit(source, box))
                {
                    Point[] pts = {
                        new Point(r.Left + m, r.Top + m),
                        new Point(r.Right - m - bmp.Width, r.Top + m),
                        new Point(r.Left + m, r.Bottom - m - bmp.Height),
                        new Point(r.Right - m - bmp.Width, r.Bottom - m - bmp.Height)
                    };
                    foreach (Point p in pts)
                    {
                        CornerForm f = new CornerForm();
                        f.Bounds = new Rectangle(p, bmp.Size);
                        f.Show();
                        f.SetBitmap(bmp, p.X, p.Y);
                        forms.Add(f);
                    }
                }
            }
        }
    }
}
'@

    [CornerLock.Overlay]::Run($ImgFile, $until.Ticks)
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
$chosen = $null
if (Test-Path (Join-Path $here 'image.png')) { $chosen = Join-Path $here 'image.png' }

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Corner Lock'
$form.ClientSize = New-Object System.Drawing.Size(320, 380)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$label = New-Object System.Windows.Forms.Label
$label.Text = 'This image goes in all four corners of your screen for 24 hours.'
$label.SetBounds(20, 15, 280, 45)
$form.Controls.Add($label)

$pic = New-Object System.Windows.Forms.PictureBox
$pic.SetBounds(85, 65, 150, 150)
$pic.SizeMode = 'Zoom'
if ($chosen) { $pic.Image = Read-ImageNoLock $chosen }
$form.Controls.Add($pic)

$choose = New-Object System.Windows.Forms.Button
$choose.Text = 'Choose image...'
$choose.SetBounds(20, 230, 280, 40)
$choose.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            $pic.Image = Read-ImageNoLock $dlg.FileName
            $script:chosen = $dlg.FileName
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Couldn't open that image.", 'Corner Lock') | Out-Null
        }
    }
})
$form.Controls.Add($choose)

$lock = New-Object System.Windows.Forms.Button
$lock.Text = 'Lock for 24 hours'
$lock.SetBounds(20, 280, 280, 48)
$lock.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lock.Add_Click({
    if (-not $pic.Image) {
        [System.Windows.Forms.MessageBox]::Show('Choose an image first.', 'Corner Lock') | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "The image will stay in your screen corners for 24 hours and comes back if closed.`n`nLock now?",
        'Corner Lock', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    try {
        New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
        $pic.Image.Save($ImgFile, [System.Drawing.Imaging.ImageFormat]::Png)
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
