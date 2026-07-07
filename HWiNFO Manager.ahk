#Requires AutoHotkey v2.0
#SingleInstance Force

; =====================================================================
;  HWiNFO Manager  (Profile Manager + Auto-Restart watchdog, combined)
;  ---------------------------------------------------------------
;  Sits in the systray. Left-click the tray icon to open the Profile
;  Manager GUI; closing that GUI (X button) just hides it - the
;  script (and its watchdog) keeps running in the background. Use
;  the tray icon's right-click menu -> Exit to actually quit.
;
;  Files created next to this script:
;    HWiNFOProfiles.ini   -> stores exe path, registry base, profile list
;    Profiles\<name>.reg  -> one exported registry file per profile
; =====================================================================

; ---------------------------------------------------------------------
; Auto-elevate: relaunch this script as Administrator if it isn't already.
; Doing this ONCE here means everything the script later runs (reg
; export/import, and launching/killing HWiNFO itself) inherits the
; elevated token - so you get a single UAC prompt on startup instead of
; a prompt every time you switch profiles / launch HWiNFO.
; ---------------------------------------------------------------------
if !A_IsAdmin {
    try {
        if A_IsCompiled
            Run('*RunAs "' A_ScriptFullPath '"')
        else
            Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    }
    ExitApp()
}

; ---------------------------- Config -----------------------------------

; Name of the Task Scheduler task used for the "run at Windows startup"
; option (see the run-at-startup functions further down).
RunAtStartupTaskName := "HWiNFO Manager Startup"

configFile  := A_ScriptDir "\HWiNFOProfiles.ini"
profilesDir := A_ScriptDir "\Profiles"
if !DirExist(profilesDir)
    DirCreate(profilesDir)

; If true, the Profile Manager GUI stays hidden (in the tray) when the
; script launches, instead of opening automatically. Persisted so it takes
; effect whether the script was started manually or via the startup task.
hideGuiOnStart := IniRead(configFile, "Settings", "HideGuiOnStart", "0") = "1"

hwinfoPath := IniRead(configFile, "Settings", "HWiNFOPath", "")
regBase    := IniRead(configFile, "Settings", "RegBase", "HWiNFO64")
; Resolve now (functions are hoisted in AHK v2, so this call is valid here)
hwinfoPath := ToAbsolutePath(hwinfoPath)

; If nothing configured yet, fall back to the default install location
; (this mirrors the old standalone Auto-Restart script's hardcoded path)
; so the watchdog has something sensible to work with out of the box.
if hwinfoPath = "" {
    defaultPath := "C:\Program Files\HWiNFO64\HWiNFO64.EXE"
    if FileExist(defaultPath)
        hwinfoPath := defaultPath
}

; Process name the watchdog watches/kills - kept in sync with hwinfoPath
; whenever it changes (BrowseExe, LoadProfile, etc.)
exeName := hwinfoPath != "" ? GetExeName(hwinfoPath) : "HWiNFO64.EXE"

; ---------------------------- Auto-restart settings ---------------------
; The periodic "kill and relaunch HWiNFO" cycle below. Configurable from
; the GUI (Auto Restart checkbox + hours/minutes fields), persisted to
; the ini. Defaults preserve the original hardcoded behavior (always on,
; every 11h58m) so existing installs keep working unchanged.

autoRestartEnabled   := IniRead(configFile, "Settings", "AutoRestartEnabled", "1") = "1"
autoRestartHours     := Integer(IniRead(configFile, "Settings", "AutoRestartHours", "11"))
autoRestartMinutes   := Integer(IniRead(configFile, "Settings", "AutoRestartMinutes", "58"))
autoRestartIntervalMs := GetMillisecondsForHours(autoRestartHours) + GetMillisecondsForMins(autoRestartMinutes)

; ---------------------------- Tray icon ---------------------------------
; Configurable from the GUI (Tray Icon section) - persisted in the ini so
; it's remembered across restarts. If nothing is configured, AHK's default
; tray icon is used.

trayIconFile  := IniRead(configFile, "Settings", "TrayIconFile", "")
trayIconFile  := trayIconFile != "" ? ToAbsolutePath(trayIconFile) : ""
trayIconIndex := IniRead(configFile, "Settings", "TrayIconIndex", "1")

; ---------------------------- Running-check settings ---------------------
; A separate, independently-timed check (distinct from the ~12h forced
; restart loop below) that periodically confirms HWiNFO is actually
; running and can optionally auto-start it (or prompt) if it's not.

runCheckEnabled      := IniRead(configFile, "Settings", "RunCheckEnabled", "0") = "1"
runCheckIntervalMin  := Integer(IniRead(configFile, "Settings", "RunCheckIntervalMin", "5"))
runCheckAutoStart    := IniRead(configFile, "Settings", "RunCheckAutoStart", "0") = "1"
runCheckPrompt       := IniRead(configFile, "Settings", "RunCheckPrompt", "1") = "1"

A_IconTip := "HWiNFO Manager"
if trayIconFile != "" {
    resolvedTrayIcon := ResolveIconFile(trayIconFile)
    if FileExist(resolvedTrayIcon) {
        try TraySetIcon(resolvedTrayIcon, Integer(trayIconIndex))
    }
}

A_TrayMenu.Delete()
A_TrayMenu.Add("Open Profile Manager", (*) => ShowMainGui())
A_TrayMenu.Add()  ; separator
A_TrayMenu.Add("Restart HWiNFO Now", (*) => RestartHWiNFONow())
A_TrayMenu.Add()  ; separator
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Open Profile Manager"
A_TrayMenu.ClickCount := 1  ; single left-click triggers the default item (normally double-click)

; ---------------------------- GUI (built once, hidden) -------------------

MainGui := Gui("+Resize +MinimizeBox", "HWiNFO Manager")
MainGui.SetFont("s10")

; Hide from the taskbar/Alt-Tab entirely - this is a tray-only app. The
; window itself still shows/hides normally via the tray icon; it just
; never gets its own taskbar button.
WinSetExStyle("+0x80", MainGui)  ; WS_EX_TOOLWINDOW

MainGui.SetFont("bold")
MainGui.Add("Text", "xm ym", "HWiNFO executable:")
MainGui.SetFont("norm")
pathEdit := MainGui.Add("Edit", "xm w360 h24 vHwinfoPathEdit", hwinfoPath)
browseBtn := MainGui.Add("Button", "x+5 w80 h24", "Browse")
browseBtn.OnEvent("Click", BrowseExe)

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "Systray icon:")
MainGui.SetFont("norm")
MainGui.Add("Button", "xm w150", "Pick Icon (shell32)...").OnEvent("Click", PickTrayIcon)
MainGui.Add("Button", "x+5 w150", "Use AHK Icon").OnEvent("Click", UseAHKIcon)

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "Startup:")
MainGui.SetFont("norm")
chkRunAtStartup := MainGui.Add("CheckBox", "xm vChkRunAtStartup", "Run HWiNFO Manager at Windows startup (as Administrator)")
chkRunAtStartup.Value := IsRunAtStartupEnabled()
chkRunAtStartup.OnEvent("Click", ToggleRunAtStartup)

