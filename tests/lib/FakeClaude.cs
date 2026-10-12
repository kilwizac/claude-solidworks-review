// FakeClaude - stands in for the Claude Code CLI (claude.exe) in tests.
// Compiled to claude.exe by tests\TestHelpers.psm1 and put first on PATH,
// so run-review.ps1 finds it the way it finds the real one.
//
// Environment:
//   FAKE_CLAUDE_LOG     folder to record the call in: args.txt (one
//                       argument per line), cwd.txt, stdin.bin
//   FAKE_CLAUDE_MODE    ok (default) | fail | empty | hang
//   FAKE_CLAUDE_REVIEW  ok: file whose bytes are written to stdout
//   FAKE_CLAUDE_OUTPUT  fail: text written to stdout (default "Invalid API key")
//   FAKE_CLAUDE_EXIT    fail: exit code (default 1)
// hang starts a child process (ping) and never returns; the child's id
// goes in child-pid.txt, so a test can check it was stopped too.
// "claude --version" prints a version and exits.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class FakeClaude
{
    public static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--version")
        {
            Console.WriteLine("9.9.9 (Fake Claude Code)");
            return 0;
        }

        string log = Environment.GetEnvironmentVariable("FAKE_CLAUDE_LOG");
        byte[] stdin = ReadAll(Console.OpenStandardInput());
        if (!string.IsNullOrEmpty(log))
        {
            Directory.CreateDirectory(log);
            File.WriteAllLines(Path.Combine(log, "args.txt"), args, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(log, "cwd.txt"), Environment.CurrentDirectory, new UTF8Encoding(false));
            File.WriteAllBytes(Path.Combine(log, "stdin.bin"), stdin);
        }

        string mode = Environment.GetEnvironmentVariable("FAKE_CLAUDE_MODE") ?? "ok";
        Stream stdout = Console.OpenStandardOutput();
        switch (mode)
        {
            case "fail":
            {
                string text = Environment.GetEnvironmentVariable("FAKE_CLAUDE_OUTPUT") ?? "Invalid API key - Please run /login";
                Write(stdout, Encoding.UTF8.GetBytes(text + "\n"));
                int code;
                if (!int.TryParse(Environment.GetEnvironmentVariable("FAKE_CLAUDE_EXIT"), out code)) code = 1;
                return code;
            }
            case "empty":
                return 0;
            case "hang":
            {
                var child = Process.Start(new ProcessStartInfo("ping.exe", "-n 3600 127.0.0.1")
                {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true
                });
                if (!string.IsNullOrEmpty(log))
                    File.WriteAllText(Path.Combine(log, "child-pid.txt"), child.Id.ToString());
                Thread.Sleep(Timeout.Infinite);
                return 0;
            }
            default:
            {
                string review = Environment.GetEnvironmentVariable("FAKE_CLAUDE_REVIEW");
                byte[] bytes = string.IsNullOrEmpty(review)
                    ? Encoding.UTF8.GetBytes("Verdict: Ready to release\n\nNothing to report.\n")
                    : File.ReadAllBytes(review);
                Write(stdout, bytes);
                return 0;
            }
        }
    }

    static byte[] ReadAll(Stream s)
    {
        var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    static void Write(Stream s, byte[] bytes)
    {
        s.Write(bytes, 0, bytes.Length);
        s.Flush();
    }
}
