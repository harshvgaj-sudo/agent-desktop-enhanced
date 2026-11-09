# agent-desk.ps1 - Production Windows Interactive Desktop Station Bridge
# Ensures commands route to WinSta0\default to bypass isolated subshell sandbox desktop limitations.

$rawArgs = @($args)

# Argument pre-processor: automatically wrap bare @refs in single quotes if unquoted
$processedArgs = @()
foreach ($arg in $rawArgs) {
    if ($arg -match '^@[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$' -and -not ($arg.StartsWith("'") -or $arg.StartsWith('"'))) {
        $processedArgs += "'$arg'"
    } else {
        $processedArgs += $arg
    }
}
$argsString = ($processedArgs -join " ")

Add-Type @"
using System;
using System.IO;
using System.Runtime.InteropServices;

public class AgentDeskBridge {
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
    public static extern UInt32 WaitForSingleObject(IntPtr hHandle, UInt32 dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, [Out] byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    public static string Execute(string cmdArgs) {
        SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(sa);
        sa.bInheritHandle = true;
        sa.lpSecurityDescriptor = IntPtr.Zero;

        IntPtr hRead, hWrite;
        CreatePipe(out hRead, out hWrite, ref sa, 0);

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.lpDesktop = @"WinSta0\default";
        si.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
        si.hStdOutput = hWrite;
        si.hStdError = hWrite;

        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        string fullCmd = "\"C:\\Users\\harsh\\AppData\\Roaming\\npm\\node_modules\\agent-desktop\\bin\\agent-desktop-win32-x64.exe\" " + cmdArgs;
        
        bool success = CreateProcess(null, fullCmd, ref sa, ref sa, true, 0, IntPtr.Zero, null, ref si, out pi);
        CloseHandle(hWrite);

        if (!success) {
            CloseHandle(hRead);
            return "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"CreateProcess failed: " + Marshal.GetLastWin32Error() + "\"}}";
        }

        WaitForSingleObject(pi.hProcess, 30000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);

        byte[] buf = new byte[65536];
        uint bytesRead;
        using (MemoryStream ms = new MemoryStream()) {
            while (ReadFile(hRead, buf, (uint)buf.Length, out bytesRead, IntPtr.Zero) && bytesRead > 0) {
                ms.Write(buf, 0, (int)bytesRead);
            }
            CloseHandle(hRead);
            return System.Text.Encoding.UTF8.GetString(ms.ToArray());
        }
    }
}
"@ -ErrorAction SilentlyContinue

[AgentDeskBridge]::Execute($argsString)