chkHideGuiOnStart := MainGui.Add("CheckBox", "xm vChkHideGuiOnStart", "Hide User Interface on Start")
chkHideGuiOnStart.Value := hideGuiOnStart
chkHideGuiOnStart.OnEvent("Click", SaveHideGuiOnStartSetting)

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "HWiNFO auto restart:")
MainGui.SetFont("norm")
chkAutoRestart := MainGui.Add("CheckBox", "xm vChkAutoRestart", "Auto Restart Every")
chkAutoRestart.Value := autoRestartEnabled
chkAutoRestart.OnEvent("Click", SaveAutoRestartSettings)

autoRestartHoursEdit := MainGui.Add("Edit", "x+8 yp-2 w40 h20 vAutoRestartHoursEdit", autoRestartHours)
autoRestartHoursEdit.OnEvent("LoseFocus", SaveAutoRestartSettings)
MainGui.Add("Text", "x+4 yp+2", "hr")
autoRestartMinutesEdit := MainGui.Add("Edit", "x+8 yp-2 w40 h20 vAutoRestartMinutesEdit", autoRestartMinutes)
autoRestartMinutesEdit.OnEvent("LoseFocus", SaveAutoRestartSettings)
MainGui.Add("Text", "x+4 yp+2", "min")

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "HWiNFO running check:")
MainGui.SetFont("norm")
chkRunCheckEnabled := MainGui.Add("CheckBox", "xm vChkRunCheckEnabled", "Check if HWiNFO is Running Every")
chkRunCheckEnabled.Value := runCheckEnabled
chkRunCheckEnabled.OnEvent("Click", SaveRunCheckSettings)

runCheckIntervalEdit := MainGui.Add("Edit", "x+8 yp-2 w40 h20 vRunCheckIntervalEdit", runCheckIntervalMin)
runCheckIntervalEdit.OnEvent("LoseFocus", SaveRunCheckSettings)
MainGui.Add("Text", "x+4 yp+2", "min")

chkRunCheckAutoStart := MainGui.Add("CheckBox", "xm vChkRunCheckAutoStart", "Automatically start HWiNFO if it's not running")
chkRunCheckAutoStart.Value := runCheckAutoStart
chkRunCheckAutoStart.OnEvent("Click", SaveRunCheckSettings)

chkRunCheckPrompt := MainGui.Add("CheckBox", "xm vChkRunCheckPrompt", "Prompt before starting (choosing No disables these checks)")
chkRunCheckPrompt.Value := runCheckPrompt
chkRunCheckPrompt.OnEvent("Click", SaveRunCheckSettings)

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "Registry key to back up:")
MainGui.SetFont("norm")
regChoice := MainGui.Add("DropDownList", "xm w160 Choose" (regBase = "HWiNFO32" ? 2 : 1), ["HWiNFO64", "HWiNFO32"])
regChoice.OnEvent("Change", SaveGlobalSettings)

MainGui.SetFont("bold")
MainGui.Add("Text", "xm", "Profiles:")
MainGui.SetFont("norm")
lb := MainGui.Add("ListBox", "xm w445 r10 vProfileList")

