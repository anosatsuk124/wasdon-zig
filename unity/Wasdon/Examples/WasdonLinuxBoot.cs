using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using VRC.SDK3.UdonNetworkCalling;
using VRC.SDKBase;
using VRC.Udon;
using VRC.Udon.Common.Interfaces;

namespace Wasdon
{
    [UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
    public class WasdonLinuxBoot : UdonSharpBehaviour
    {
        public UdonBehaviour kernel;
        public Text console;
        public Text status;

        private const int VisibleLines = 22;
        private const float BootRetryInterval = 0.25f;
        private const double BootFrameBudget = 0.010;
        private const int MaxStepsPerFrame = 16;
        private const double ProgressInterval = 0.25;
        private bool bootRequested;
        private bool running;
        private float nextBootAttempt;
        private int bootSteps;
        private double bootStartedAt;
        private double nextProgressUpdate;
        private string pendingBroadcast;
        private string lastConsole;

        public void ClickStart()
        {
            if (NetworkCalling.InNetworkCall || bootRequested || running) return;
            RequestBoot();
            pendingBroadcast = nameof(BootStart);
            BroadcastPendingCommand();
        }

        public void ClickReload()
        {
            if (NetworkCalling.InNetworkCall) return;
            RequestBoot();
            pendingBroadcast = nameof(BootReload);
            BroadcastPendingCommand();
        }

        [NetworkCallable]
        public void BootStart()
        {
            if (!bootRequested && !running) RequestBoot();
        }

        [NetworkCallable]
        public void BootReload()
        {
            RequestBoot();
        }

        private void BroadcastPendingCommand()
        {
            if (string.IsNullOrEmpty(pendingBroadcast) || !Utilities.IsValid(Networking.LocalPlayer) || !Networking.IsObjectReady(gameObject))
                return;

            string command = pendingBroadcast;
            pendingBroadcast = null;
            SendCustomNetworkEvent(NetworkEventTarget.Others, command);
        }

        private void RequestBoot()
        {
            bootRequested = true;
            running = false;
            lastConsole = "";
            console.text = "";
            status.text = "WAITING  /  Kernel initialization";
            TryBeginBoot();
        }

        private void TryBeginBoot()
        {
            if (!KernelAvailable()) return;
            nextBootAttempt = Time.unscaledTime + BootRetryInterval;
            if (!kernel.gameObject.activeInHierarchy) return;

            // A previous run may still have its flag set when Reload is
            // pressed. The new Boot event must set it again to acknowledge.
            kernel.SetProgramVariable("bootRunning", false);
            kernel.SendCustomEvent("Boot");
            if (!KernelAvailable()) return;
            object state = kernel.GetProgramVariable("bootRunning");
            if (state == null || !(bool)state) return;

            bootRequested = false;
            running = true;
            bootSteps = 0;
            bootStartedAt = Time.realtimeSinceStartupAsDouble;
            nextProgressUpdate = bootStartedAt;
            status.text = "BOOTING  /  0 steps";
        }

        private bool KernelAvailable()
        {
            if (Utilities.IsValid(kernel) && kernel.enabled) return true;
            bootRequested = false;
            running = false;
            status.text = Utilities.IsValid(kernel) ? "STOPPED  /  Kernel disabled" : "KERNEL ASSET REQUIRED";
            return false;
        }

        private void Update()
        {
            BroadcastPendingCommand();
            if (bootRequested)
            {
                if (Time.unscaledTime >= nextBootAttempt) TryBeginBoot();
                return;
            }

            if (!running) return;
            if (!KernelAvailable()) return;
            // The guest can spend thousands of steps before its console
            // comes online. Fit multiple bounded events into each frame.
            double deadline = Time.realtimeSinceStartupAsDouble + BootFrameBudget;
            for (int i = 0; i < MaxStepsPerFrame; i++)
            {
                kernel.SendCustomEvent("BootStep");
                if (!kernel.enabled)
                {
                    running = false;
                    status.text = "STOPPED  /  Udon execution error";
                    return;
                }
                bootSteps++;
                if (Time.realtimeSinceStartupAsDouble >= deadline) break;
            }

            object consoleValue = kernel.GetProgramVariable("bootConsole");
            object state = kernel.GetProgramVariable("bootRunning");
            if (consoleValue == null || state == null)
            {
                running = false;
                status.text = "STOPPED  /  Kernel program unavailable";
                return;
            }

            string output = (string)consoleValue;
            if (output != lastConsole)
            {
                lastConsole = output;
                int first = output.Length;
                int lines = 0;
                while (first > 0)
                {
                    first--;
                    if (output[first] == '\n')
                    {
                        lines++;
                        if (lines > VisibleLines)
                        {
                            first++;
                            break;
                        }
                    }
                }
                console.text = output.Substring(first).TrimEnd();
            }

            running = (bool)state;
            if (!running)
            {
                status.text = output.Contains("env.wasm_create_and_run_task")
                    ? "STOPPED  /  First task switch"
                    : "STOPPED  /  Kernel event ended";
                return;
            }

            double now = Time.realtimeSinceStartupAsDouble;
            if (now >= nextProgressUpdate)
            {
                nextProgressUpdate = now + ProgressInterval;
                status.text = "BOOTING  /  " + bootSteps + " steps  /  " + (int)(now - bootStartedAt) + " s";
            }
        }
    }
}
