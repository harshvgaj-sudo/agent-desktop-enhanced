# agent-desk.ps1 - Production Windows Interactive Desktop Station Bridge
# Ensures commands route to WinSta0\default to bypass isolated subshell sandbox desktop limitations.

$rawArgs = @($args)

# Ref Normalization:
# Strip accidental outer quotes (single/double) from refs (@<snapshot_id>:e<N>) so the binary
# receives strictly @<snapshot_id>:e<N>. Do not inject literal single quotes.
function Normalize-Arg([string]$arg) {
    if ([string]::IsNullOrEmpty($arg)) { return $arg }
    $trimmed = $arg.Trim(@([char]39, [char]34, [char]96))
    if ($trimmed -match '^@[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$') {
        return $trimmed
    }
    return $arg
}

$processedArgs = @()
foreach ($arg in $rawArgs) {
    $processedArgs += (Normalize-Arg $arg)
}

function Resolve-AgentDesktopBinary {
    if ($env:AGENT_DESKTOP_EXE -and (Test-Path $env:AGENT_DESKTOP_EXE)) {
        return (Resolve-Path $env:AGENT_DESKTOP_EXE).Path
    }
    $candidates = @(
        (Join-Path $PSScriptRoot "..\node_modules\agent-desktop\bin\agent-desktop-win32-x64.exe"),
        (Join-Path $PSScriptRoot "node_modules\agent-desktop\bin\agent-desktop-win32-x64.exe"),
        (Join-Path $env:APPDATA "npm\node_modules\agent-desktop\bin\agent-desktop-win32-x64.exe")
    )
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand)) {
            return (Resolve-Path $cand).Path
        }
    }
    $cmd = Get-Command "agent-desktop-win32-x64.exe" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        return $cmd.Source
    }
    return "C:\Users\harsh\AppData\Roaming\npm\node_modules\agent-desktop\bin\agent-desktop-win32-x64.exe"
}

$exePath = Resolve-AgentDesktopBinary
if (-not (Test-Path $exePath)) {
    Write-Error "agent-desktop binary not found at: $exePath"
    $global:LASTEXITCODE = 1
    exit 1
}

$TypeDefinition = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class AgentDeskNativeBridge {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public Int32 cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public Int32 dwX;
        public Int32 dwY;
        public Int32 dwXSize;
        public Int32 dwYSize;
        public Int32 dwXCountChars;
        public Int32 dwYCountChars;
        public Int32 dwFillAttribute;
        public Int32 dwFlags;
        public Int16 wShowWindow;
        public Int16 cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public Int32 dwProcessId;
        public Int32 dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(
        string lpApplicationName,
        string lpCommandLine,
        ref SECURITY_ATTRIBUTES lpProcessAttributes,
        ref SECURITY_ATTRIBUTES lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UInt32 WaitForSingleObject(IntPtr hHandle, UInt32 dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, [Out] byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    public static string EscapeArgument(string arg) {
        if (string.IsNullOrEmpty(arg)) {
            return "\"\"";
        }
        bool needsQuotes = false;
        for (int i = 0; i < arg.Length; i++) {
            char c = arg[i];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '"') {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes) {
            return arg;
        }

        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        for (int i = 0; i < arg.Length; i++) {
            char c = arg[i];
            if (c == '\\') {
                backslashes++;
            } else if (c == '"') {
                sb.Append(new string('\\', backslashes * 2 + 1));
                sb.Append('"');
                backslashes = 0;
            } else {
                if (backslashes > 0) {
                    sb.Append(new string('\\', backslashes));
                    backslashes = 0;
                }
                sb.Append(c);
            }
        }
        if (backslashes > 0) {
            sb.Append(new string('\\', backslashes * 2));
        }
        sb.Append('"');
        return sb.ToString();
    }

    public static string BuildCommandLine(string exePath, string[] args) {
        StringBuilder sb = new StringBuilder();
        sb.Append(EscapeArgument(exePath));
        if (args != null) {
            for (int i = 0; i < args.Length; i++) {
                sb.Append(' ');
                sb.Append(EscapeArgument(args[i]));
            }
        }
        return sb.ToString();
    }

    public static int Execute(string exePath, string[] args, out string output) {
        output = "";
        string fullCmd = BuildCommandLine(exePath, args);

        SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(sa);
        sa.bInheritHandle = true;
        sa.lpSecurityDescriptor = IntPtr.Zero;

        IntPtr hRead, hWrite;
        if (!CreatePipe(out hRead, out hWrite, ref sa, 0)) {
            int err = Marshal.GetLastWin32Error();
            output = "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"CreatePipe failed: " + err + "\"}}";
            return 1;
        }

        // Do not let the child process inherit the read end
        SetHandleInformation(hRead, 1 /* HANDLE_FLAG_INHERIT */, 0);

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.lpDesktop = @"WinSta0\default";
        si.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
        si.hStdOutput = hWrite;
        si.hStdError = hWrite;
        si.hStdInput = IntPtr.Zero;

        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        bool success = CreateProcess(null, fullCmd, ref sa, ref sa, true, 0, IntPtr.Zero, null, ref si, out pi);

        // Parent must close write handle immediately so ReadFile sees EOF when child exits
        CloseHandle(hWrite);

        if (!success) {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(hRead);
            output = "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"CreateProcess failed: " + err + "\"}}";
            return 1;
        }

        byte[] outputBytes = null;
        Exception readEx = null;

        Thread readerThread = new Thread(() => {
            try {
                byte[] buf = new byte[65536];
                uint bytesRead;
                using (MemoryStream ms = new MemoryStream()) {
                    while (ReadFile(hRead, buf, (uint)buf.Length, out bytesRead, IntPtr.Zero) && bytesRead > 0) {
                        ms.Write(buf, 0, (int)bytesRead);
                    }
                    outputBytes = ms.ToArray();
                }
            } catch (Exception ex) {
                readEx = ex;
            } finally {
                CloseHandle(hRead);
            }
        });
        readerThread.IsBackground = true;
        readerThread.Start();

        // Wait up to 60 seconds for child process to finish
        uint waitRes = WaitForSingleObject(pi.hProcess, 60000);
        if (waitRes == 0x00000102 /* WAIT_TIMEOUT */) {
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            readerThread.Join(2000);
            output = "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"Execution timed out after 60s\"}}";
            return 1;
        }

        // Wait for reader thread to complete reading buffered bytes
        readerThread.Join(5000);

        uint exitCode = 0;
        GetExitCodeProcess(pi.hProcess, out exitCode);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);

        if (outputBytes != null && outputBytes.Length > 0) {
            output = Encoding.UTF8.GetString(outputBytes);
        } else if (readEx != null) {
            output = "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"Pipe read error: " + readEx.Message + "\"}}";
        }

        return (int)exitCode;
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'AgentDeskNativeBridge').Type) {
    Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
}

$cliOutput = ""
$exitCode = [AgentDeskNativeBridge]::Execute($exePath, $processedArgs, [ref]$cliOutput)
if ($cliOutput) {
    Write-Output $cliOutput
}
$global:LASTEXITCODE = $exitCode
exit $exitCode