MainGui.Add("Button", "xm w145", "Load Profile").OnEvent("Click", LoadProfile)
MainGui.Add("Button", "x+5 w145", "Update Selected").OnEvent("Click", UpdateSelectedProfile)
MainGui.Add("Button", "x+5 w145", "Save Current as New").OnEvent("Click", SaveNewProfile)
MainGui.Add("Button", "xm w145", "Rename Profile").OnEvent("Click", RenameProfile)
MainGui.Add("Button", "x+5 w145", "Open Profiles Folder").OnEvent("Click", (*) => Run(profilesDir))
MainGui.Add("Button", "x+5 w145", "Delete Profile").OnEvent("Click", DeleteProfile)

statusText := MainGui.Add("Text", "xm w445 r2", "Ready.")

; Closing the GUI just hides it - it does NOT end the script. The
; watchdog keeps running in the background; use the tray menu's
; "Exit" to actually quit.
MainGui.OnEvent("Close", (*) => MainGui.Hide())
MainGui.OnEvent("Escape", (*) => MainGui.Hide())

; Minimizing (via the titlebar button) sends it to the tray instead of
; leaving a minimized window sitting around with no taskbar button to
; restore it from (since the taskbar entry is hidden - see WS_EX_TOOLWINDOW
; above). Re-open it the same way you opened it originally: click the
; tray icon.
MainGui.OnEvent("Size", GuiMinimizeToTray)

RefreshList()
ApplyRunCheckTimer()

; Show the Profile Manager GUI on launch by default - unless the "Hide GUI
; on Start" checkbox is enabled, in which case the script just starts
; tray-only (matching how it already behaves after the window is closed).
if !hideGuiOnStart
    ShowMainGui()

; ---------------------------- Watchdog: initial start ---------------------

justStarted := true
if HWiNFOPID() != 0
    HWiNFOKill()
HWiNFOStart()

; ---------------------------- Main loop (watchdog) -------------------------
; This Loop runs forever as the script's persistent "main thread". Tray
; clicks and GUI button clicks fire as separate interrupting threads (AHK
; pumps messages during Sleep), so the tray icon and GUI stay fully
; responsive even while this is waiting out its auto-restart interval.
;
; When Auto Restart is unchecked, this loop just idles (short 1-minute
; sleeps) without touching HWiNFO at all - it only re-checks the setting
; each cycle so re-enabling it takes effect quickly. Note: since Sleep()
; can't be interrupted mid-wait, a change made WHILE a long interval is
; already in progress (e.g. disabling it partway through an 11h58m wait)
; won't take effect until that wait finishes.

Loop {
    if justStarted {
        justStarted := false  ; skip this pass's check - HWiNFO was JUST launched above, give it time to init.
    } else if autoRestartEnabled {
        if HWiNFOPID() != 0 {
            if HWiNFOKill() != 0 {
                Sleep(250)  ; brief pause so the process fully releases before relaunching
                HWiNFOStart()
            } else {
                TrayTip("HWiNFO Manager", "HWiNFO process refused to terminate. Is it running as admin?", "Icon!")
                Sleep(GetMillisecondsForMins(1))  ; retry soon instead of waiting a full interval
                Continue
            }
        } else {
            ; Shares the same auto-start/prompt settings as the periodic
            ; running-check below, so there's one consistent, configurable
            ; behavior instead of a hardcoded prompt here.
            HandleHWiNFONotRunning()
        }
    }
    Sleep(autoRestartEnabled ? autoRestartIntervalMs : GetMillisecondsForMins(1))
}

; ---------------------------- Functions: shared/helpers -------------------

ToRelativePath(fullPath) {
    ; Store paths relative to the script folder so the whole folder can be
    ; moved/renamed without breaking the .ini. Falls back to an absolute
    ; path if the target lives outside the script folder (e.g. an HWiNFO
    ; install in Program Files).
    global A_ScriptDir
    base := A_ScriptDir
    if (SubStr(fullPath, 1, StrLen(base)) = base) {
        rel := SubStr(fullPath, StrLen(base) + 1)
        rel := LTrim(rel, "\/")
        return rel = "" ? "." : rel
    }
    return fullPath
}

ToAbsolutePath(path) {
    global A_ScriptDir
    if path = ""
        return path
    ; Already absolute? (drive letter "X:" or UNC "\\server\...")
    if (SubStr(path, 2, 1) = ":") || (SubStr(path, 1, 2) = "\\")
        return path
    return A_ScriptDir "\" path
}

