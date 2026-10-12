// SwHarness - drives SOLIDWORKS for the end-to-end test
// (tests\SolidWorks.Tests.ps1).
//
// RunMacro runs a macro the way a user does (ISldWorks.RunMacro2) on a
// worker thread. Meanwhile it watches for dialogs SOLIDWORKS shows - the
// macro's message boxes - records their title, text and buttons, and
// presses OK (else No, else Cancel) so the macro can go on. A message box
// would otherwise block RunMacro2 forever.
//
// Compiled by the test with Add-Type, against SOLIDWORKS's interop
// assemblies. Keep this file ASCII.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;

namespace ClaudeReview.Tests
{
    public sealed class DialogInfo
    {
        public string Title;
        public string Text;
        public string Buttons;
        public string Pressed;
        public double AtSeconds;
        public override string ToString() { return "[" + Title + "] " + Text + " {" + Buttons + "} -> " + Pressed; }
    }

    public sealed class MacroRun
    {
        public bool Finished;
        public bool Returned;
        public int Error;
        public string Exception;
        public double Seconds;
        public List<DialogInfo> Dialogs = new List<DialogInfo>();
    }

    public static class SwHarness
    {
        // Attaches to the running SOLIDWORKS of this version (ProgID e.g.
        // SldWorks.Application.33 for 2025) or starts it, and waits until
        // it has finished starting.
        static SldWorks app;

        // PowerShell can't hand a SOLIDWORKS COM object back to C#, so the
        // connection stays here and the other calls use it.
        public static void Connect(string progId, int timeoutSeconds)
        {
            Type t = Type.GetTypeFromProgID(progId, true);
            app = (SldWorks)Activator.CreateInstance(t);
            var sw = Stopwatch.StartNew();
            while (!app.StartupProcessCompleted)
            {
                if (sw.Elapsed.TotalSeconds > timeoutSeconds)
                    throw new TimeoutException("SOLIDWORKS didn't finish starting within " + timeoutSeconds + " s.");
                Thread.Sleep(500);
            }
            app.Visible = true;
        }

        // PowerShell can't call SOLIDWORKS's COM objects late-bound
        // (TYPE_E_ELEMENTNOTFOUND), so everything the test needs is here.
        public static string Revision() { return app.RevisionNumber(); }
        public static int ProcessId() { return app.GetProcessID(); }

        // Full paths of the open documents.
        public static string[] OpenDocuments()
        {
            var paths = new List<string>();
            object docs = app.GetDocuments();
            if (docs is object[])
                foreach (object o in (object[])docs)
                {
                    var d = o as ModelDoc2;
                    if (d != null) paths.Add(d.GetPathName());
                }
            return paths.ToArray();
        }

        // "<path>|<type>" of the active document (type: 1 part, 2
        // assembly, 3 drawing), or "" when none is open.
        public static string ActiveDocument()
        {
            var d = app.ActiveDoc as ModelDoc2;
            return d == null ? "" : d.GetPathName() + "|" + d.GetType();
        }

        public static bool Activate(string path)
        {
            var d = app.GetOpenDocumentByName(path) as ModelDoc2;
            if (d == null) return false;
            int err = 0;
            app.ActivateDoc3(d.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref err);
            return true;
        }

        public static bool Open(string path)
        {
            int type = path.EndsWith(".SLDDRW", StringComparison.OrdinalIgnoreCase) ? (int)swDocumentTypes_e.swDocDRAWING
                     : path.EndsWith(".SLDASM", StringComparison.OrdinalIgnoreCase) ? (int)swDocumentTypes_e.swDocASSEMBLY
                     : (int)swDocumentTypes_e.swDocPART;
            int errs = 0, warns = 0;
            var d = app.OpenDoc6(path, type, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref errs, ref warns);
            if (d == null) return false;
            return Activate(path);
        }

        // Closes a document without saving; false if it wasn't open.
        public static bool Close(string path)
        {
            var d = app.GetOpenDocumentByName(path) as ModelDoc2;
            if (d == null) return false;
            app.CloseDoc(d.GetTitle());
            return true;
        }

        // True when an open document has unsaved changes.
        public static bool IsDirty(string path)
        {
            var d = app.GetOpenDocumentByName(path) as ModelDoc2;
            return d != null && d.GetSaveFlag();
        }

        public static void Exit() { app.ExitApp(); }

