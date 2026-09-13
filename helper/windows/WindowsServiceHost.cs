using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DomainManager.Helper;

internal static class WindowsServiceHost
{
    private const int ServiceWin32OwnProcess = 0x00000010;
    private const int ServiceStartPending = 0x00000002;
    private const int ServiceStopPending = 0x00000003;
    private const int ServiceRunning = 0x00000004;
    private const int ServiceStopped = 0x00000001;
    private const int ServiceAcceptStop = 0x00000001;
    private const int ServiceControlStop = 0x00000001;

    private static readonly ManualResetEventSlim StopSignal = new(false);
    private static readonly CancellationTokenSource Cancellation = new();
    private static ServiceMainDelegate? serviceMain;
    private static ServiceControlHandler? controlHandler;
    private static Func<CancellationToken, Task<int>>? worker;
    private static IntPtr statusHandle;
    private static int serviceExitCode;

    public static int Run(string serviceName, Func<CancellationToken, Task<int>> serviceWorker)
    {
        worker = serviceWorker;
        serviceMain = ServiceMain;
        var table = new[]
        {
            new ServiceTableEntry { ServiceName = serviceName, ServiceMain = serviceMain },
            new ServiceTableEntry(),
        };

        if (!StartServiceCtrlDispatcher(table))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Nie można połączyć helpera z Menedżerem sterowania usługami Windows.");

        return serviceExitCode;
    }

    private static void ServiceMain(int argumentCount, IntPtr arguments)
    {
        controlHandler = ControlHandler;
        statusHandle = RegisterServiceCtrlHandlerEx("DomainManagerHelper", controlHandler, IntPtr.Zero);
        if (statusHandle == IntPtr.Zero)
        {
            serviceExitCode = Marshal.GetLastWin32Error();
            return;
        }

        SetStatus(ServiceStartPending, 0, 10_000);
        Task<int> task = Task.Run(() => worker!(Cancellation.Token));
        _ = task.ContinueWith(_ => StopSignal.Set(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        SetStatus(ServiceRunning, ServiceAcceptStop, 0);
        StopSignal.Wait();
        SetStatus(ServiceStopPending, 0, 10_000);
        Cancellation.Cancel();

        try
        {
            serviceExitCode = task.GetAwaiter().GetResult();
        }
        catch
        {
            serviceExitCode = 1;
        }

        SetStatus(ServiceStopped, 0, 0, serviceExitCode);
    }

    private static int ControlHandler(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        if (control == ServiceControlStop)
            StopSignal.Set();
        return 0;
    }

    private static void SetStatus(int currentState, int acceptedControls, int waitHint, int win32ExitCode = 0)
    {
        var status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = currentState,
            ControlsAccepted = acceptedControls,
            Win32ExitCode = win32ExitCode,
            WaitHint = waitHint,
        };
        SetServiceStatus(statusHandle, ref status);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string? ServiceName;
        public ServiceMainDelegate? ServiceMain;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainDelegate(int argumentCount, IntPtr arguments);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int ServiceControlHandler(int control, int eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher([In] ServiceTableEntry[] serviceTable);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string serviceName, ServiceControlHandler handler, IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr serviceStatusHandle, ref ServiceStatus serviceStatus);
}