ResolveIconFile(path) {
    ; PickIconDlg (and sometimes users) hand back bare system filenames like
    ; "shell32.dll" with no directory. Windows itself resolves those fine via
    ; its standard DLL search order, but FileExist() doesn't search PATH, so
    ; it reports "not found" even though the file is really in System32.
    ; Check there (and a couple of other likely spots) before giving up.
    if path = "" || FileExist(path)
        return path
    if InStr(path, "\") || InStr(path, "/")
        return path  ; has a directory component already; nothing more we can do

    candidate := A_WinDir "\System32\" path
    if FileExist(candidate)
        return candidate
    candidate := A_WinDir "\SysWOW64\" path
    if FileExist(candidate)
        return candidate
    candidate := A_WinDir "\" path
    if FileExist(candidate)
        return candidate

    return path  ; couldn't resolve further; return unchanged
}

GetProfiles() {
    global configFile
    result := Map()
    raw := ""
    try raw := IniRead(configFile, "Profiles")
    catch
        return result
    for line in StrSplit(raw, "`n", "`r") {
        if line = ""
            continue
        parts := StrSplit(line, "=", , 2)
        if parts.Length = 2
            result[parts[1]] := ToAbsolutePath(parts[2])
    }
    return result
}

RefreshList(*) {
    global lb
    lb.Delete()
    for name, path in GetProfiles()
        lb.Add([name])
}

SetStatus(msg) {
    global statusText
    statusText.Text := msg
}

SaveGlobalSettings(*) {
    global configFile, pathEdit, regChoice
    IniWrite(ToRelativePath(pathEdit.Value), configFile, "Settings", "HWiNFOPath")
    IniWrite(regChoice.Text, configFile, "Settings", "RegBase")
}

SaveHideGuiOnStartSetting(ctrl, *) {
    global configFile, hideGuiOnStart
    hideGuiOnStart := ctrl.Value
    IniWrite(hideGuiOnStart ? "1" : "0", configFile, "Settings", "HideGuiOnStart")
    SetStatus(hideGuiOnStart ? "GUI will stay hidden on next start." : "GUI will show on next start.")
}

SanitizeFileName(name) {
    return RegExReplace(name, '[\\/:\*\?"<>\|]', "_")
}

GetExeName(fullPath) {
    SplitPath(fullPath, &outName)
    return outName
}

CloseAppGracefully(exeNameToClose) {
    ; A plain WM_CLOSE doesn't work for HWiNFO when "Minimize Sensors
    ; instead of closing" is on - it just re-minimizes instead of quitting.
    ; It also never gives HWiNFO the chance to call Shell_NotifyIcon
    ; (NIM_DELETE), leaving a "ghost" tray icon behind. Windows itself
    ; closes apps on shutdown/logoff differently: it sends
    ; WM_QUERYENDSESSION ("are you OK ending?") then WM_ENDSESSION with
    ; wParam=TRUE ("the session IS ending, clean up now"). Well-behaved
    ; tray apps generally treat that as a real, unconditional quit request,
    ; so we mimic that here before resorting to force-kill.
    if !ProcessExist(exeNameToClose)
        return

    DetectHiddenWindows(true)
    hwnds := WinGetList("ahk_exe " exeNameToClose)

    for hwnd in hwnds {
        try SendMessage(0x0011, 0, 0, , "ahk_id " hwnd)  ; WM_QUERYENDSESSION
    }
    for hwnd in hwnds {
        try SendMessage(0x0016, 1, 0, , "ahk_id " hwnd)  ; WM_ENDSESSION, wParam=TRUE
    }

    if ProcessWaitClose(exeNameToClose, 5)
        return

    ; Didn't honor it either - force-kill as the final fallback.
    if ProcessExist(exeNameToClose) {
        ProcessClose(exeNameToClose)
        ProcessWaitClose(exeNameToClose, 3)
    }
}

ExportRegKey(regKey, regFile) {
    ; Returns true on success
    try FileDelete(regFile)
    RunWait('reg export "' regKey '" "' regFile '" /y', , "Hide")
    return FileExist(regFile) ? true : false
}

GetMillisecondsForMins(minutes) {
    return minutes * 60000
}

GetMillisecondsForHours(hours) {
    return hours * 60 * 60000
}

; ---------------------------- Functions: run-at-startup --------------------
; Implemented as a Task Scheduler task (rather than a Startup-folder shortcut)
; so it can launch pre-elevated ("Run with highest privileges") - since this
; script self-elevates via *RunAs anyway, a plain Startup-folder shortcut
; would still trigger a UAC prompt on every login. A scheduled task set to
; run elevated for the current user does not prompt.
;
; Uses PowerShell's ScheduledTasks cmdlets rather than plain schtasks.exe,
; because schtasks.exe's /create switches can't touch the task's Conditions
; tab. By default Task Scheduler tasks refuse to start on battery power and
; will stop if AC is lost mid-run - not what you want for a monitoring tool
; that should just keep running. -AllowStartIfOnBatteries and
; -DontStopIfGoingOnBatteries below turn both of those conditions off.
; A temp .ps1 file is used (instead of passing the whole script inline via
; -Command) to sidestep quoting headaches around nested single/double quotes.

PSQuote(str) {
    ; Escape a string for safe embedding inside a PowerShell single-quoted
    ; literal ('...'): the only character that needs escaping there is a
    ; literal single quote, which PowerShell wants doubled ('').
    return StrReplace(str, "'", "''")
}

RunPowerShellScript(psContent) {
    ; Writes psContent to a temp .ps1 file, runs it hidden, returns
    ; {code, error}, then cleans up the temp file(s).
    ;
    ; The script is wrapped so that ANY cmdlet error becomes a terminating
    ; error (via $ErrorActionPreference = 'Stop') and is caught, written to
    ; an error file, and turned into a non-zero exit code. Without this,
    ; PowerShell cmdlet errors (e.g. a bad -Argument to
    ; New-ScheduledTaskAction) just print in red and the .ps1 keeps going /
    ; exits 0 - so callers here would wrongly think the task was created.
    psFile  := A_Temp "\HWiNFOMgr_TaskSetup_" A_TickCount ".ps1"
    errFile := psFile ".err.txt"
    try FileDelete(psFile)
    try FileDelete(errFile)

    wrapped := "$ErrorActionPreference = 'Stop'`n"
    wrapped .= "try {`n" psContent "`n}`n"
    wrapped .= "catch {`n"
    wrapped .= "  $_.Exception.Message | Out-File -FilePath '" PSQuote(errFile) "' -Encoding UTF8`n"
    wrapped .= "  exit 1`n"
    wrapped .= "}`n"

    FileAppend(wrapped, psFile, "UTF-8")
    exitCode := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '"', , "Hide")

    errMsg := ""
    if FileExist(errFile)
        try errMsg := Trim(FileRead(errFile, "UTF-8"))

    try FileDelete(psFile)
    try FileDelete(errFile)
    return {code: exitCode, error: errMsg}
}

