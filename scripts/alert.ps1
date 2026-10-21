# Plays rain or snow over every screen and flashes the project's VS Code taskbar button.
# The look follows RainProject (github.com/riyasy/RainProject): thin streaks that splatter on the ground, and soft
# flakes that settle into a heap. The code is a fresh GDI+ implementation, not a port of its source.
# Each screen gets a click-through, never-focused, per-pixel-alpha overlay, so it cannot steal input while it shows.
# The effect loops until Space is pressed, -StopFile holds the word "stop", or -MaxSeconds pass, then fades out.
# A corner hint says so, with a countdown to the remote alert when -NotifyAt (Unix ms) is set.
# Exits 2 when Space dismissed it, which tells the hook someone is at the screen.
param(
    [ValidateSet('snow', 'rain')]
    [string]$Effect = 'snow',
    [string]$Color = '#FFFFFF',
    [string]$Project = '',
    [int]$MaxSeconds = 120,
    [string]$StopFile = '',
    [long]$NotifyAt = 0
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
    }

    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, uint crKey, ref BLENDFUNCTION pblend, uint dwFlags);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
}

// A full-screen layered window drawn through a premultiplied 32-bit DIB that GDI+ paints into directly.
public class Overlay : Form {
    readonly IntPtr memDc, dib, oldBitmap;
    readonly Bitmap canvas;
    public readonly Graphics G;

    public Overlay(Rectangle bounds) {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        ShowInTaskbar = false;
        TopMost = true;

        Native.BITMAPINFOHEADER header = new Native.BITMAPINFOHEADER();
        header.biSize = (uint)Marshal.SizeOf(header);
        header.biWidth = bounds.Width;
        header.biHeight = -bounds.Height; // top-down rows, matching GDI+'s layout
        header.biPlanes = 1;
        header.biBitCount = 32;
        IntPtr bits;
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        memDc = Native.CreateCompatibleDC(screenDc);
        dib = Native.CreateDIBSection(screenDc, ref header, 0, out bits, IntPtr.Zero, 0);
        Native.ReleaseDC(IntPtr.Zero, screenDc);
        oldBitmap = Native.SelectObject(memDc, dib);

        canvas = new Bitmap(bounds.Width, bounds.Height, bounds.Width * 4, PixelFormat.Format32bppPArgb, bits);
        G = Graphics.FromImage(canvas);
        G.SmoothingMode = SmoothingMode.AntiAlias;
        G.CompositingQuality = CompositingQuality.HighSpeed;
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    // WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST:
    // per-pixel alpha, click-through, no taskbar entry, never focused, above everything.
    protected override CreateParams CreateParams {
        get { CreateParams p = base.CreateParams; p.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x8000000 | 0x8; return p; }
    }

    // Pushes the canvas to the screen; `alpha` (0-255) fades the whole overlay in and out.
    public void Present(byte alpha) {
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        Native.POINT destination = new Native.POINT { X = Left, Y = Top };
        Native.POINT source = new Native.POINT();
        Native.SIZE size = new Native.SIZE { Width = Width, Height = Height };
        Native.BLENDFUNCTION blend = new Native.BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = alpha, AlphaFormat = 1 };
        Native.UpdateLayeredWindow(Handle, screenDc, ref destination, ref size, memDc, ref source, 0, ref blend, 2);
        Native.ReleaseDC(IntPtr.Zero, screenDc);
    }

    protected override void Dispose(bool disposing) {
        G.Dispose();
        canvas.Dispose();
        Native.SelectObject(memDc, oldBitmap);
        Native.DeleteObject(dib);
        Native.DeleteDC(memDc);
        base.Dispose(disposing);
    }
}

public abstract class Scene {
    protected static readonly Random Rng = new Random();
    protected readonly float Width, Ground, Scale;
    protected readonly Color Tint;

    // `ground` is where particles land: the top of a bottom taskbar, else the screen's bottom edge.
    protected Scene(float width, float ground, float height, Color tint) {
        Width = width;
        Ground = ground;
        Scale = height / 1080f;
        Tint = tint;
    }

    protected static float Range(float min, float max) { return min + (float)Rng.NextDouble() * (max - min); }

    public abstract void Update(float seconds);
    public abstract void Draw(Graphics g);
}

