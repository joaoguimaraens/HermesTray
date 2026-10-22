using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.IO;
using System.Text;

// Deterministic subprocess fixture. It is NOT a Hermes server.
public static class FakeHermes {
  public static int Main(string[] args) {
    string mode=Environment.GetEnvironmentVariable("HERMESTRAY_FIXTURE_MODE") ?? "";
    if (Array.IndexOf(args,"--version")>=0) {
      if(mode=="hang-version") Thread.Sleep(Timeout.Infinite);
      if(mode=="version-fail") { Console.WriteLine("DO_NOT_LOG_SENSITIVE_MARKER"); return 12; }
      if(mode=="wrong-version") { Console.WriteLine("Different application v1.0.0"); return 0; }
      Console.WriteLine("Hermes Agent v0.0.0 (test fixture)"); return 0;
    }
    if (Array.IndexOf(args,"--help")>=0) {
      if(mode=="help-fail") { Console.WriteLine("DO_NOT_LOG_SENSITIVE_MARKER"); return 12; }
      if(mode=="unsupported-serve") { Console.WriteLine("usage: hermes chat"); return 0; }
      Console.WriteLine("usage: hermes serve --host HOST --port PORT (test fixture)"); return 0;
    }
    if (Array.IndexOf(args,"--flood")>=0) { for(int i=0;i<6000;i++) Console.WriteLine(new string('X',512)); return 0; }
    int port = 9119;
    for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--port") port = int.Parse(args[i + 1]);
    if (Array.IndexOf(args, "--child") >= 0) {
      var listener = new TcpListener(IPAddress.Loopback, port);
      listener.Start();
      for (;;) {
        using (var client = listener.AcceptTcpClient()) {
          if (mode=="tcp-only") continue;
          client.ReceiveTimeout=2000;
          try {
            var stream=client.GetStream();
            var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);
            string request=reader.ReadLine();
            if(request!=null && request.StartsWith("GET /api/status ")) Console.WriteLine("FIXTURE_STATUS_REQUEST");
            string header; while (!string.IsNullOrEmpty(header=reader.ReadLine())) { }
            string control=Environment.GetEnvironmentVariable("HERMESTRAY_FIXTURE_CONTROL");
            if (!string.IsNullOrEmpty(control) && File.Exists(control)) mode=File.ReadAllText(control).Trim();
            string body="{\"version\":\"0.0.0-test-fixture\",\"auth_required\":true,\"auth_providers\":[\"basic\"]}";
            if(mode=="oauth") body="{\"version\":\"0.0.0-test-fixture\",\"auth_required\":true,\"auth_providers\":[\"nous\"]}";
            if(mode=="unauth") body="{\"version\":\"0.0.0-test-fixture\",\"auth_required\":false,\"auth_providers\":[\"basic\"]}";
            if(mode=="no-provider") body="{\"version\":\"0.0.0-test-fixture\",\"auth_required\":true,\"auth_providers\":[]}";
            if(mode=="bad-json") body="DO_NOT_LOG_SENSITIVE_MARKER";
            if(mode=="bad-types") body="{\"version\":\"0.0.0-test-fixture\",\"auth_required\":\"true\",\"auth_providers\":[\"basic\"]}";
            string status=mode=="http-error" ? "503 Unavailable" : "200 OK";
            if(request==null || !request.StartsWith("GET /api/status ")) status="404 Not Found";
            if(mode=="redirect") status="302 Found";
            var bytes=Encoding.UTF8.GetBytes(body);
            string response="HTTP/1.1 "+status+"\r\nContent-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\nConnection: close\r\n";
            if(mode=="redirect") response+="Location: http://127.0.0.1:"+port+"/private\r\n";
            var head=Encoding.ASCII.GetBytes(response+"\r\n");
            stream.Write(head,0,head.Length);
            if(mode=="slow-body") { foreach(byte b in bytes) { stream.WriteByte(b); stream.Flush(); Thread.Sleep(50); } }
            else stream.Write(bytes,0,bytes.Length);
            stream.Flush();
          } catch (IOException) { }
        }
      }
    }
    if (args.Length < 3 || args[0] != "serve" || args[1] != "--host" || (args[2] != "0.0.0.0" && args[2] != "127.0.0.1")) return 42;
    if(mode=="auth-refused") { Console.Error.WriteLine("Refusing to bind dashboard: no auth providers are registered. Configure an auth provider before exposing the dashboard."); return 78; }
    if(mode=="early-exit") return 9;
    if(mode=="no-listener") Thread.Sleep(Timeout.Infinite);
    Console.WriteLine("Fixture arguments: " + string.Join(" ", args));
    var child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--child --port " + port) { UseShellExecute = false, CreateNoWindow = true });
    Console.WriteLine("CHILD_PID=" + child.Id);
    child.WaitForExit();
    if(mode=="linger-wrapper") Thread.Sleep(Timeout.Infinite);
    return child.ExitCode;
  }
}