IsRunAtStartupEnabled() {
    global RunAtStartupTaskName
    psContent := "if (Get-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
    return RunPowerShellScript(psContent).code = 0
}

SetRunAtStartup(enable) {
    global RunAtStartupTaskName
    if enable {
        ; Build the launch command: for a compiled .exe just the exe itself
        ; with no argument; for a plain script, the AutoHotkey interpreter
        ; as the executable and the quoted script path as its argument.
        execPath := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
        execArg  := A_IsCompiled ? "" : '"' A_ScriptFullPath '"'

        ; IMPORTANT: only pass -Argument when there actually is one.
        ; New-ScheduledTaskAction's -Argument parameter rejects an empty
        ; string ("Cannot bind argument to parameter 'Argument' because it
        ; is an empty string"), which is a terminating error. For the
        ; compiled-exe case execArg is "" (the exe needs no argument), so
        ; passing -Argument '' here silently killed task creation for every
        ; compiled build while working fine for the plain-script case
        ; (where execArg is always non-empty). Omitting the switch entirely
        ; when there's nothing to pass fixes that.
        if execArg = ""
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "'`n"
        else
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "' -Argument '" PSQuote(execArg) "'`n"

        psContent .= "$trigger = New-ScheduledTaskTrigger -AtLogOn`n"
        psContent .= "$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive`n"
        ; -AllowStartIfOnBatteries and -DontStopIfGoingOnBatteries turn off
        ; the two Conditions-tab settings that would otherwise block this
        ; monitoring tool from starting/staying running on battery power.
        ; -ExecutionTimeLimit ([TimeSpan]::Zero) disables the Settings-tab
        ; "Stop the task if it runs longer than: 3 days" limit, since this
        ; is meant to run indefinitely as long as Windows is logged in.
        psContent .= "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)`n"
        psContent .= "Register-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null"

        result := RunPowerShellScript(psContent)
        return {ok: result.code = 0, error: result.error}
    } else {
        ; Deleting a task that doesn't exist is treated as success too,
        ; since that still leaves us in the desired "not registered" state.
        psContent := "Unregister-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Confirm:$false -ErrorAction SilentlyContinue"
        RunPowerShellScript(psContent)
        return {ok: true, error: ""}
    }
}

ToggleRunAtStartup(ctrl, *) {
    enable := ctrl.Value
    result := SetRunAtStartup(enable)
    if !result.ok {
        msg := "Couldn't " (enable ? "create" : "remove") " the startup task."
        if result.error != ""
            msg .= "`n`nDetails:`n" result.error
        MsgBox(msg, "Startup", "Icon!")
        ctrl.Value := !enable  ; revert the checkbox to reflect what actually happened
        return
    }
    SetStatus(enable ? "HWiNFO Manager will now start automatically (elevated) at Windows login." : "Startup task removed.")
}

; ---------------------------- Functions: watchdog --------------------------

HWiNFOPID() {
    global exeName
    return ProcessExist(exeName)
}

HWiNFOKill() {
    global exeName
    pid := ProcessExist(exeName)
    if !pid
        return 0

    CloseAppGracefully(exeName)

    ; A single immediate check right here can occasionally still see the
    ; process as "existing" for a brief moment even after it has actually
    ; terminated (Windows can lag slightly in updating process state).
    ; Poll a few times over ~1.5s instead of judging on one instant check.
    Loop 6 {
        if !ProcessExist(exeName)
            return pid
        Sleep(250)
    }
    return 0
}

HWiNFOStart() {
    global hwinfoPath
    if hwinfoPath = "" || !FileExist(hwinfoPath) {
        TrayTip("HWiNFO Manager", "Can't start HWiNFO - set a valid executable path in the Profile Manager first.", "Icon!")
        return
    }
    ; No need for *RunAs here: this whole script is already elevated, so
    ; child processes it launches inherit that elevated token automatically.
    Run('"' hwinfoPath '"')
}

RestartHWiNFONow(*) {
    if HWiNFOPID() != 0
        HWiNFOKill()
    HWiNFOStart()
    TrayTip("HWiNFO Manager", "HWiNFO restarted.")
}

; ---------------------------- Functions: running-check ---------------------
; A separate, independently-timed check from the ~12h forced-restart loop
; above. When enabled, it fires every N minutes (configurable) and, if
; HWiNFO isn't running, either starts it automatically, prompts the user,
; or (if neither option is set) just notifies via TrayTip. The 12h loop's
; "not running" case also calls into HandleHWiNFONotRunning() so both
; paths share one consistent, configurable behavior.

ApplyRunCheckTimer() {
    ; (Re)starts or stops the periodic timer to match current settings.
    ; Calling SetTimer again with the same function reference updates the
    ; existing timer's period rather than creating a duplicate one.
    global runCheckEnabled, runCheckIntervalMin
    if runCheckEnabled && runCheckIntervalMin > 0
        SetTimer(RunningCheckTick, runCheckIntervalMin * 60000)
    else
        SetTimer(RunningCheckTick, 0)  ; 0 = disable
}

RunningCheckTick(*) {
    if HWiNFOPID() != 0
        return  ; running fine - nothing to do
    HandleHWiNFONotRunning()
}

HandleHWiNFONotRunning() {
    global runCheckAutoStart, runCheckPrompt, runCheckEnabled
    global chkRunCheckEnabled, configFile

    if runCheckAutoStart {
        HWiNFOStart()
        TrayTip("HWiNFO Manager", "HWiNFO wasn't running - started it automatically.")
        return
    }

    if runCheckPrompt {
        result := MsgBox("HWiNFO is not running. Would you like to restart it?", "HWiNFO Auto Restart", "YesNo")
        if result = "Yes" {
            HWiNFOStart()
        } else {
            ; Per the "prompt" setting's contract: answering No disables the
            ; periodic checks entirely (the 12h loop still runs regardless -
            ; only the dedicated running-check timer is turned off).
            runCheckEnabled := false
            IniWrite(0, configFile, "Settings", "RunCheckEnabled")
            try chkRunCheckEnabled.Value := 0
            ApplyRunCheckTimer()
            SetStatus("HWiNFO running-check disabled.")
        }
        return
    }

    ; Neither auto-start nor prompt is enabled - just notify, take no action.
    TrayTip("HWiNFO Manager", "HWiNFO is not running.", "Icon!")
}

SaveRunCheckSettings(*) {
    global chkRunCheckEnabled, chkRunCheckAutoStart, chkRunCheckPrompt, runCheckIntervalEdit, configFile
    global runCheckEnabled, runCheckIntervalMin, runCheckAutoStart, runCheckPrompt

    runCheckEnabled   := chkRunCheckEnabled.Value ? true : false
    runCheckAutoStart := chkRunCheckAutoStart.Value ? true : false
    runCheckPrompt    := chkRunCheckPrompt.Value ? true : false

    ; Validate the interval; revert to the last good value on bad input
    ; (empty, non-numeric, zero, negative) instead of accepting it.
    val := Trim(runCheckIntervalEdit.Value)
    if !IsInteger(val) || Integer(val) < 1 {
        val := runCheckIntervalMin
        runCheckIntervalEdit.Value := val
    }
    runCheckIntervalMin := Integer(val)

    IniWrite(runCheckEnabled ? 1 : 0, configFile, "Settings", "RunCheckEnabled")
    IniWrite(runCheckIntervalMin, configFile, "Settings", "RunCheckIntervalMin")
    IniWrite(runCheckAutoStart ? 1 : 0, configFile, "Settings", "RunCheckAutoStart")
    IniWrite(runCheckPrompt ? 1 : 0, configFile, "Settings", "RunCheckPrompt")

    ApplyRunCheckTimer()
    SetStatus("Running-check settings saved.")
}

SaveAutoRestartSettings(*) {
    global chkAutoRestart, autoRestartHoursEdit, autoRestartMinutesEdit, configFile
    global autoRestartEnabled, autoRestartHours, autoRestartMinutes, autoRestartIntervalMs

    autoRestartEnabled := chkAutoRestart.Value ? true : false

    ; Validate hours/minutes; revert to the last good value on bad input.
    hVal := Trim(autoRestartHoursEdit.Value)
    if !IsInteger(hVal) || Integer(hVal) < 0 {
        hVal := autoRestartHours
        autoRestartHoursEdit.Value := hVal
    }
    mVal := Trim(autoRestartMinutesEdit.Value)
    if !IsInteger(mVal) || Integer(mVal) < 0 || Integer(mVal) > 59 {
        mVal := autoRestartMinutes
        autoRestartMinutesEdit.Value := mVal
    }
    autoRestartHours   := Integer(hVal)
    autoRestartMinutes := Integer(mVal)

    ; Guard against a 0h0m interval, which would restart HWiNFO in a tight loop.
    if autoRestartHours = 0 && autoRestartMinutes = 0 {
        autoRestartMinutes := 1
        autoRestartMinutesEdit.Value := 1
        MsgBox("Interval can't be zero - set to 1 minute.", "Auto Restart", "Icon!")
    }

    autoRestartIntervalMs := GetMillisecondsForHours(autoRestartHours) + GetMillisecondsForMins(autoRestartMinutes)

    IniWrite(autoRestartEnabled ? 1 : 0, configFile, "Settings", "AutoRestartEnabled")
    IniWrite(autoRestartHours, configFile, "Settings", "AutoRestartHours")
    IniWrite(autoRestartMinutes, configFile, "Settings", "AutoRestartMinutes")

    SetStatus("Auto restart settings saved.")
}

; ---------------------------- Functions: GUI / profile manager -------------

ShowMainGui(*) {
    global MainGui
    MainGui.Show()
}

GuiMinimizeToTray(GuiObj, MinMax, Width, Height) {
    ; MinMax: -1 = minimized, 1 = maximized, 0 = neither (plain resize)
    if MinMax = -1
        GuiObj.Hide()
}

PickTrayIcon(*) {
    ; Opens the native Windows "Change Icon" picker - the exact same dialog
    ; you get from a shortcut's Properties -> Change Icon. It shows the full
    ; icon grid; click one, hit OK, and it's applied automatically. This
    ; dialog has its own "Browse..." button built in, so no separate
    ; browse control is needed here.
    global MainGui, trayIconFile, trayIconIndex

    startFile := trayIconFile != "" ? trayIconFile : A_WinDir "\System32\shell32.dll"
    if !FileExist(startFile)
        startFile := A_WinDir "\System32\shell32.dll"  ; must be an ABSOLUTE path -
        ; if the user doesn't change files (just picks a different icon inside
        ; it), the dialog hands this same string back unchanged, so a bare
        ; "shell32.dll" here would come back bare too and fail FileExist later.

    bufChars := 260
    buf := Buffer(bufChars * 2, 0)  ; wide-char buffer (MAX_PATH)
    StrPut(startFile, buf, bufChars, "UTF-16")

    iconIndex := 0
    ok := 0
    try ok := DllCall("shell32\PickIconDlg", "ptr", MainGui.Hwnd, "ptr", buf, "uint", bufChars, "int*", &iconIndex)
    catch as e {
        MsgBox("Couldn't open the icon picker:`n" e.Message, "Pick Icon", "IconX")
        return
    }
    if !ok
        return  ; user hit Cancel

    chosenFile := ResolveIconFile(StrGet(buf, "UTF-16"))
    if !FileExist(chosenFile) {
        MsgBox("The picker returned a file that couldn't be located:`n" chosenFile, "Pick Icon", "IconX")
        return
    }
    trayIconFile := chosenFile
    trayIconIndex := iconIndex + 1  ; PickIconDlg reports 0-based; TraySetIcon expects 1-based
    ApplyTrayIcon()
}