// Rain: thin streaks at terminal speed, slanted by the wind, that splatter into bouncing droplets on landing.
public class RainScene : Scene {
    const float TerminalSpeed = 1000, WindSpeed = 75 * 3;
    const float SplatterSeconds = 0.5f, SplatterSpeed = 200, Gravity = 1000, AirDrag = 2, Bounce = 0.9f;

    class Droplet { public float X, Y, Vx, Vy, Radius; public int Bounces; }
    class Drop {
        public float X, Y, Width, Length, SplatterTime;
        public bool HasLanded;
        public List<Droplet> Droplets = new List<Droplet>();
    }

    readonly List<Drop> drops = new List<Drop>();
    readonly Pen pen;
    readonly SolidBrush brush;
    readonly float dirX, dirY;

    public RainScene(float width, float ground, float height, Color tint, int count) : base(width, ground, height, tint) {
        pen = new Pen(Color.FromArgb(200, tint), 1) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        brush = new SolidBrush(tint);
        float speed = (float)Math.Sqrt(WindSpeed * WindSpeed + TerminalSpeed * TerminalSpeed);
        dirX = WindSpeed / speed;
        dirY = TerminalSpeed / speed;
        for (int i = 0; i < count; i++) {
            Drop drop = new Drop();
            Spawn(drop, -height);
            drops.Add(drop);
        }
    }

    // Spread across a wider band than the screen so the slant still covers the left edge.
    void Spawn(Drop drop, float top) {
        drop.X = Range(-Width / 3, Width + Width / 3) - WindSpeed * Scale * 0.5f;
        drop.Y = Range(top, 0);
        drop.Width = Range(0.6f, 1.6f) * Scale;
        drop.Length = Range(30, 100) * Scale;
        drop.HasLanded = false;
        drop.SplatterTime = 0;
        drop.Droplets.Clear();
    }

    public override void Update(float seconds) {
        foreach (Drop drop in drops) {
            if (!drop.HasLanded) {
                drop.X += WindSpeed * Scale * seconds;
                drop.Y += TerminalSpeed * Scale * seconds;
                if (drop.Y < Ground) continue;
                drop.HasLanded = true;
                drop.Y = Ground;
                if (drop.X < 0 || drop.X > Width) { Spawn(drop, -Ground / 2); continue; }
                for (int i = 0; i < 3; i++) {
                    // Up and out to either side: 20-70 or 110-160 degrees.
                    double angle = (Rng.Next(2) == 0 ? Range(20, 70) : Range(110, 160)) * Math.PI / 180;
                    drop.Droplets.Add(new Droplet {
                        X = drop.X, Y = Ground - 2 * Scale,
                        Vx = (float)(SplatterSpeed * Math.Cos(angle)) * Scale,
                        Vy = (float)(-SplatterSpeed * Math.Sin(angle)) * Scale,
                        Radius = Range(1.5f, 2.5f) * Scale
                    });
                }
                continue;
            }

            foreach (Droplet d in drop.Droplets) {
                d.X += d.Vx * seconds;
                d.Y += d.Vy * seconds;
                d.Vy += Gravity * Scale * seconds;
                d.Vx *= 1 - AirDrag * seconds;
                if (d.Y + d.Radius > Ground) { d.Y = Ground - d.Radius; d.Vy = -d.Vy * Bounce; d.Bounces++; }
            }
            drop.SplatterTime += seconds;
            if (drop.SplatterTime >= SplatterSeconds) Spawn(drop, -Ground / 4);
        }
    }

    public override void Draw(Graphics g) {
        foreach (Drop drop in drops) {
            if (!drop.HasLanded) {
                if (drop.Y < 0) continue;
                pen.Width = drop.Width;
                g.DrawLine(pen, drop.X - drop.Length * dirX, drop.Y - drop.Length * dirY, drop.X, drop.Y);
                continue;
            }
            // Droplets fade from 75% to nothing over the splatter's half second, and vanish after two bounces.
            int alpha = (int)(Math.Max(0, 1 - drop.SplatterTime / SplatterSeconds) * 0.75 * 255);
            brush.Color = Color.FromArgb(alpha, Tint);
            foreach (Droplet d in drop.Droplets) {
                if (d.Bounces < 2) g.FillEllipse(brush, d.X - d.Radius, d.Y - d.Radius, d.Radius * 2, d.Radius * 2);
            }
        }
    }
}