        // pid: the SOLIDWORKS process (ISldWorks.GetProcessID), whose
        // dialogs are answered.
        public static MacroRun RunMacro(string progId, int pid, string swpPath, string module, string procedure,
                                        int timeoutSeconds, string screenshotOnTimeout)
        {
            var run = new MacroRun();
            var worker = new Thread(() =>
            {
                try
                {
                    var app = (SldWorks)Activator.CreateInstance(Type.GetTypeFromProgID(progId, true));
                    int err;
                    run.Returned = app.RunMacro2(swpPath, module, procedure,
                        (int)swRunMacroOption_e.swRunMacroUnloadAfterRun, out err);
                    run.Error = err;
                }
                catch (Exception ex)
                {
                    run.Exception = ex.GetType().Name + ": " + ex.Message;
                }
            });
            worker.SetApartmentState(ApartmentState.STA);
            worker.IsBackground = true;

            var clock = Stopwatch.StartNew();
            worker.Start();
            var seen = new HashSet<IntPtr>();
            while (worker.IsAlive)
            {
                if (clock.Elapsed.TotalSeconds > timeoutSeconds)
                {
                    if (!string.IsNullOrEmpty(screenshotOnTimeout)) TrySaveScreenshot(screenshotOnTimeout);
                    run.Exception = "The macro didn't finish within " + timeoutSeconds + " s." +
                                    (run.Dialogs.Count > 0 ? "" : " No dialog was seen.");
                    run.Seconds = clock.Elapsed.TotalSeconds;
                    return run;
                }
                foreach (IntPtr dlg in FindDialogs(pid))
                {
                    if (seen.Contains(dlg)) continue;
                    // Let the dialog finish drawing its text.
                    Thread.Sleep(250);
                    if (!IsWindow(dlg)) continue;
                    seen.Add(dlg);
                    DialogInfo info = Describe(dlg);
                    info.AtSeconds = clock.Elapsed.TotalSeconds;
                    info.Pressed = Answer(dlg);
                    run.Dialogs.Add(info);
                }
                Thread.Sleep(200);
            }
            run.Finished = true;
            run.Seconds = clock.Elapsed.TotalSeconds;
            return run;
        }

        // Visible dialog windows (#32770) of the SOLIDWORKS process.
        public static List<IntPtr> FindDialogs(int pid)
        {
            var found = new List<IntPtr>();
            EnumWindows((h, l) =>
            {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if ((pid == 0 || owner == pid) && IsWindowVisible(h) && ClassOf(h) == "#32770") found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found;
        }

        static DialogInfo Describe(IntPtr dlg)
        {
            var text = new List<string>();
            var buttons = new List<string>();
            EnumChildWindows(dlg, (h, l) =>
            {
                string cls = ClassOf(h);
                string t = TextOf(h);
                if (cls == "Static" && t.Length > 0) text.Add(t);
                else if (cls == "Button" && t.Length > 0) buttons.Add(t.Replace("&", ""));
                return true;
            }, IntPtr.Zero);
            return new DialogInfo { Title = TextOf(dlg), Text = string.Join("\n", text), Buttons = string.Join(", ", buttons) };
        }

        // OK, else No, else Cancel: what lets a macro carry on without
        // changing anything.
        static string Answer(IntPtr dlg)
        {
            foreach (int id in new[] { 1, 7, 2 })
            {
                IntPtr button = GetDlgItem(dlg, id);
                if (button != IntPtr.Zero && IsWindowVisible(button))
                {
                    string label = TextOf(button).Replace("&", "");
                    PostMessage(dlg, 0x0111 /* WM_COMMAND */, (IntPtr)id, button);
                    return label;
                }
            }
            PostMessage(dlg, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
            return "(closed)";
        }

        public static void TrySaveScreenshot(string path)
        {
            try
            {
                int w = GetSystemMetrics(78), h = GetSystemMetrics(79); // virtual screen
                int x = GetSystemMetrics(76), y = GetSystemMetrics(77);
                using (var bmp = new Bitmap(w, h))
                using (var g = Graphics.FromImage(bmp))
                {
                    g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
                    bmp.Save(path, ImageFormat.Png);
                }
            }
            catch { }
        }

        static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        // WM_GETTEXT: GetWindowText doesn't read controls of other processes.
        static string TextOf(IntPtr h)
        {
            IntPtr len;
            if (SendMessageTimeout(h, 0x000E /* WM_GETTEXTLENGTH */, IntPtr.Zero, IntPtr.Zero, 2, 2000, out len) == IntPtr.Zero) return "";
            int n = (int)len;
            if (n <= 0) return "";
            var buf = Marshal.AllocHGlobal((n + 1) * 2);
            try
            {
                IntPtr got;
                SendMessageTimeout(h, 0x000D /* WM_GETTEXT */, (IntPtr)(n + 1), buf, 2, 2000, out got);
                return Marshal.PtrToStringUni(buf) ?? "";
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr dlg, int id);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    }
}