ApplyTrayIcon(*) {
    global trayIconFile, trayIconIndex, configFile

    file := trayIconFile
    if file = "" {
        UseAHKIcon()
        return
    }

    file := ResolveIconFile(file)
    if !FileExist(file) {
        MsgBox("File not found:`n" file, "Tray Icon", "Icon!")
        return
    }
    trayIconFile := file  ; keep the resolved full path

    try {
        TraySetIcon(file, trayIconIndex)
    } catch as e {
        MsgBox("Couldn't load that icon (bad file or icon number).`n`n" e.Message, "Tray Icon", "IconX")
        return
    }

    IniWrite(ToRelativePath(file), configFile, "Settings", "TrayIconFile")
    IniWrite(trayIconIndex, configFile, "Settings", "TrayIconIndex")
    SetStatus("Tray icon updated.")
}

UseAHKIcon(*) {
    global trayIconFile, trayIconIndex, configFile
    try TraySetIcon("*")  ; asterisk -> revert to AutoHotkey's built-in default icon (an empty string does NOT do this in v2 - it silently no-ops)
    trayIconFile := ""
    trayIconIndex := 1
    try IniDelete(configFile, "Settings", "TrayIconFile")
    try IniDelete(configFile, "Settings", "TrayIconIndex")
    SetStatus("Tray icon reset to the default AHK icon.")
}