// Snow: soft flakes drifting down with a sway, piling into a heap along the ground that slumps to stay smooth.
public class SnowScene : Scene {
    const float MaxSpeed = 75, Fall = 10, Sway = 20, ColumnWidth = 12, MaxHeapFraction = 0.12f;

    class Flake { public float X, Y, Vy, Radius, Phase; }

    readonly List<Flake> flakes = new List<Flake>();
    readonly float[] heap;
    readonly SolidBrush halo, core, heapBrush;
    readonly float columnWidth;
    float time;

    public SnowScene(float width, float ground, float height, Color tint, int count) : base(width, ground, height, tint) {
        halo = new SolidBrush(Color.FromArgb(70, tint));
        core = new SolidBrush(Color.FromArgb(230, tint));
        heapBrush = new SolidBrush(Color.FromArgb(235, tint));
        columnWidth = ColumnWidth * Scale;
        heap = new float[(int)(width / columnWidth) + 2];
        // Start spread over the whole screen, so the snow is already falling when it fades in.
        for (int i = 0; i < count; i++) {
            Flake flake = new Flake();
            Spawn(flake, 0, ground);
            flakes.Add(flake);
        }
    }

    void Spawn(Flake flake, float top, float bottom) {
        flake.X = Range(0, Width);
        flake.Y = Range(top, bottom);
        flake.Radius = Range(0.8f, 2.5f) * 1.3f * Scale;
        // Smaller flakes fall slower, which reads as depth.
        flake.Vy = MaxSpeed * Scale * (0.4f + 0.6f * flake.Radius / (3.25f * Scale)) * Range(0.5f, 1);
        flake.Phase = Range(0, (float)Math.PI * 2);
    }

    public override void Update(float seconds) {
        time += seconds;
        float maxHeap = Ground * MaxHeapFraction;
        foreach (Flake flake in flakes) {
            flake.Vy = Math.Min(flake.Vy + Fall * Scale * seconds, MaxSpeed * Scale);
            flake.Y += flake.Vy * seconds;
            flake.X += (float)Math.Sin(time * 1.3 + flake.Phase) * Sway * Scale * seconds;
            if (flake.X < 0) flake.X += Width;
            if (flake.X > Width) flake.X -= Width;

            int column = Math.Min(heap.Length - 1, Math.Max(0, (int)(flake.X / columnWidth)));
            if (flake.Y + flake.Radius < Ground - heap[column]) continue;
            heap[column] = Math.Min(maxHeap, heap[column] + flake.Radius * 0.5f);
            Spawn(flake, -Ground * 0.1f, 0);
        }

        // Slump: a column much taller than its neighbour sheds some snow to it.
        for (int i = 0; i < heap.Length - 1; i++) {
            float difference = heap[i] - heap[i + 1];
            if (Math.Abs(difference) <= 2 * Scale) continue;
            float moved = difference * 0.08f;
            heap[i] -= moved;
            heap[i + 1] += moved;
        }
    }

    public override void Draw(Graphics g) {
        foreach (Flake flake in flakes) {
            if (flake.Y < -flake.Radius) continue;
            g.FillEllipse(halo, flake.X - flake.Radius * 1.6f, flake.Y - flake.Radius * 1.6f, flake.Radius * 3.2f, flake.Radius * 3.2f);
            g.FillEllipse(core, flake.X - flake.Radius, flake.Y - flake.Radius, flake.Radius * 2, flake.Radius * 2);
        }

        // The heap as one smooth outline through the column tops.
        PointF[] outline = new PointF[heap.Length + 2];
        for (int i = 0; i < heap.Length; i++) outline[i] = new PointF(i * columnWidth, Ground - heap[i]);
        outline[heap.Length] = new PointF((heap.Length - 1) * columnWidth, Ground);
        outline[heap.Length + 1] = new PointF(0, Ground);
        using (GraphicsPath path = new GraphicsPath()) {
            path.AddCurve(outline, 0, heap.Length - 1, 0.5f);
            path.AddLine(outline[heap.Length - 1], outline[heap.Length]);
            path.AddLine(outline[heap.Length], outline[heap.Length + 1]);
            path.CloseFigure();
            g.FillPath(heapBrush, path);
        }
    }
}

