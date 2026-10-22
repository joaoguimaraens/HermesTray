using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.NetworkInformation;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace HermesTray.Runtime
{
  // Drain a pipe independently of the child and rotate the controller-owned sink.
  sealed class OutputCapture : IDisposable
  {
    readonly string path;
    readonly int limit, backups;
    FileStream output, input;
    Thread worker;
    public volatile bool Failed;
    public OutputCapture(string path, int limit, int backups)
    {
      this.path = path; this.limit = limit; this.backups = backups;
      Rotate();
    }
    void Rotate()
    {
      if (output != null) { output.Dispose(); output = null; }
      if (backups > 0 && File.Exists(path))
      {
        // Bound an oversized log left by an older release before archiving it.
        using (var old = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
          if (old.Length > limit)
          {
            var tail = new byte[limit]; old.Position = old.Length - limit;
            int read = 0, n; while (read < tail.Length && (n = old.Read(tail, read, tail.Length - read)) > 0) read += n;
            old.Position = 0; old.SetLength(0); old.Write(tail, 0, read);
          }
        }
        string last = path + "." + backups;
        if (File.Exists(last)) File.Delete(last);
        for (int i = backups - 1; i >= 1; i--) if (File.Exists(path + "." + i)) File.Move(path + "." + i, path + "." + (i + 1));
        File.Move(path, path + ".1");
      }
      output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
    }
    public void Start(FileStream pipe)
    {
      input = pipe;
      worker = new Thread(Drain) { IsBackground = true, Name = "HermesTray output" };
      worker.Start();
    }
    void Drain()
    {
      try
      {
        var bytes = new byte[4096]; int read;
        while ((read = input.Read(bytes, 0, bytes.Length)) > 0)
        {
          if (Failed) continue; // Drain even after a sink failure; never block the child.
          try
          {
            int offset = 0;
            while (offset < read)
            {
              if (output.Length == limit) { if (backups == 0) break; Rotate(); }
              int count = (int)Math.Min(read - offset, limit - output.Length);
              output.Write(bytes, offset, count); output.Flush(); offset += count;
            }
          }
          catch { Failed = true; }
        }
      }
      catch { Failed = true; }
      finally { CloseStreams(); }
    }
    void CloseStreams()
    {
      try { if (input != null) input.Dispose(); } catch { Failed = true; }
      try { if (output != null) output.Dispose(); } catch { Failed = true; }
    }
    public void Dispose()
    {
      if (worker != null) {
        if (!worker.Join(5000)) { try { if (input != null) input.Dispose(); } catch { Failed = true; } }
      }
      else CloseStreams();
    }
  }

  // Native CLIs join the job atomically inside CreateProcess. MSIX requires
  // suspended creation followed by assignment; its narrow startup gap is documented.
  public sealed class OwnedProcess : IDisposable
  {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
      public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
      public BasicLimits BasicLimitInformation;
      public IoCounters IoInfo;
      public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Accounting
    {
      public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
      public int cb; public string reserved, desktop, title;
      public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
      public ushort showWindow, reserved2; public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint processId, threadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int type, out Accounting info, uint length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFile(string path, uint access, uint share, ref SecurityAttributes attributes, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("iphlpapi.dll", SetLastError = true)] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int kind, uint reserved);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    IntPtr job, process;
    OutputCapture capture;
    public bool OutputFailed { get { return capture != null && capture.Failed; } }
    public int ProcessId { get; private set; }
    public uint ExitCode { get { uint code; return process != IntPtr.Zero && GetExitCodeProcess(process, out code) ? code : 0; } }
    public uint ActiveProcessCount
    {
      get
      {
        Accounting info;
        return job != IntPtr.Zero && QueryInformationJobObject(job, 1, out info, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero) ? info.ActiveProcesses : 0;
      }
    }
    public bool OwnsListener(int port, string bindAddress = "0.0.0.0")
    {
      if (job == IntPtr.Zero) return false;
      int size = 0;
      GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 3, 0); // IPv4, owner-PID listeners
      if (size < 4) return false;
      IntPtr table = Marshal.AllocHGlobal(size);
      try
      {
        if (GetExtendedTcpTable(table, ref size, false, 2, 3, 0) != 0) return false;
        int count = Marshal.ReadInt32(table);
        if (count < 0 || 4L + count * 24L > size) return false;
        for (int i = 0; i < count; i++)
        {
          IntPtr row = IntPtr.Add(table, 4 + i * 24);
          int address = Marshal.ReadInt32(row, 4), rawPort = Marshal.ReadInt32(row, 8);
          int localPort = ((rawPort & 255) << 8) | ((rawPort >> 8) & 255);
          int expected = BitConverter.ToInt32(IPAddress.Parse(bindAddress).GetAddressBytes(), 0);
          if (localPort != port || (expected == 0 ? address != 0 && address != 0x0100007f : address != expected)) continue;
          try
          {
            using (var owner = Process.GetProcessById(Marshal.ReadInt32(row, 20)))
            {
              bool inside;
              if (IsProcessInJob(owner.Handle, job, out inside) && inside) return true;
            }
          }
          catch { /* Unknown ownership never counts as an owned listener. */ }
        }
        return false;
      }
      finally { Marshal.FreeHGlobal(table); }
    }
    public OwnedProcess(string executable, string arguments, string logPath, int maxLogBytes = 1048576, int logBackups = 2)
    {
      // MSIX activation rejects JOB_LIST; native CLIs use atomic job assignment.
      string fullPath = Path.GetFullPath(executable);
      string storeRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps") + Path.DirectorySeparatorChar;
      string aliasRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft\\WindowsApps") + Path.DirectorySeparatorChar;
      bool packaged = fullPath.StartsWith(storeRoot, StringComparison.OrdinalIgnoreCase) || fullPath.StartsWith(aliasRoot, StringComparison.OrdinalIgnoreCase);
      ProcessInfo pi = new ProcessInfo();
      IntPtr output = IntPtr.Zero, input = IntPtr.Zero, readPipe = IntPtr.Zero;
      IntPtr attributes = IntPtr.Zero, jobEntry = IntPtr.Zero, handleEntries = IntPtr.Zero;
      bool attributesReady = false;
      try
      {
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) throw new Win32Exception();
        var sa = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Inherit = true };
        if (maxLogBytes < 1 || logBackups < 0 || logBackups > 10) throw new ArgumentOutOfRangeException("log limits");
        capture = new OutputCapture(logPath, maxLogBytes, logBackups);
        if (!CreatePipe(out readPipe, out output, ref sa, 0)) throw new Win32Exception();
        if (!SetHandleInformation(readPipe, 1, 0)) throw new Win32Exception();
        input = CreateFile("NUL", 0x80000000, 3, ref sa, 3, 0x80, IntPtr.Zero);
        if (input == new IntPtr(-1)) throw new Win32Exception();
        IntPtr attributeSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeSize);
        attributes = Marshal.AllocHGlobal(attributeSize);
        if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref attributeSize)) throw new Win32Exception();
        attributesReady = true;
        jobEntry = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobEntry, job);
        // PROC_THREAD_ATTRIBUTE_JOB_LIST: membership exists before any thread can run.
        if (!packaged && !UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x2000D), jobEntry, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
        handleEntries = Marshal.AllocHGlobal(2 * IntPtr.Size);
        Marshal.WriteIntPtr(handleEntries, output); Marshal.WriteIntPtr(handleEntries, IntPtr.Size, input);
        // Only stdout/stderr and stdin are inherited, never the controller's job handle.
        if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handleEntries, new IntPtr(2 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
        var si = new StartupInfoEx { Startup = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfoEx)), flags = 0x100, stdin = input, stdout = output, stderr = output }, Attributes = attributes };
        if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments), IntPtr.Zero, IntPtr.Zero, true, 0x08000004 | 0x00080000, IntPtr.Zero, Path.GetDirectoryName(executable), ref si, out pi)) throw new Win32Exception();
        process = pi.process; ProcessId = (int)pi.processId;
        if (packaged && !AssignProcessToJobObject(job, process)) throw new Win32Exception();
        var pipe = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(readPipe, true), FileAccess.Read, 4096, false);
        readPipe = IntPtr.Zero; capture.Start(pipe);
        if (ResumeThread(pi.thread) == uint.MaxValue) throw new Win32Exception();
      }
      catch
      {
        if (pi.process != IntPtr.Zero) { TerminateProcess(pi.process, 1); WaitForSingleObject(pi.process, 5000); }
        if (output != IntPtr.Zero && output != new IntPtr(-1)) { CloseHandle(output); output = IntPtr.Zero; }
        Dispose(); throw;
      }
      finally
      {
        if (attributesReady) DeleteProcThreadAttributeList(attributes);
        if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
        if (jobEntry != IntPtr.Zero) Marshal.FreeHGlobal(jobEntry);
        if (handleEntries != IntPtr.Zero) Marshal.FreeHGlobal(handleEntries);
        if (pi.thread != IntPtr.Zero) CloseHandle(pi.thread);
        if (output != IntPtr.Zero && output != new IntPtr(-1)) CloseHandle(output);
        if (input != IntPtr.Zero && input != new IntPtr(-1)) CloseHandle(input);
        if (readPipe != IntPtr.Zero) CloseHandle(readPipe);
      }
    }
    public void Dispose()
    {
      var ownedJob = Interlocked.Exchange(ref job, IntPtr.Zero);
      if (ownedJob != IntPtr.Zero)
      {
        TerminateJobObject(ownedJob, 0);
        if (process != IntPtr.Zero) WaitForSingleObject(process, 5000);
        CloseHandle(ownedJob);
      }
      var ownedProcess = Interlocked.Exchange(ref process, IntPtr.Zero);
      if (ownedProcess != IntPtr.Zero) CloseHandle(ownedProcess);
      if (capture != null) capture.Dispose();
    }
  }

  public sealed class CheckResult
  {
    public int Code;
    public string Reason, Message;
    public bool Retry;
    public static CheckResult Failure(int code, string reason, string message)
    {
      return new CheckResult { Code = code, Reason = reason, Message = message };
    }
  }

  public static class StartupChecks
  {
    public const string AuthenticationMessage = "Dashboard authentication is unavailable. Run 'hermes serve --host 0.0.0.0' in a terminal and configure username/password or OAuth. Stop that server with Ctrl+C, then restart HermesTray.";
    static CheckResult InvalidStatus()
    {
      return CheckResult.Failure(7, "InvalidBackendStatus", "The backend returned an unsupported status response. Update Hermes Agent and check /api/status locally before restarting HermesTray.");
    }
    public static CheckResult CheckStatus(int port, int timeout, CancellationToken token, string address = "127.0.0.1")
    {
      var request = (HttpWebRequest)WebRequest.Create("http://" + address + ":" + port + "/api/status");
      request.Method = "GET"; request.Accept = "application/json"; request.Proxy = null;
      request.AllowAutoRedirect = false; request.UseDefaultCredentials = false;
      request.Credentials = null; request.PreAuthenticate = false; request.KeepAlive = false;
      request.Timeout = Math.Max(1, timeout); request.ReadWriteTimeout = Math.Max(1, timeout);
      using (var deadline = new CancellationTokenSource(Math.Max(1, timeout)))
      using (var linked = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token))
      using (linked.Token.Register(() => request.Abort()))
      {
        try
        {
          token.ThrowIfCancellationRequested();
          using (var response = (HttpWebResponse)request.GetResponse())
          {
            if (response.StatusCode != HttpStatusCode.OK) return InvalidStatus();
            if (response.ContentType == null || response.ContentType.IndexOf("json", StringComparison.OrdinalIgnoreCase) < 0) return InvalidStatus();
            var text = new StringBuilder();
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
              var buffer = new char[4096]; int read;
              while ((read = reader.Read(buffer, 0, buffer.Length)) != 0)
              {
                token.ThrowIfCancellationRequested();
                if (text.Length + read > 262144) return InvalidStatus();
                text.Append(buffer, 0, read);
              }
            }
            // Never include the response body or parser exceptions in logs/notifications.
            Dictionary<string, object> status;
            try { status = new JavaScriptSerializer().DeserializeObject(text.ToString()) as Dictionary<string, object>; }
            catch { return InvalidStatus(); }
            object version, required, registered;
            if (status == null || !status.TryGetValue("version", out version) || !(version is string) || string.IsNullOrWhiteSpace((string)version) || !status.TryGetValue("auth_required", out required) || !(required is bool) || !status.TryGetValue("auth_providers", out registered)) return InvalidStatus();
            var providers = registered as object[];
            if (providers == null) return InvalidStatus();
            foreach (var provider in providers) if (!(provider is string) || string.IsNullOrWhiteSpace((string)provider)) return InvalidStatus();
            if (!(bool)required || providers.Length == 0) return CheckResult.Failure(4, "AuthenticationRequired", AuthenticationMessage);
            return new CheckResult();
          }
        }
        catch (OperationCanceledException) { throw; }
        catch (WebException error)
        {
          token.ThrowIfCancellationRequested();
          using (var response = error.Response as HttpWebResponse)
          {
            if (response != null && (int)response.StatusCode < 500) return InvalidStatus();
            return new CheckResult { Retry = true, Reason = deadline.IsCancellationRequested ? "Timeout" :
              (response != null ? "HTTP " + (int)response.StatusCode : "Transport " + error.Status) };
          }
        }
        catch { token.ThrowIfCancellationRequested(); return new CheckResult { Retry = true, Reason = deadline.IsCancellationRequested ? "Timeout" : "ResponseReadFailed" }; }
      }
    }
    public static bool AuthenticationWasRefused(string path, long startOffset)
    {
      try
      {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
          stream.Position = Math.Max(startOffset, Math.Max(0, stream.Length - 32768));
          using (var reader = new StreamReader(stream, Encoding.UTF8))
          {
            string output = reader.ReadToEnd();
            return output.Contains("no auth providers are registered") || output.Contains("Configure an auth provider before exposing the dashboard");
          }
        }
      }
      catch { return false; }
    }
    static CheckResult Probe(string executable, string arguments, string directory, int timeout, CancellationToken token, bool version)
    {
      string output = Path.Combine(directory, ".probe-" + Guid.NewGuid().ToString("N") + ".log");
      try
      {
        token.ThrowIfCancellationRequested();
        using (var child = new OwnedProcess(executable, arguments, output, 65537, 0))
        {
          var clock = Stopwatch.StartNew();
          while (child.ActiveProcessCount != 0)
          {
            token.ThrowIfCancellationRequested();
            if (clock.ElapsedMilliseconds >= timeout) return CheckResult.Failure(3, "CliTimeout", "Hermes did not respond to a CLI check in time. Run hermes --version in a terminal, repair the installation, and restart HermesTray.");
            Thread.Sleep(30);
          }
          if (child.ExitCode != 0) return CheckResult.Failure(3, "HermesUnusable", "The Hermes CLI check failed. Run hermes --version and hermes serve --help in a terminal, then repair or update Hermes.");
        }
        if (new FileInfo(output).Length > 65536) return CheckResult.Failure(3, "HermesIncompatible", "Unexpected Hermes CLI output. Select a compatible Hermes executable with -HermesPath.");
        string text = File.ReadAllText(output);
        bool valid = version ? Regex.IsMatch(text, @"(?im)^\s*Hermes(?: Agent)?\s+v?\d+\.\d+") : text.Contains("serve") && text.Contains("--host") && text.Contains("--port");
        return valid ? new CheckResult() : CheckResult.Failure(3, "HermesIncompatible", "The executable is not a compatible Hermes CLI. Update Hermes Agent or select its executable with -HermesPath.");
      }
      catch (OperationCanceledException) { throw; }
      catch { return CheckResult.Failure(3, "HermesUnusable", "Hermes could not be executed. Check its installation, permissions, and -HermesPath, then restart HermesTray."); }
      finally { try { if (File.Exists(output)) File.Delete(output); } catch { } }
    }
    public static CheckResult CheckCli(string executable, string directory, int timeout, CancellationToken token)
    {
      if (!File.Exists(executable)) return CheckResult.Failure(2, "HermesMissing", "Hermes is unavailable. Install Hermes Agent or use -HermesPath to select its executable, then restart HermesTray.");
      var result = Probe(executable, "--version", directory, timeout, token, true);
      return result.Code != 0 ? result : Probe(executable, "serve --help", directory, timeout, token, false);
    }
  }

  public static class IconLoader
  {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr CreateIconFromResourceEx(byte[] bytes, uint length, bool icon, uint version, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    public static Icon Load(byte[] bytes, Size size)
    {
      if (bytes.Length < 6 || BitConverter.ToUInt16(bytes, 0) != 0 || BitConverter.ToUInt16(bytes, 2) != 1) throw new InvalidDataException("Invalid icon.ico");
      int count = BitConverter.ToUInt16(bytes, 4), best = 6, distance = int.MaxValue;
      if (count == 0 || bytes.Length < 6 + 16 * count) throw new InvalidDataException("Invalid icon directory");
      for (int i = 0; i < count; i++)
      {
        int entry = 6 + 16 * i, width = bytes[entry] == 0 ? 256 : bytes[entry], height = bytes[entry + 1] == 0 ? 256 : bytes[entry + 1];
        int current = Math.Abs(width - size.Width) + Math.Abs(height - size.Height);
        if (current < distance) { best = entry; distance = current; }
      }
      uint length = BitConverter.ToUInt32(bytes, best + 8), offset = BitConverter.ToUInt32(bytes, best + 12);
      if (length == 0 || (long)offset + length > bytes.Length) throw new InvalidDataException("Invalid icon frame");
      var frame = new byte[length]; Array.Copy(bytes, offset, frame, 0, length);
      IntPtr handle = CreateIconFromResourceEx(frame, length, true, 0x30000, size.Width, size.Height, 0);
      if (handle == IntPtr.Zero) throw new Win32Exception();
      try { using (var borrowed = Icon.FromHandle(handle)) return (Icon)borrowed.Clone(); }
      finally { DestroyIcon(handle); }
    }
  }

  public sealed class TrayApplication : ApplicationContext
  {
    public NotifyIcon Tray { get; private set; }
    public ContextMenuStrip Menu { get; private set; }
    public string State { get; private set; }
    public string LastError { get; private set; }
    public string Arguments { get; private set; }
    public int ResultCode { get; private set; }
    public string FailureCode { get; private set; }
    public bool IsClosed { get; private set; }
    public bool NotifyFailures { get; set; }
    public int FailureNoticeMilliseconds { get; set; }
    public int CliTimeoutMilliseconds { get; set; }
    public int StartupTimeoutMilliseconds { get; set; }
    public int HttpTimeoutMilliseconds { get; set; }
    public int UnavailableTimeoutMilliseconds { get; set; }
    public bool AuthenticationVerified { get; private set; }
    public int ServerProcessId { get { return server == null ? 0 : server.ProcessId; } }
    public uint ActiveProcessCount { get { return server == null ? 0 : server.ActiveProcessCount; } }
    readonly string executable, logs, bindAddress, probeAddress;
    readonly int port;
    readonly Icon icon;
    readonly System.Windows.Forms.Timer timer;
    OwnedProcess server;
    bool started, stopped;
    DateTime failureDeadline;
    readonly CancellationTokenSource cancellation = new CancellationTokenSource();
    Task<CheckResult> preflight;
    Task<CheckResult> statusProbe;
    readonly Stopwatch startupClock = new Stopwatch();
    readonly Stopwatch healthClock = new Stopwatch();
    readonly Stopwatch unavailableClock = new Stopwatch();
    long serverLogOffset;
    public TrayApplication(Icon icon, string executable, string arguments, int port, string logDirectory, string bindAddress = "0.0.0.0")
    {
      this.icon = icon; this.executable = executable; Arguments = arguments; this.port = port; logs = logDirectory;
      this.bindAddress = bindAddress; probeAddress = bindAddress == "0.0.0.0" ? "127.0.0.1" : bindAddress;
      Directory.CreateDirectory(logs);
      State = "Stopped";
      NotifyFailures = true; FailureNoticeMilliseconds = 5000; CliTimeoutMilliseconds = 10000;
      StartupTimeoutMilliseconds = 60000; HttpTimeoutMilliseconds = 5000; UnavailableTimeoutMilliseconds = 30000;
      Menu = new ContextMenuStrip();
      var exit = new ToolStripMenuItem("Exit");
      exit.Name = "Exit"; exit.Click += delegate { Exit(); };
      Menu.Items.Add(exit);
      Tray = new NotifyIcon { Icon = icon, Text = "HermesTray - starting", ContextMenuStrip = Menu, Visible = true };
      timer = new System.Windows.Forms.Timer { Interval = 500 };
      timer.Tick += delegate { Poll(); };
    }
    public static bool IsPortListening(int port)
    {
      foreach (var endpoint in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()) if (endpoint.Port == port) return true;
      return false;
    }
    void Log(string text)
    {
      try
      {
        string path = Path.Combine(logs, "tray.log");
        if (File.Exists(path) && new FileInfo(path).Length > 1048576) { string old = path + ".1"; if (File.Exists(old)) File.Delete(old); File.Move(path, old); }
        File.AppendAllText(path, DateTime.Now.ToString("s") + " " + text + Environment.NewLine);
      }
      catch { /* Logging must not prevent owned-process cleanup. */ }
    }
    void Fail(string message) { Fatal(5, "ServerFailed", message); }
    void Fatal(int code, string reason, string message)
    {
      if (stopped || ResultCode != 0) return;
      ResultCode = code; FailureCode = reason; LastError = message; State = "Error";
      AuthenticationVerified = false; cancellation.Cancel();
      if (server != null) server.Dispose();
      Tray.Text = "HermesTray - error; check logs";
      Log(reason + ": " + message);
      if (NotifyFailures)
      {
        try { Tray.ShowBalloonTip(5000, "HermesTray error", message, ToolTipIcon.Error); }
        catch { /* Notifications may be unavailable; the log remains authoritative. */ }
      }
      failureDeadline = DateTime.UtcNow.AddMilliseconds(Math.Max(0, FailureNoticeMilliseconds));
      timer.Start();
    }
    public void Start()
    {
      if (started || stopped) return;
      started = true;
      try
      {
        if (!File.Exists(executable)) { Fatal(2, "HermesMissing", "Hermes is unavailable. Install Hermes Agent or use -HermesPath to select its executable, then restart HermesTray."); return; }
        if (IsPortListening(port)) { State = "External"; Tray.Text = "HermesTray - port already in use"; Log("Port " + port + " already in use. No process started or adopted."); return; }
        State = "Checking"; Tray.Text = "HermesTray - checking prerequisites";
        preflight = Task.Factory.StartNew(() => StartupChecks.CheckCli(executable, logs, Math.Max(1, CliTimeoutMilliseconds), cancellation.Token));
        timer.Start();
      }
      catch (Exception error) { Fail(error.Message); }
    }
    void Poll()
    {
      if (stopped) return;
      if (ResultCode != 0) { if (DateTime.UtcNow >= failureDeadline) Exit(); return; }
      if (State == "Checking")
      {
        if (!preflight.IsCompleted) return;
        if (preflight.IsFaulted || preflight.IsCanceled) { Fatal(3, "HermesUnusable", "Hermes CLI validation could not complete. Restart HermesTray or check Hermes in a terminal."); return; }
        var check = preflight.Result;
        if (check.Code != 0) { Fatal(check.Code, check.Reason, check.Message); return; }
        if (IsPortListening(port)) { timer.Stop(); State = "External"; Tray.Text = "HermesTray - port already in use"; Log("Port became occupied during validation. No server started."); return; }
        try
        {
          Log("Hermes CLI validated. Starting: \"" + executable + "\" " + Arguments);
          string serverLog = Path.Combine(logs, "server.log");
          serverLogOffset = 0; // OutputCapture rotates the previous launch before starting.
          server = new OwnedProcess(executable, Arguments, serverLog);
          State = "Starting"; Tray.Text = "HermesTray - starting";
          startupClock.Restart();
        }
        catch { Fatal(5, "ServerFailed", "Hermes could not start. Check the installation and server.log, then restart HermesTray."); }
        return;
      }
      if (server == null) return;
      try
      {
        if (server.OutputFailed) { Fatal(5, "LogWriteFailed", "Server output could not be recorded. Check log directory permissions and free disk space, then restart HermesTray."); return; }
        if (server.ActiveProcessCount == 0)
        {
          if (State == "Starting" && StartupChecks.AuthenticationWasRefused(Path.Combine(logs, "server.log"), serverLogOffset)) Fatal(4, "AuthenticationRequired", StartupChecks.AuthenticationMessage);
          else Fail("Hermes exited. Code=" + server.ExitCode + ". Run the command in a terminal or check server.log, then restart HermesTray.");
          return;
        }
        if (State == "Starting" || State == "Running" || State == "Degraded")
        {
          if (State == "Starting" && startupClock.ElapsedMilliseconds >= Math.Max(1, StartupTimeoutMilliseconds)) { Fatal(6, "StartupTimeout", "Hermes did not become ready in time. Check server.log and run hermes serve --host 0.0.0.0 in a terminal before restarting HermesTray."); return; }
          if (State == "Degraded" && unavailableClock.ElapsedMilliseconds >= Math.Max(1, UnavailableTimeoutMilliseconds)) { Fatal(5, "ServerUnavailable", "Hermes stopped responding. Check server.log and restart HermesTray."); return; }
          if (!IsPortListening(port)) { if (State != "Starting") { if (State != "Degraded") Log("Health check failed: NoListener."); Degrade(); } return; }
          if (!server.OwnsListener(port, bindAddress)) { Fatal(7, "UnownedListener", "The port is not owned by this HermesTray process tree. The external listener was left untouched."); return; }
          if (State == "Running" && statusProbe == null && healthClock.ElapsedMilliseconds < 5000) return;
          if (statusProbe == null) { statusProbe = Task.Factory.StartNew(() => StartupChecks.CheckStatus(port, Math.Max(1, HttpTimeoutMilliseconds), cancellation.Token, probeAddress)); return; }
          if (!statusProbe.IsCompleted) return;
          if (statusProbe.IsFaulted || statusProbe.IsCanceled) { Fatal(7, "InvalidBackendStatus", "The backend status could not be validated. Check Hermes and restart HermesTray."); return; }
          var result = statusProbe.Result; statusProbe = null;
          if (result.Retry) { Log("Health check failed: " + result.Reason + "."); if (State != "Starting") Degrade(); return; }
          if (result.Code != 0) { Fatal(result.Code, result.Reason, result.Message); return; }
          if (!server.OwnsListener(port, bindAddress)) { Fatal(7, "UnownedListener", "The listener changed during validation. The external listener was left untouched."); return; }
          bool becameReady = State != "Running";
          AuthenticationVerified = true; State = "Running"; Tray.Text = "HermesTray - server running";
          healthClock.Restart(); unavailableClock.Reset();
          if (becameReady) Log("Authenticated HTTP readiness verified on port " + port + "; owned root PID " + server.ProcessId + ".");
        }
      }
      catch (Exception error) { timer.Stop(); Fail(error.Message); }
    }
    void Degrade()
    {
      AuthenticationVerified = false; State = "Degraded";
      Tray.Text = "HermesTray - checking server";
      if (!unavailableClock.IsRunning) unavailableClock.Start();
    }
    public void Exit() { Stop(); ExitThread(); }
    void Stop()
    {
      if (stopped) return;
      stopped = true; IsClosed = true; AuthenticationVerified = false; timer.Stop(); cancellation.Cancel();
      if (server != null) { server.Dispose(); Log("Owned server process tree stopped."); }
      Tray.Visible = false; Tray.Dispose(); Menu.Dispose(); timer.Dispose(); icon.Dispose(); State = "Stopped";
    }
    protected override void ExitThreadCore() { Stop(); base.ExitThreadCore(); }
    protected override void Dispose(bool disposing) { if (disposing) Stop(); base.Dispose(disposing); }
  }
}