BrowseExe(*) {
    global pathEdit, hwinfoPath, exeName
    chosen := FileSelect(1, , "Select HWiNFO executable", "Executables (*.exe)")
    if chosen != "" {
        pathEdit.Value := chosen
        hwinfoPath := chosen
        exeName := GetExeName(chosen)
        SaveGlobalSettings()
        SetStatus("HWiNFO path updated.")
    }
}

SaveNewProfile(*) {
    global regChoice, profilesDir, configFile
    SaveGlobalSettings()

    ib := InputBox("Enter a name for this profile:", "New Profile")
    if ib.Result = "Cancel" || Trim(ib.Value) = ""
        return
    name := Trim(ib.Value)

    if GetProfiles().Has(name) {
        MsgBox("A profile named '" name "' already exists. Choose a different name or use Update Selected instead.", "Name in use", "Icon!")
        return
    }

    fileName := SanitizeFileName(name) ".reg"
    regFile  := profilesDir "\" fileName
    regKey   := "HKCU\Software\" regChoice.Text

    ok := ExportRegKey(regKey, regFile)
    if !ok {
        SetStatus("Export failed. Is the registry key correct?")
        return
    }

    IniWrite(ToRelativePath(regFile), configFile, "Profiles", name)
    RefreshList()
    SetStatus("Saved current settings as profile '" name "'.")
}