public static class Alert {
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO info);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    // FLASHW_ALL | FLASHW_TIMERNOFG: caption and taskbar button flash until the window comes to the foreground.
    // The project's own window when its title names it, otherwise every VS Code window.
    public static void Flash(string project) {
        List<IntPtr> all = new List<IntPtr>();
        List<IntPtr> matched = new List<IntPtr>();
        EnumWindows((hwnd, lParam) => {
            if (!IsWindowVisible(hwnd)) return true;
            StringBuilder text = new StringBuilder(512);
            GetWindowText(hwnd, text, text.Capacity);
            string title = text.ToString();
            if (!title.EndsWith("Visual Studio Code")) return true;
            all.Add(hwnd);
            if (project.Length > 0 && title.Contains(" - " + project + " ")) matched.Add(hwnd);
            return true;
        }, IntPtr.Zero);

        foreach (IntPtr hwnd in matched.Count > 0 ? matched : all) {
            FLASHWINFO info = new FLASHWINFO { hwnd = hwnd, dwFlags = 0x3 | 0xC, uCount = 0, dwTimeout = 0 };
            info.cbSize = (uint)Marshal.SizeOf(info);
            FlashWindowEx(ref info);
        }
    }

    delegate IntPtr KeyProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, KeyProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    // True once Space ended the effect, rather than the stop file or the cap.
    public static bool IsDismissed;

    // Kept in a field so the collector never frees the delegate the hook calls into.
    static KeyProc keyProc;
    static IntPtr keyHook;
    static bool isSpaceHeld;

    // A low-level keyboard hook, whichever window has focus. Space dismisses, and is swallowed with its repeats and
    // key-up, so it never reaches the focused window and cannot pick or submit anything in Claude's dialog.
    static IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam) {
        // lParam points at a KBDLLHOOKSTRUCT, whose first field is the virtual-key code; 0x20 is Space.
        if (code >= 0 && Marshal.ReadInt32(lParam) == 0x20) {
            int message = wParam.ToInt32();
            // WM_KEYDOWN, WM_SYSKEYDOWN
            if (message == 0x100 || message == 0x104) { IsDismissed = true; isSpaceHeld = true; return (IntPtr)1; }
            // WM_KEYUP, WM_SYSKEYUP
            if ((message == 0x101 || message == 0x105) && isSpaceHeld) { isSpaceHeld = false; return (IntPtr)1; }
        }
        return CallNextHookEx(keyHook, code, wParam, lParam);
    }

    // The corner hint: what Claude waits on, how to dismiss, and when the remote alert goes out.
    static string[] HintLines(string project, long notifyAt) {
        string title = project.Length > 0 ? "Claude is waiting on you \u00B7 " + project : "Claude is waiting on you";
        if (notifyAt <= 0) return new[] { title, "Press Space to dismiss" };
        long left = (notifyAt - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 999) / 1000;
        string countdown = left > 0 ? "Sending notification in " + left + "s" : "Notification sent";
        return new[] { title, "Press Space to dismiss", countdown };
    }

    // Top-right corner, clear of the snow heap and the taskbar.
    static void DrawHint(Graphics g, float width, float scale, string[] lines) {
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        float margin = 24 * scale, padding = 14 * scale, gap = 4 * scale;
        using (Font bold = new Font("Segoe UI", 18 * scale, FontStyle.Bold, GraphicsUnit.Pixel))
        using (Font regular = new Font("Segoe UI", 16 * scale, GraphicsUnit.Pixel))
        using (SolidBrush panel = new SolidBrush(Color.FromArgb(190, 24, 24, 28)))
        using (SolidBrush ink = new SolidBrush(Color.White))
        using (SolidBrush dim = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) {
            SizeF[] sizes = new SizeF[lines.Length];
            float boxWidth = 0, boxHeight = 0;
            for (int i = 0; i < lines.Length; i++) {
                sizes[i] = g.MeasureString(lines[i], i == 0 ? bold : regular);
                boxWidth = Math.Max(boxWidth, sizes[i].Width);
                boxHeight += sizes[i].Height + (i > 0 ? gap : 0);
            }
            RectangleF box = new RectangleF(width - margin - boxWidth - 2 * padding, margin, boxWidth + 2 * padding, boxHeight + 2 * padding);
            float radius = 10 * scale;
            using (GraphicsPath path = new GraphicsPath()) {
                path.AddArc(box.Left, box.Top, 2 * radius, 2 * radius, 180, 90);
                path.AddArc(box.Right - 2 * radius, box.Top, 2 * radius, 2 * radius, 270, 90);
                path.AddArc(box.Right - 2 * radius, box.Bottom - 2 * radius, 2 * radius, 2 * radius, 0, 90);
                path.AddArc(box.Left, box.Bottom - 2 * radius, 2 * radius, 2 * radius, 90, 90);
                path.CloseFigure();
                g.FillPath(panel, path);
            }
            float y = box.Top + padding;
            for (int i = 0; i < lines.Length; i++) {
                g.DrawString(lines[i], i == 0 ? bold : regular, i == 0 ? ink : dim, box.Left + padding, y);
                y += sizes[i].Height + gap;
            }
        }
    }

    static bool IsStopRequested(string stopFile) {
        if (stopFile.Length == 0) return false;
        try { return System.IO.File.ReadAllText(stopFile).Trim() == "stop"; } catch { return false; }
    }

    public static void Play(string effect, Color color, int maxSeconds, string stopFile, string project, long notifyAt) {
        Native.SetProcessDPIAware();
        List<Overlay> overlays = new List<Overlay>();
        List<Scene> scenes = new List<Scene>();
        foreach (Screen screen in Screen.AllScreens) {
            Rectangle b = screen.Bounds;
            // Land on a bottom taskbar's top edge; with the taskbar elsewhere, on the screen's bottom edge.
            float ground = screen.WorkingArea.Bottom < b.Bottom ? screen.WorkingArea.Bottom - b.Top : b.Height;
            float density = b.Width / 1920f;
            scenes.Add(effect == "rain"
                ? (Scene)new RainScene(b.Width, ground, b.Height, color, (int)(140 * density))
                : new SnowScene(b.Width, ground, b.Height, color, (int)(450 * density)));
            Overlay overlay = new Overlay(b);
            overlay.Show();
            overlays.Add(overlay);
        }

        // Fade in over 0.3 s; fade out over 0.6 s once Space, the stop file or the cap ends it.
        const float fadeIn = 0.3f, fadeOut = 0.6f;
        Stopwatch clock = Stopwatch.StartNew();
        float last = 0;
        float stoppedAt = -1;
        int frame = 0;
        // WH_KEYBOARD_LL; its callbacks arrive on this thread's message loop.
        keyProc = OnKey;
        keyHook = SetWindowsHookEx(13, keyProc, GetModuleHandle(null), 0);

        Timer timer = new Timer { Interval = 15 };
        timer.Tick += (sender, args) => {
            frame++;
            float now = (float)clock.Elapsed.TotalSeconds;
            float step = Math.Min(0.05f, now - last);
            last = now;

            if (stoppedAt < 0 && (IsDismissed || now >= maxSeconds || (frame % 20 == 0 && IsStopRequested(stopFile)))) stoppedAt = now;
            float level = stoppedAt >= 0 ? 1 - (now - stoppedAt) / fadeOut : Math.Min(1, now / fadeIn);
            if (level <= 0) {
                timer.Stop();
                if (keyHook != IntPtr.Zero) UnhookWindowsHookEx(keyHook);
                foreach (Overlay overlay in overlays) overlay.Close();
                Application.ExitThread();
                return;
            }

            string[] hint = HintLines(project, notifyAt);
            for (int i = 0; i < overlays.Count; i++) {
                scenes[i].Update(step);
                overlays[i].G.Clear(Color.Transparent);
                scenes[i].Draw(overlays[i].G);
                DrawHint(overlays[i].G, overlays[i].Width, overlays[i].Height / 1080f, hint);
                overlays[i].Present((byte)(255 * level));
            }
        };
        timer.Start();
        Application.Run();
    }
}
'@

[Alert]::Flash($Project)
[Alert]::Play($Effect, [System.Drawing.ColorTranslator]::FromHtml($Color), $MaxSeconds, $StopFile, $Project, $NotifyAt)
if ([Alert]::IsDismissed) { exit 2 }