UpdateSelectedProfile(*) {
    global lb, regChoice
    name := lb.Text
    if name = "" {
        MsgBox("Select a profile first.", "No profile selected", "Icon!")
        return
    }
    profiles := GetProfiles()
    regFile := profiles[name]
    regKey := "HKCU\Software\" regChoice.Text

    result := MsgBox("Overwrite profile '" name "' with the CURRENT HWiNFO settings?", "Confirm Update", "YesNo Icon?")
    if result != "Yes"
        return

    ok := ExportRegKey(regKey, regFile)
    if ok
        SetStatus("Profile '" name "' updated.")
    else
        SetStatus("Update failed.")
}

LoadProfile(*) {
    global lb, pathEdit, regChoice, hwinfoPath, exeName
    name := lb.Text
    if name = "" {
        MsgBox("Select a profile first.", "No profile selected", "Icon!")
        return
    }
    profiles := GetProfiles()
    regFile := profiles[name]
    if !FileExist(regFile) {
        MsgBox("The .reg file for this profile is missing:`n" regFile, "File not found", "IconX")
        return
    }
    hwPath := pathEdit.Value
    if hwPath = "" || !FileExist(hwPath) {
        MsgBox("Set a valid path to the HWiNFO executable first.", "HWiNFO path missing", "Icon!")
        return
    }

    ; Keep the watchdog in sync with whatever path is currently set here.
    hwinfoPath := hwPath
    exeName := GetExeName(hwPath)

    SetStatus("Closing HWiNFO...")
    CloseAppGracefully(exeName)

    ; IMPORTANT: .reg import only ADDS/OVERWRITES values present in the file -
    ; it can never delete a value. Settings that are represented by the ABSENCE
    ; of a registry value (e.g. a disabled "Show in OSD" toggle) would otherwise
    ; never get "unset" on import, since old leftover values stay behind.
    ; Wiping the key first guarantees an exact restore, not a merge.
    regKey := "HKCU\Software\" regChoice.Text
    ; Safety guard: never let this run against anything other than exactly
    ; one of the two expected HWiNFO keys. If regChoice.Text were ever
    ; empty or unexpected, regKey could collapse to "HKCU\Software\" and
    ; reg delete would wipe EVERY app's settings under your profile.
    if !(regChoice.Text = "HWiNFO64" || regChoice.Text = "HWiNFO32") {
        MsgBox("Refusing to continue: unexpected registry key selection (`"" regChoice.Text "`"). Nothing was deleted.", "Safety check failed", "IconX")
        return
    }
    SetStatus("Clearing previous registry state...")
    RunWait('reg delete "' regKey '" /f', , "Hide")

    SetStatus("Importing profile '" name "'...")
    RunWait('reg import "' regFile '"', , "Hide")
    Sleep(200)

    SetStatus("Starting HWiNFO...")
    HWiNFOStart()
    SetStatus("Profile '" name "' loaded and HWiNFO started.")
}

DeleteProfile(*) {
    global lb, configFile
    name := lb.Text
    if name = "" {
        MsgBox("Select a profile first.", "No profile selected", "Icon!")
        return
    }
    result := MsgBox("Delete profile '" name "' and its .reg file? This cannot be undone.", "Confirm Delete", "YesNo Icon!")
    if result != "Yes"
        return

    profiles := GetProfiles()
    regFile := profiles[name]
    IniDelete(configFile, "Profiles", name)
    try FileDelete(regFile)
    RefreshList()
    SetStatus("Profile '" name "' deleted.")
}

RenameProfile(*) {
    global lb, configFile, profilesDir
    oldName := lb.Text
    if oldName = "" {
        MsgBox("Select a profile first.", "No profile selected", "Icon!")
        return
    }
    ib := InputBox("Enter a new name for '" oldName "':", "Rename Profile", , oldName)
    if ib.Result = "Cancel" || Trim(ib.Value) = "" || Trim(ib.Value) = oldName
        return
    newName := Trim(ib.Value)

    if GetProfiles().Has(newName) {
        MsgBox("A profile named '" newName "' already exists.", "Name in use", "Icon!")
        return
    }

    profiles := GetProfiles()
    oldRegFile := profiles[oldName]
    newRegFile := profilesDir "\" SanitizeFileName(newName) ".reg"

    try FileMove(oldRegFile, newRegFile, 1)
    IniDelete(configFile, "Profiles", oldName)
    IniWrite(ToRelativePath(newRegFile), configFile, "Profiles", newName)
    RefreshList()
    SetStatus("Renamed '" oldName "' to '" newName "'.")
}
