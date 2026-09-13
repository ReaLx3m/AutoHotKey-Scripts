#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ============================================================
;  Remote Button Mapper
;  - Capture a scancode from any remote/keyboard button
;  - Assign it a key or key-combo to send instead
;  - Runs in the systray. Closing the window just hides it.
;    Double-click the tray icon to bring the window back.
;  - Mappings are saved to remote_mappings.ini next to the script
;    and reloaded (and re-armed) automatically on next launch.
;  - Scancode-based single-run mappings have a Trigger setting: fire on
;    PRESS (the instant the button goes down), on a long PRESS (mid-hold,
;    once the threshold elapses), on a short RELEASE (tap - only if the
;    threshold never elapsed), or on RELEASE regardless of how long the
;    button was held. This means a single physical button can carry
;    independent mappings for press and release, or a tap vs. a hold - the
;    hold duration is a single global setting (Long press threshold, ms).
;    Raw HID mappings don't support any of this - see comments near
;    FireButtonMappings() for why.
;  - PROFILES: mappings belong to a named profile. "Default" always exists
;    and is used whenever no app-specific profile is active. Any other
;    profile can be given a list of process names (e.g. kodi.exe); when
;    "Enable app-based auto profile switching" is on, a background watcher polls
;    the foreground window every 500ms and swaps the ACTIVE profile to
;    whichever one claims the focused app's process, falling back to
;    Default when nothing matches (or when app-watching is off). Firing is
;    resolved per BUTTON, not as a blanket profile swap: for each physical
;    button, if the active profile defines any mapping on it, that mapping
;    fires; otherwise Default's mapping for that same button fires instead
;    (if Default has one). So a non-Default profile only needs to define
;    the buttons it wants to override or add - everything else transparently
;    falls through to Default. See EffectiveProfileForButton(). The GUI's
;    "Editing profile" list box (to the left of the mappings list) is a
;    separate, independent concept: it just controls which profile's
;    mappings the list/capture form below is showing and saving into,
;    regardless of which profile the engine currently has active.
;    New/Rename/Delete Profile buttons manage the non-Default profiles and
;    their process lists; Default itself can't be renamed or deleted.
; ============================================================

mapFile := A_ScriptDir "\remote_mappings.ini"
RunAtStartupTaskName := "Remote Button Mapper Startup"

; ---------------- Elevation ----------------
; Some Windows accessibility features (Voice Access, Narrator, Magnifier,
; the on-screen keyboard) run with a special "UIAccess" privilege. While one
; of them has keyboard focus, Windows can bypass a plain (non-admin)
; script's low-level keyboard hook, so scancode-based mappings stop firing
; and the physical button's normal/factory function leaks through until
; focus moves to an ordinary window. Running this script elevated
; (Administrator) puts it on equal footing and fixes that - see
; RelaunchElevated()/SetRunElevated() further down for the toggle that
; controls this. It's opt-in because it means a UAC prompt on launch.
; This check runs before any tray icon or GUI is created so a saved
; "run elevated" preference relaunches immediately, rather than showing a
; non-elevated window that then closes and reopens moments later.
if FileExist(mapFile) && IniRead(mapFile, "Settings", "RunElevated", "0") = "1" && !A_IsAdmin
    RelaunchElevated()

mappings := Map()      ; key "<Profile>::SCxxx" -> {profile, sc, desc, target, enabled}
mapOrder := []         ; keeps display/registration order
masterEnabled := true
capturedSC := 0
startHidden := false
runElevated := false
runAtStartup := false
runAtStartupMode := "shortcut"   ; "shortcut" (shell:startup) or "admin" (Task Scheduler, runs elevated with no UAC prompt)
targetSendString := ""
; Tracks the InputHook used by the "Capture" button (Learn a button) and
; whether it currently has all button hotkeys suspended - see StartCapture/
; OnCaptureKey/ResumeButtonHotkeysIfNeeded for why that's needed.
captureHook := ""
captureSuspended := false

; ---------------- Profiles ----------------
; A profile is a named set of mappings. "Default" always exists, can't be
; renamed/deleted, and has no process matcher - it's the fallback used
; whenever no app-specific profile is active (including whenever app-watch
; is off). Non-Default profiles carry a list of process filenames
; (case-insensitive exact match against the foreground window's exe) that,
; when focused, make that profile the active one instead of Default.
; profiles: name -> {processNames: [...]}
profiles := Map("Default", {processNames: []})
; activeProfileName is which profile the FIRING ENGINE currently uses -
; driven entirely by the foreground-app watcher (or forced to "Default"
; while appWatchEnabled is false). editingProfileName is which profile the
; GUI is currently showing/editing in the list and capture form - a pure UI
; concern, chosen by the user, independent of whatever is actively firing.
; These are deliberately two different globals; don't conflate them.
activeProfileName := "Default"
editingProfileName := "Default"
appWatchEnabled := false

; Long-press detection (scancode mappings only - see FireButtonMappings).
; longPressMs is the single global setting: hold a button longer than this
; and, on release, the button's "long" mapping(s) fire instead of its
; "short" one(s). buttonPressState tracks the in-progress press for each
; scancode button key ("SCxxx") -> {pressed, token, downTick, longFired}.
longPressMs := 500
buttonPressState := Map()

; Continuous-run state for the "Repeat while holding" and "Toggle" run
; modes (see StartRepeat/StopRepeat/ToggleRepeat near FireButtonMappings).
; repeatActive: mapping id -> bool (currently looping).
; repeatTimerFns: mapping id -> the bound SetTimer function reference, kept
; around because AHK needs that exact reference again to turn the timer off.
repeatActive := Map()
repeatTimerFns := Map()

; Steps of the macro currently shown in the main form's capture UI (only
; meaningful while Action = Macro). Populated/edited via OpenMacroEditor().
currentMacroSteps := []

; State for capturing raw HID events (buttons Capture can't see) directly
; from the main window, as an alternative to scancode-based capture.
captureRawMode := false
rawCaptureArmed := false
capturedRawPage := 0
capturedRawBytesHex := ""
lastCaptureKind := "sc"   ; "sc" or "raw" - tells Add/Update which kind to save
editingId := ""        ; id of the mapping currently loaded from the list for editing ("" = none / new)

; ---------------- Tray setup ----------------
A_TrayMenu.Delete()
A_TrayMenu.Add("Show Mapper", (*) => ShowGui())
A_TrayMenu.Add()
A_TrayMenu.Add("Remapping Enabled", ToggleMasterFromTray)
A_TrayMenu.Check("Remapping Enabled")
A_TrayMenu.Add("Start Hidden", ToggleStartHiddenFromTray)
A_TrayMenu.Add("Enable App-Based Auto Profile Switching", ToggleAppWatchFromTray)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Show Mapper"
A_IconTip := "Remote Button Mapper"

OnMessage(0x404, OnTrayMsg)
OnTrayMsg(wParam, lParam, msg, hwnd) {
    if (lParam = 0x203)   ; WM_LBUTTONDBLCLK on the tray icon
        ShowGui()
}

; ---------------- GUI ----------------
g := Gui("", "Remote Button Mapper")
g.OnEvent("Close", (*) => (CancelPendingButtonCapture(), g.Hide()))
g.SetFont("s10", "Segoe UI")

grpLearnButton := g.Add("GroupBox", "x8 y10 w572 h390", "Learn a button")
g.Add("Text", "x20 y30", "1. Click Capture, then press a button:")
btnCapture := g.Add("Button", "x+10 yp-4 w100", "Capture")
btnCapture.OnEvent("Click", StartCapture)
chkCaptureRaw := g.Add("Checkbox", "x20 y+6", "Capture raw HID event (use if the button isn't detected above)")
chkCaptureRaw.OnEvent("Click", (*) => SetCaptureRawMode(chkCaptureRaw.Value))
txtCaptureStatus := g.Add("Text", "x20 y+8 w520", "Not captured yet.")

g.Add("Text", "x20 y+15", "Description:")
editDesc := g.Add("Edit", "x+10 w150")
g.Add("Text", "x+15", "Action:")
ddlActionType := g.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App", "Macro"])
ddlActionType.OnEvent("Change", (*) => OnActionTypeChange())

lblSends := g.Add("Text", "x20 y+15", "Sends:")
txtTarget := g.Add("Edit", "x+10 w268 ReadOnly Background0xFFFFFF")
; Clicking/tabbing into this field starts capture directly (no separate
; "Capture Key" button) - see StartTargetCapture's re-entrancy guard. It then
; keeps listening and re-capturing on every subsequent keypress for as long
; as the field has focus; StopTargetCapture ends that when focus leaves.
txtTarget.OnEvent("Focus", StartTargetCapture)
txtTarget.OnEvent("LoseFocus", StopTargetCapture)

; Sends / App path+args / Macro info are three alternative views of the same
; row - only one is visible at a time (see OnActionTypeChange) - so all three
; start at this same anchor row instead of stacking on top of one another
; regardless of visibility. That stacking is what used to leave a big gap
; above Trigger for Key/Macro (which only need this one row) and made the
; App fields (which need this row plus Arguments below it) sit in the middle
; of space sized for all three groups at once.
lblSends.GetPos(&actionRow1X, &actionRow1Y, , &actionRow1H)

lblAppPath := g.Add("Text", "x20 y" actionRow1Y, "App/File path:")
editAppPath := g.Add("Edit", "x+10 w280")
btnBrowseApp := g.Add("Button", "x+8 w80", "Browse...")
btnBrowseApp.OnEvent("Click", (*) => BrowseForAppInto(editAppPath))

lblAppArgs := g.Add("Text", "x20 y+10", "Arguments (optional):")
editAppArgs := g.Add("Edit", "x+10 w330")
lblAppArgs.GetPos(&actionRow2X, &actionRow2Y)
editAppArgs.GetPos(, , , &actionRow2H)

lblMacroInfo := g.Add("Text", "x20 y" actionRow1Y " w280", "Macro: 0 step(s)")
btnEditMacro := g.Add("Button", "x+5 yp-5 w120", "Edit Macro...")
btnEditMacro.OnEvent("Click", OnEditMacroClick)

; Trigger governs WHEN a single-run scancode mapping fires relative to the
; physical press: immediately on Down ("press"), on Up if released before
; the long-press threshold ("short" release), or on Up only after being
; held past the threshold ("long" release). Doesn't apply to raw HID
; captures - see the comment near FireButtonMappings for why.
;
; Its Y position (and that of every control below it) is built here assuming
; the "collapsed" one-row case (Send Key/Combo or Macro, whichever is
; selected by default) - ReflowActionAreaForType(), called from
; OnActionTypeChange(), shifts this whole block down while "Launch App" is
; selected (the only action type that needs the extra Arguments row) and
; back up when it isn't, rather than reserving that row's space permanently.
triggerGapY := actionRow1Y + actionRow1H + 10
lblTrigger := g.Add("Text", "x20 y" triggerGapY, "Trigger:")
ddlPressType := g.Add("DropDownList", "x+10 w280 Choose1", ["On release (short tap)", "On press (immediate)", "On long press (while held)", "On release (any duration)"])
; How far to shift lblTrigger-and-everything-below to make room for the
; Arguments row: the extra vertical space that row (plus its gap) occupies.
appExtraRowShift := (actionRow2Y + actionRow2H) - (actionRow1Y + actionRow1H)
actionAreaExpanded := false

lblRunMode := g.Add("Text", "x20 y+12", "Run mode:")
ddlRunMode := g.Add("DropDownList", "x+10 w220 Choose1", ["Single run", "Repeat while holding", "Toggle (press to start/stop)"])
ddlRunMode.OnEvent("Change", (*) => OnRunModeChange())
lblRepeatMs := g.Add("Text", "x+15", "Interval (ms):")
edRepeatMs := g.Add("Edit", "x+8 w60", "100")

btnAddNew := g.Add("Button", "x20 y+18 w110", "Add Mapping")
btnAddNew.OnEvent("Click", (*) => SaveMapping(true))
btnUpdate := g.Add("Button", "x+8 w110", "Update Mapping")
btnUpdate.OnEvent("Click", (*) => SaveMapping(false))
btnTest := g.Add("Button", "x+8 w90", "Test Send")
btnTest.OnEvent("Click", TestSend)
btnClearForm := g.Add("Button", "x+8 w70", "Clear")
btnClearForm.OnEvent("Click", (*) => ResetCaptureUI())
; The GroupBox was given a fixed h390 above, which doesn't actually reach
; just past this button row - it was eyeballed and leaves the box's bottom
; edge well below here, overlapping into the Profiles section beneath it.
; Size it for real off this row's actual position instead, and re-run this
; anytime the row above moves (see ResizeLearnButtonBox/ReflowActionAreaForType).
ResizeLearnButtonBox()

lblProfilesHeader := g.Add("Text", "x20 y+18", "Profiles")
; "r13" tells AHK to size the box for exactly 13 rows before it needs a
; scrollbar - more reliable than guessing a pixel height, since it adapts to
; whatever font size is actually in effect.
lbProfiles := g.Add("ListBox", "x20 y+2 w150 r13", ["Default"])
lbProfiles.OnEvent("Change", (*) => OnEditingProfileChange())
lbProfiles.GetPos(&lbProfilesX, &lbProfilesY, &lbProfilesW, &lbProfilesH)

lv := g.Add("ListView", "x+10 yp w400 h" lbProfilesH, ["On", "Remote Button", "Sends", "Press"])
lv.OnEvent("ItemSelect", LVSelect)
lv.OnEvent("ContextMenu", LVContextMenu)
lv.ModifyCol(1, 35)
lv.ModifyCol(2, 140)
lv.ModifyCol(3, 170)
lv.ModifyCol(4, 55)
lv.GetPos(&lvX, &lvY, &lvW, &lvH)

; ---- Profile management ----
; "Editing profile" is a pure GUI concern (which profile the list/form below
; shows and saves into) - independent of activeProfileName, which the firing
; engine drives from the foreground-app watcher. See handoff §4. Selecting a
; name in the profile list box above is what changes it; these buttons
; manage the list box's contents, laid out in a row directly beneath it
; whose combined width never exceeds the box's own width. New is 20%
; narrower and Rename 20% wider than an equal three-way split; Delete stays
; at the base split width, so the row's total width is unchanged.
profileBtnGap := 3
profileBtnW := (lbProfilesW - 2 * profileBtnGap) // 3
newBtnW := Round(profileBtnW * 0.8)
renameBtnW := Round(profileBtnW * 1.2)
deleteBtnW := profileBtnW
btnNewProfile := g.Add("Button", "x" lbProfilesX " y" (lbProfilesY + lbProfilesH + 10) " w" newBtnW, "New")
btnNewProfile.OnEvent("Click", (*) => OpenProfileDialog("new"))
btnRenameProfile := g.Add("Button", "x+" profileBtnGap " yp w" renameBtnW, "Rename")
btnRenameProfile.OnEvent("Click", (*) => OpenProfileDialog("rename"))
btnDeleteProfile := g.Add("Button", "x+" profileBtnGap " yp w" deleteBtnW, "Delete")
btnDeleteProfile.OnEvent("Click", (*) => DeleteProfileFlow())
btnDeleteProfile.GetPos(&dpX, &dpY, &dpW, &dpH)

btnToggle := g.Add("Button", "x" lvX " y" (lvY + lvH + 10) " w130", "Enable/Disable")
btnToggle.OnEvent("Click", ToggleSelected)
btnRemove := g.Add("Button", "x+10 w110", "Remove")
btnRemove.OnEvent("Click", RemoveSelected)
btnRawSniffer := g.Add("Button", "x+10 w130", "Raw HID Sniffer...")
btnRawSniffer.OnEvent("Click", OpenRawSniffer)
btnRawSniffer.GetPos(&rsX, &rsY, &rsW, &rsH)

; The "Profiles" column (list box + its row of 3 buttons) and the mapping
; action-button row don't necessarily end at the same height, so the next
; row below both is anchored to whichever one actually goes lower.
belowProfileColsY := Max(dpY + dpH, rsY + rsH) + 15

chkStartHidden := g.Add("Checkbox", "x20 y" belowProfileColsY, "Start hidden in systray (don't show this window on launch)")
chkStartHidden.OnEvent("Click", (*) => SetStartHidden(chkStartHidden.Value))
chkMaster := g.Add("Checkbox", "x20 y+8", "Remapping enabled")
chkMaster.OnEvent("Click", (*) => SetMasterEnabled(chkMaster.Value))

chkAppWatch := g.Add("Checkbox", "x20 y+10", "Enable app-based auto profile switching")
chkAppWatch.OnEvent("Click", (*) => SetAppWatchEnabled(chkAppWatch.Value))

chkRunElevated := g.Add("Checkbox", "x20 y+10", "Run elevated (Administrator)")
chkRunElevated.OnEvent("Click", (*) => SetRunElevated(chkRunElevated.Value))
lblElevatedInfo := g.Add("Text", "x38 y+2 w544 cGray", "Fixes mappings getting stuck sending the button's factory function while Voice Access, Narrator, Magnifier, or the on-screen keyboard has focus. Turning this on restarts the app now with a UAC prompt.")

chkRunStartup := g.Add("Checkbox", "x20 y+10", "Run on startup")
chkRunStartup.OnEvent("Click", (*) => SetRunAtStartup(chkRunStartup.Value))
ddlRunStartupMode := g.Add("DropDownList", "x+10 yp-2 w220", ["Shortcut in shell:startup", "As admin (Task Scheduler)"])
ddlRunStartupMode.Choose(1)
ddlRunStartupMode.OnEvent("Change", (*) => OnRunStartupModeChange())

lblLongPress := g.Add("Text", "x20 y+12", "Long press threshold (ms):")
edLongPressMs := g.Add("Edit", "x+10 w70", String(longPressMs))
edLongPressMs.OnEvent("Change", (*) => OnLongPressMsChange())

txtStatus := g.Add("Text", "x20 y+15 w560", "Ready.")
txtActiveProfile := g.Add("Text", "x20 y+8 w560", "Active profile: Default")

; Every control from Trigger downward, in a flat list, so
; ReflowActionAreaForType() can shift them all by the same delta together
; when the Launch App fields' extra row is added or removed above them.
controlsBelowActionRow := [lblTrigger, ddlPressType, lblRunMode, ddlRunMode, lblRepeatMs, edRepeatMs,
    btnAddNew, btnUpdate, btnTest, btnClearForm,
    lblProfilesHeader, lbProfiles, lv,
    btnNewProfile, btnRenameProfile, btnDeleteProfile,
    btnToggle, btnRemove, btnRawSniffer,
    chkStartHidden, chkMaster, chkAppWatch, chkRunElevated, lblElevatedInfo,
    chkRunStartup, ddlRunStartupMode,
    lblLongPress, edLongPressMs, txtStatus, txtActiveProfile]

; Moves every control in controlsBelowActionRow down (positive deltaY) or up
; (negative) by the same amount, preserving their layout relative to each
; other while making room for (or reclaiming) the Launch App Arguments row.
; Windows doesn't always repaint the area a moved control vacated, which
; left ghost/overlapping pixels behind after a shift - the RedrawWindow call
; at the end forces the whole client area (and every child control) to
; erase and repaint cleanly once all the moves are done.
; Sizes the "Learn a button" GroupBox to end a fixed margin below whichever
; row Add Mapping/Update Mapping/Test Send/Clear is currently sitting on,
; rather than trusting the box's original (miscalibrated) static height or
; assuming a delta shift lines the two up - this way it's correct in both
; the collapsed and Launch-App-expanded layouts, and after any future change
; to what's above it.
ResizeLearnButtonBox() {
    global grpLearnButton, btnClearForm
    btnClearForm.GetPos(&bcx, &bcy, &bcw, &bch)
    grpLearnButton.GetPos(&gbx, &gby, &gbw, &gbh)
    newBottom := bcy + bch + 15
    grpLearnButton.Move(, , gbw, newBottom - gby)
}

ReflowActionAreaForType(deltaY) {
    global controlsBelowActionRow, g
    if deltaY = 0
        return
    for ctrl in controlsBelowActionRow {
        ctrl.GetPos(&cx, &cy)
        ctrl.Move(, cy + deltaY)
    }
    ; Re-fit the box to the button row's new position now that it's moved,
    ; instead of growing/shrinking the box by deltaY off its old (wrong) size.
    ResizeLearnButtonBox()
    ; The window itself was auto-sized to fit the initial (collapsed) layout
    ; and won't grow on its own, so everything shifted below the old bottom
    ; edge would otherwise end up outside the visible window. Pass X/Y back
    ; explicitly - leaving them blank resets the window's position instead
    ; of preserving it.
    g.GetPos(&gx, &gy, &gw, &gh)
    g.Move(gx, gy, gw, gh + deltaY)
    ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    DllCall("RedrawWindow", "ptr", g.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0004 | 0x0080 | 0x0100)
}

OnActionTypeChange(*) {
    global actionAreaExpanded, appExtraRowShift
    isApp := ddlActionType.Value = 2
    isMacro := ddlActionType.Value = 3
    isKey := !isApp && !isMacro
    lblSends.Visible := isKey
    txtTarget.Visible := isKey
    lblAppPath.Visible := isApp
    editAppPath.Visible := isApp
    btnBrowseApp.Visible := isApp
    lblAppArgs.Visible := isApp
    editAppArgs.Visible := isApp
    lblMacroInfo.Visible := isMacro
    btnEditMacro.Visible := isMacro
    ; Only "Launch App" needs the extra Arguments row above Trigger - shift
    ; everything from Trigger down to make room for it (or reclaim the space
    ; when leaving Launch App), rather than reserving it permanently.
    if isApp && !actionAreaExpanded {
        ReflowActionAreaForType(appExtraRowShift)
        actionAreaExpanded := true
    } else if !isApp && actionAreaExpanded {
        ReflowActionAreaForType(-appExtraRowShift)
        actionAreaExpanded := false
    }
}
OnActionTypeChange()

; Run mode governs WHEN/how often a mapping's action fires (see
; StartRepeat/StopRepeat/ToggleRepeat and OnButtonDown/OnButtonUp). The
; press/short/long Trigger distinction only makes sense for a single-shot
; action, so it's hidden (and reset) for the other two modes.
OnRunModeChange(*) {
    isSingle := ddlRunMode.Value = 1
    lblRepeatMs.Visible := !isSingle
    edRepeatMs.Visible := !isSingle
    ddlPressType.Visible := isSingle
    if !isSingle
        ddlPressType.Choose(DdlIndexFromPressType("short"))
}
OnRunModeChange()

; ddlPressType index <-> stored pressType string
; ("press"/"long"/"short"/"release"). Centralized here so the dropdown's
; item order only has to agree with itself, not be duplicated at every
; call site.
PressTypeFromDdlIndex(idx) {
    return idx = 2 ? "press" : (idx = 3 ? "long" : (idx = 4 ? "release" : "short"))
}
DdlIndexFromPressType(pt) {
    return pt = "press" ? 2 : (pt = "long" ? 3 : (pt = "release" ? 4 : 1))
}

OnEditMacroClick(*) {
    global currentMacroSteps
    OpenMacroEditor(currentMacroSteps, SaveMacroStepsFromMainEditor)
}

SaveMacroStepsFromMainEditor(steps) {
    global currentMacroSteps
    currentMacroSteps := steps
    UpdateMacroInfoLabel()
}

UpdateMacroInfoLabel() {
    global currentMacroSteps
    lblMacroInfo.Value := "Macro: " currentMacroSteps.Length " step(s)"
}

BrowseForAppInto(editCtrl) {
    file := FileSelect(, , "Select application or file", "Executables (*.exe)")
    if file != ""
        editCtrl.Value := file
}

ShowGui() {
    g.Show()
}

; ---------------- Capture logic (source button) ----------------
SetCaptureRawMode(val) {
    global captureRawMode
    captureRawMode := !!val
}

OnCaptureKey(ihObj, VK, SC) {
    global capturedSC, lastCaptureKind
    ihObj.Stop()
    capturedSC := SC
    lastCaptureKind := "sc"
    scName := Format("SC{:03X}", SC)
    vkHex := Format("0x{:X}", VK)
    txtCaptureStatus.Value := "Captured " scName " (VK:" vkHex ")"
    ResumeButtonHotkeysIfNeeded()
}

; Resumes the button hotkeys suspended by StartCapture, if they currently
; are. Safe to call any time (e.g. even if nothing is suspended).
ResumeButtonHotkeysIfNeeded() {
    global captureSuspended
    if captureSuspended {
        Suspend(0)
        captureSuspended := false
    }
}

; Stops a still-pending "Learn a button" capture and un-suspends button
; hotkeys if needed - called when the main window closes/hides mid-capture,
; so suspend state never gets stuck on if the user abandons a capture.
CancelPendingButtonCapture() {
    global captureHook
    if IsObject(captureHook) {
        try captureHook.Stop()
        captureHook := ""
    }
    ResumeButtonHotkeysIfNeeded()
}

StartCapture(*) {
    global captureRawMode, rawCaptureArmed, captureHook, captureSuspended
    ; Cancel/clean up any previous still-pending capture first (covers
    ; re-clicking Capture, or switching the raw-HID checkbox mid-wait).
    if IsObject(captureHook) {
        try captureHook.Stop()
        captureHook := ""
    }
    ResumeButtonHotkeysIfNeeded()
    if captureRawMode {
        rawCaptureArmed := false   ; make sure it's off while we wait out the click
        txtCaptureStatus.Value := "Get ready... (waiting for your click to finish)"
        SetTimer(ArmRawCapture, -600)   ; one-shot, 600ms delay - avoids capturing
        return                          ; the mouse click on this button itself
    }
    ; Suspend every registered button hotkey while we wait for a press. A
    ; remote button that's already mapped and enabled (in Default OR any
    ; other profile) has a real Hotkey() registered for its scancode - AHK's
    ; hotkey engine consumes a matching non-passive hotkey at the hook level
    ; before a plain InputHook (like this capture) ever sees it. Without
    ; suspending, pressing an already-mapped button here would both silently
    ; re-fire its existing action and never register as "captured". Suspend
    ; doesn't touch each hotkey's individual On/Off state - it just pauses
    ; the whole engine - so ResumeButtonHotkeysIfNeeded() below restores
    ; everything exactly as it was.
    Suspend(1)
    captureSuspended := true
    txtCaptureStatus.Value := "Waiting for button press..."
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnCaptureKey
    ih.OnKeyUp := (*) => {}
    ih.Start()
    captureHook := ih
}

ArmRawCapture() {
    global rawCaptureArmed
    rawCaptureArmed := true
    txtCaptureStatus.Value := "Waiting for button press (raw HID)..."
}

; ---------------- Capture logic (target key/combo) ----------------
; Accepts ANY key, including ones the built-in Hotkey control refuses
; (Space, Enter, Tab, Win alone, etc.). Modifier state is tracked from the
; capture hook's own KeyDown/KeyUp events (targetHeldMods below) rather than
; polled from GetKeyState - GetKeyState reflects live OS state, which can be
; a step ahead of or behind the exact sequence of events our hook has
; delivered so far, and with 2+ modifiers that gap occasionally made two
; key-up events both look like "the last modifier just released" (see
; OnTargetKeyUp). Tracking our own set of held modifiers instead means the
; logic only ever depends on events we've actually seen, in the order we saw
; them - no polling, no race.
IsModifierVK(vk) {
    return vk = 0x10 || vk = 0x11 || vk = 0x12 || vk = 0x5B || vk = 0x5C
        || (vk >= 0xA0 && vk <= 0xA5)
}

; VK -> prefix char, for building modStr from whatever's in targetHeldMods.
ModPrefixForVK(vk) {
    if (vk = 0x10 || vk = 0xA0 || vk = 0xA1)          ; VK_SHIFT / LSHIFT / RSHIFT
        return "+"
    if (vk = 0x11 || vk = 0xA2 || vk = 0xA3)          ; VK_CONTROL / LCONTROL / RCONTROL
        return "^"
    if (vk = 0x12 || vk = 0xA4 || vk = 0xA5)          ; VK_MENU / LMENU / RMENU
        return "!"
    if (vk = 0x5B || vk = 0x5C)                       ; LWIN / RWIN
        return "#"
    return ""
}

FormatSendKey(keyName) {
    if StrLen(keyName) = 1 {
        if InStr("^!+#{}", keyName)
            return "{" keyName "}"
        return keyName
    }
    return "{" keyName "}"
}

; Friendlier label for a handful of key names GetKeyName returns that read
; oddly on their own (the left/right variants, mainly) - everything else is
; shown exactly as GetKeyName gave it (e.g. "F5", "Enter", "PrintScreen").
KeyDisplayName(keyName) {
    static names := Map(
        "LWin", "Win", "RWin", "Win",
        "LControl", "Ctrl", "RControl", "Ctrl", "Control", "Ctrl",
        "LShift", "Shift", "RShift", "Shift",
        "LAlt", "Alt", "RAlt", "Alt")
    return names.Has(keyName) ? names[keyName] : keyName
}

; Converts the raw AHK Send string we actually store/send (e.g. "^+u",
; "#", "{F5}") into a friendly label for the Sends field (e.g. "Ctrl+Shift+U",
; "Win", "F5"). Purely cosmetic - targetSendString/m.target keep the raw
; AHK format everywhere else (saving, Test Send, etc.); only what the field
; displays goes through this.
HumanizeSendKey(sendStr) {
    if sendStr = ""
        return ""
    modNames := []
    i := 1
    len := StrLen(sendStr)
    while i <= len {
        c := SubStr(sendStr, i, 1)
        if c = "^"
            modNames.Push("Ctrl"), i++
        else if c = "!"
            modNames.Push("Alt"), i++
        else if c = "+"
            modNames.Push("Shift"), i++
        else if c = "#"
            modNames.Push("Win"), i++
        else
            break
    }
    rest := SubStr(sendStr, i)
    keyLabel := ""
    if SubStr(rest, 1, 1) = "{" && SubStr(rest, -1) = "}"
        keyLabel := KeyDisplayName(SubStr(rest, 2, StrLen(rest) - 2))
    else if rest != ""
        keyLabel := StrUpper(rest)   ; bare literal char, e.g. "u" -> "U"; digits/symbols unaffected
    parts := modNames
    if keyLabel != ""
        parts.Push(keyLabel)
    label := ""
    for idx, p in parts
        label .= (idx = 1 ? "" : "+") p
    return label
}

FinalizeTarget(modStr, keyName) {
    ; NOTE: deliberately does NOT stop/clear targetCaptureHook - the hook is
    ; meant to keep running and keep reporting new keys for as long as the
    ; Sends field has focus. See StartTargetCapture/StopTargetCapture.
    global targetSendString
    targetSendString := modStr FormatSendKey(keyName)
    txtTarget.Value := HumanizeSendKey(targetSendString)
    txtCaptureStatus.Value := "Captured target key: " HumanizeSendKey(targetSendString) " (still listening - press another key to change it, or click away to stop)"
}

; targetHeldMods: VK -> true for every modifier key currently down, as seen
; by THIS hook (not polled from the OS - see note above). targetComboFired
; is set the instant a non-modifier key finalizes a combo (Ctrl+Shift+U,
; etc.) and cleared once targetHeldMods empties out again. Lets
; OnTargetKeyUp tell "user is releasing the modifiers that were part of the
; combo I just captured" (ignore) apart from "user tapped a bare modifier as
; the whole target" (capture it) - without this, releasing Ctrl after
; Ctrl+C would overwrite "^c" with "Ctrl".
targetHeldMods := Map()
targetComboFired := false

; Builds a canonical ^!+# prefix string from a heldMods map (VK -> true),
; in AHK's usual Ctrl/Alt/Shift/Win order - regardless of the order the
; modifiers were actually pressed in. Shared by every key/combo capture
; session (the main Sends field, the macro step editor's Key/Combo field).
BuildModStrFromHeld(heldMods) {
    hasCtrl := false, hasAlt := false, hasShift := false, hasWin := false
    for vk in heldMods {
        switch ModPrefixForVK(vk) {
            case "^": hasCtrl := true
            case "!": hasAlt := true
            case "+": hasShift := true
            case "#": hasWin := true
        }
    }
    modStr := ""
    if hasCtrl
        modStr .= "^"
    if hasAlt
        modStr .= "!"
    if hasShift
        modStr .= "+"
    if hasWin
        modStr .= "#"
    return modStr
}

OnTargetKeyDown(ihObj, VK, SC) {
    global targetHeldMods, targetComboFired
    if IsModifierVK(VK) {
        targetHeldMods[VK] := true
        return   ; keep waiting - this might just be a modifier being held
    }
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    FinalizeTarget(BuildModStrFromHeld(targetHeldMods), keyName)
    targetComboFired := true
    ; No ihObj.Stop() here - the same hook stays armed so the next keypress
    ; (while the field still has focus) re-captures and overwrites this one.
}

OnTargetKeyUp(ihObj, VK, SC) {
    global targetHeldMods, targetComboFired
    if !IsModifierVK(VK)
        return
    targetHeldMods.Delete(VK)
    allModsUp := (targetHeldMods.Count = 0)
    if targetComboFired {
        ; A non-modifier already finalized this gesture. Every modifier-up
        ; from here out is just the tail end of releasing that combo, never
        ; a trigger to finalize something new - we only use it to notice the
        ; gesture is fully over and reset targetComboFired for next time.
        if allModsUp
            targetComboFired := false
        return
    }
    ; No non-modifier fired yet this gesture - this might be a bare modifier
    ; used as the whole target (e.g. Win alone). Only finalize once every
    ; modifier we saw go down has come back up.
    if !allModsUp
        return
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    FinalizeTarget("", keyName)
    ; Hook stays armed - see note in OnTargetKeyDown.
}

; Fires automatically when the Sends field gets focus (click or Tab) - there's
; no separate "Capture Key" button anymore. targetCaptureHook holds the
; currently-listening InputHook (if any) so that refocusing the field while a
; previous capture never completed cleanly stops it first, instead of leaving
; two hooks racing to catch the same keypress. Once started, the hook is left
; running (see FinalizeTarget) so every subsequent keypress while the field
; has focus re-captures and overwrites the target; StopTargetCapture (bound
; to the field's LoseFocus event) is what actually shuts it down.
targetCaptureHook := ""
StartTargetCapture(*) {
    global targetCaptureHook, targetComboFired, targetHeldMods
    if IsObject(targetCaptureHook) {
        try targetCaptureHook.Stop()
    }
    targetComboFired := false
    targetHeldMods := Map()
    txtTarget.Value := ""
    txtCaptureStatus.Value := "Waiting for target key/combo... (press it now, e.g. Space, Win, Ctrl+Alt+S)"
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnTargetKeyDown
    ih.OnKeyUp := OnTargetKeyUp
    ih.Start()
    targetCaptureHook := ih
}

; Bound to the Sends field's LoseFocus event - ends the listening session
; started by StartTargetCapture. If the field lost focus without ever
; capturing a key this time (e.g. clicked in and straight back out), restore
; whatever target value was last committed instead of leaving the field blank.
StopTargetCapture(*) {
    global targetCaptureHook, targetSendString
    if IsObject(targetCaptureHook) {
        try targetCaptureHook.Stop()
        targetCaptureHook := ""
    }
    txtTarget.Value := HumanizeSendKey(targetSendString)
    if targetSendString != ""
        txtCaptureStatus.Value := "Captured target key: " HumanizeSendKey(targetSendString)
}

; ---------------- Raw HID Sniffer ----------------
; Uses the Windows Raw Input API to see HID reports the standard keyboard
; hook can't - e.g. Consumer Control / vendor-defined usage pages that
; Windows never translates into an actual keystroke. Diagnostic only:
; it does not create mappings by itself, but tells you what a "dead"
; button is actually sending so you know what you're dealing with.
; Assumes 64-bit AutoHotkey (the current default installer).
RIDEV_INPUTSINK := 0x00000100
rawSniffing := false
gRaw := ""
lstRawLog := ""

OpenRawSniffer(*) {
    global gRaw, lstRawLog
    if IsObject(gRaw) {
        gRaw.Show()
        return
    }
    gRaw := Gui("+AlwaysOnTop", "Raw HID Sniffer")
    gRaw.OnEvent("Close", (*) => gRaw.Hide())
    gRaw.SetFont("s9", "Consolas")
    gRaw.Add("Text", "w600", "Click Start, then press the remote button. Raw reports from ALL connected HID collections (keyboard, consumer control, vendor-defined, etc.) are logged below.")
    btnStart := gRaw.Add("Button", "w130", "Start Sniffing")
    btnStart.OnEvent("Click", (*) => ToggleSniffing(btnStart))
    btnClear := gRaw.Add("Button", "x+10 w100", "Clear Log")
    btnClear.OnEvent("Click", ClearRawLog)
    btnMapSelected := gRaw.Add("Button", "x+10 w170", "Map Selected to Key...")
    btnMapSelected.OnEvent("Click", MapSelectedRawLine)
    lstRawLog := gRaw.Add("ListBox", "x10 y+10 w600 h350")
    gRaw.Show()
}

ClearRawLog(*) {
    global g_rawLogCount, g_rawLogData
    lstRawLog.Delete()
    g_rawLogCount := 0
    g_rawLogData := []
}

ToggleSniffing(btnStart) {
    global rawSniffing, g_rawLogCount, g_rawLogData
    if !rawSniffing {
        okCount := RegisterAllRawInputDevices()
        if !okCount {
            MsgBox("Could not register any raw input devices.`nDeviceCount: " g_lastDeviceCount " EntryCount: " g_lastEntryCount, "Error", "Icon!")
            return
        }
        if IsObject(lstRawLog) {
            for line in g_regLog {
                lstRawLog.Add([line])
                g_rawLogData.Push("")
                g_rawLogCount++
            }
        }
        rawSniffing := true
        btnStart.Text := "Stop Sniffing"
    } else {
        rawSniffing := false
        btnStart.Text := "Start Sniffing"
    }
}

global g_lastDeviceCount := 0
global g_lastEntryCount := 0
global g_regLog := []
global g_rawLogCount := 0
global g_rawLogData := []

RegisterAllRawInputDevices() {
    global g_lastDeviceCount, g_lastEntryCount, g_regLog
    g_regLog := []
    hwnd := g.Hwnd
    count := 0
    DllCall("GetRawInputDeviceList", "ptr", 0, "uint*", &count, "uint", 16, "int")
    g_lastDeviceCount := count
    if count = 0
        return 0
    listBuf := Buffer(count * 16, 0)
    got := DllCall("GetRawInputDeviceList", "ptr", listBuf, "uint*", &count, "uint", 16, "int")
    if got = -1
        return 0

    seen := Map()
    entries := []
    loop count {
        off := (A_Index - 1) * 16
        hDevice := NumGet(listBuf, off, "Ptr")
        dwType := NumGet(listBuf, off + 8, "UInt")
        if dwType = 0   ; skip mice
            continue
        info := GetRawDeviceInfo(hDevice)
        if !info
            continue
        if info.usagePage = 0x01 && info.usage = 0x06 {
            ; Standard keyboard TLC. We don't need raw delivery for this -
            ; InputHook/Hotkey already capture real keyboard presses via the
            ; low-level hook with no focus dependency. Registering it for
            ; raw input turned out to be what broke normal keyboard capture
            ; while our own window had focus, so skip it entirely.
            continue
        }
        k := info.usagePage "_" info.usage
        if seen.Has(k)
            continue
        seen[k] := true
        entries.Push(info)
    }
    g_lastEntryCount := entries.Length
    if entries.Length = 0
        return 0

    ; Register ONE device at a time. RegisterRawInputDevices is all-or-nothing
    ; for the whole array it's given, so a single unsupported usage page/usage
    ; (some vendor-defined or virtual HID collections report ones Windows
    ; rejects) would otherwise silently block every other device too.
    okCount := 0
    for e in entries {
        rid := Buffer(16, 0)
        NumPut("UShort", e.usagePage, rid, 0)
        NumPut("UShort", e.usage, rid, 2)
        NumPut("UInt", RIDEV_INPUTSINK, rid, 4)
        NumPut("Ptr", hwnd, rid, 8)
        ok := DllCall("RegisterRawInputDevices", "ptr", rid, "uint", 1, "uint", 16, "int")
        tag := Format("Page:0x{:X} Usage:0x{:X}", e.usagePage, e.usage)
        if ok {
            okCount++
            g_regLog.Push(FormatTime(A_Now, "HH:mm:ss") " [Registered] " tag)
        } else {
            g_regLog.Push(FormatTime(A_Now, "HH:mm:ss") " [FAILED] " tag " LastError:" A_LastError)
        }
    }
    return okCount
}

GetRawDeviceInfo(hDevice) {
    size := 32
    buf := Buffer(size, 0)
    NumPut("UInt", size, buf, 0)
    pcb := size
    r := DllCall("GetRawInputDeviceInfo", "ptr", hDevice, "uint", 0x2000000B, "ptr", buf, "uint*", &pcb, "int")
    if r = -1
        return false
    dwType := NumGet(buf, 4, "UInt")
    if dwType != 2   ; not HID -> standard keyboard TLC per spec
        return {usagePage: 0x01, usage: 0x06}
    return {usagePage: NumGet(buf, 20, "UShort"), usage: NumGet(buf, 22, "UShort")}
}

OnRawInput(wParam, lParam, msg, hwnd) {
    global rawSniffing, lstRawLog, g_rawLogCount, g_rawLogData, mapOrder, mappings, masterEnabled
    global rawCaptureArmed, capturedRawPage, capturedRawBytesHex, lastCaptureKind, capturedSC
    global activeProfileName
    cbHeader := 8 + (A_PtrSize * 2)
    size := 0
    DllCall("GetRawInputData", "ptr", lParam, "uint", 0x10000003, "ptr", 0, "uint*", &size, "uint", cbHeader, "int")
    if size = 0
        return
    buf := Buffer(size, 0)
    got := DllCall("GetRawInputData", "ptr", lParam, "uint", 0x10000003, "ptr", buf, "uint*", &size, "uint", cbHeader, "int")
    if got != size
        return
    dwType := NumGet(buf, 0, "UInt")
    hDevice := NumGet(buf, 8, "Ptr")
    line := ""
    rowData := ""
    if dwType = 1 {
        base := cbHeader
        makeCode := NumGet(buf, base, "UShort")
        flags := NumGet(buf, base + 2, "UShort")
        vkey := NumGet(buf, base + 6, "UShort")
        if flags & 1   ; key-up, skip to reduce noise
            return
        line := Format("[Keyboard] MakeCode:0x{:X} VKey:0x{:X} Flags:0x{:X}", makeCode, vkey, flags)
    } else if dwType = 2 {
        base := cbHeader
        dwSizeHid := NumGet(buf, base, "UInt")
        dataOff := base + 8
        info := GetRawDeviceInfo(hDevice)
        bytes := ""
        loop dwSizeHid
            bytes .= Format("{:02X} ", NumGet(buf, dataOff + A_Index - 1, "UChar"))
        bytesNorm := StrReplace(Trim(bytes), " ", "")
        pageStr := info ? Format("Page:0x{:X} Usage:0x{:X}", info.usagePage, info.usage) : "Page:?"
        line := "[HID] " pageStr " Bytes: " Trim(bytes)
        if info {
            rowData := {page: info.usagePage, bytesHex: bytesNorm}
            if rawCaptureArmed {
                ; Fulfill a capture requested from the main window's
                ; "Capture raw HID event" checkbox instead of matching
                ; against existing mappings.
                rawCaptureArmed := false
                capturedRawPage := info.usagePage
                capturedRawBytesHex := bytesNorm
                lastCaptureKind := "raw"
                capturedSC := 0
                if IsObject(txtCaptureStatus)
                    txtCaptureStatus.Value := Format("Captured raw HID event: Page:0x{:X} Bytes:{}", info.usagePage, bytesNorm)
                if rawSniffing && IsObject(lstRawLog) {
                    lstRawLog.Add([FormatTime(A_Now, "HH:mm:ss") " " line])
                    g_rawLogData.Push(rowData)
                    g_rawLogCount++
                    lstRawLog.Choose(g_rawLogCount)
                }
                return
            }
            ; Raw-report mappings: for buttons with no legacy VK/scancode
            ; (e.g. Consumer "Voice Command"), match on the exact raw
            ; report bytes and Send() directly - no OS hotkey involved.
            rawButtonKey := "RAW_" Format("{:X}", info.usagePage) "_" bytesNorm
            effProfile := EffectiveProfileForButton(rawButtonKey, "raw")
            for key in mapOrder {
                m := mappings[key]
                if (m.HasOwnProp("kind") ? m.kind : "sc") != "raw"
                    continue
                if (m.HasOwnProp("profile") ? m.profile : "Default") != effProfile
                    continue
                if m.page = info.usagePage && m.bytesHex = bytesNorm {
                    if masterEnabled && m.enabled
                        FireMapping(m)
                    ; no break - a raw event can have multiple mappings attached
                }
            }
        }
    } else {
        return
    }
    if rawSniffing && IsObject(lstRawLog) {
        lstRawLog.Add([FormatTime(A_Now, "HH:mm:ss") " " line])
        g_rawLogData.Push(rowData)
        g_rawLogCount++
        lstRawLog.Choose(g_rawLogCount)
    }
}
OnMessage(0x00FF, OnRawInput)

; ---------------- Map a raw HID line to a key ----------------
global rawMapTargetString := ""
global rawMacroSteps := []

MapSelectedRawLine(*) {
    idx := lstRawLog.Value
    if !idx || idx > g_rawLogData.Length {
        MsgBox("Select a raw [HID] line from the log first.", "Nothing selected", "Icon!")
        return
    }
    data := g_rawLogData[idx]
    if !IsObject(data) {
        MsgBox("That line isn't a mappable raw HID event. Select an [HID] line (not a status or keyboard line).", "Can't map this", "Icon!")
        return
    }
    OpenRawMapDialog(data.page, data.bytesHex)
}

OpenRawMapDialog(page, bytesHex) {
    global rawMapTargetString, rawMacroSteps
    rawMapTargetString := ""
    rawMacroSteps := []
    gm := Gui("+AlwaysOnTop +Owner" gRaw.Hwnd, "Map Raw HID Event")
    gm.SetFont("s10", "Segoe UI")
    gm.Add("Text", "w420", Format("Event: Page:0x{:X} Bytes:{}", page, bytesHex))
    gm.Add("Text", "xm y+15", "Description:")
    edDesc := gm.Add("Edit", "x+10 w180")
    gm.Add("Text", "x+15", "Action:")
    ddlRawAction := gm.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App", "Macro"])

    lblRawSends := gm.Add("Text", "xm y+15", "Sends:")
    edTarget := gm.Add("Edit", "x+10 w120 ReadOnly")
    btnCap := gm.Add("Button", "x+10 w110", "Capture Key")
    btnCap.OnEvent("Click", (*) => StartRawMapTargetCapture(edTarget))

    lblRawAppPath := gm.Add("Text", "xm y+12", "App/File path:")
    edRawAppPath := gm.Add("Edit", "x+10 w260")
    btnRawBrowse := gm.Add("Button", "x+8 w80", "Browse...")
    btnRawBrowse.OnEvent("Click", (*) => BrowseForAppInto(edRawAppPath))

    lblRawAppArgs := gm.Add("Text", "xm y+10", "Arguments (optional):")
    edRawAppArgs := gm.Add("Edit", "x+10 w300")

    lblRawMacroInfo := gm.Add("Text", "xm y+12", "Macro: 0 step(s)")
    btnRawEditMacro := gm.Add("Button", "x+10 w120", "Edit Macro...")
    btnRawEditMacro.OnEvent("Click", (*) => OpenMacroEditor(rawMacroSteps, (steps) => SetRawMacroSteps(steps, lblRawMacroInfo)))

    ; Raw HID mappings only support run mode "single" (see the note near
    ; FireButtonMappings/SaveRawMapping) - no run-mode UI here.
    ToggleRawActionControls(*) {
        v := ddlRawAction.Value
        isApp := v = 2
        isMacro := v = 3
        isKey := !isApp && !isMacro
        lblRawSends.Visible := isKey
        edTarget.Visible := isKey
        btnCap.Visible := isKey
        lblRawAppPath.Visible := isApp
        edRawAppPath.Visible := isApp
        btnRawBrowse.Visible := isApp
        lblRawAppArgs.Visible := isApp
        edRawAppArgs.Visible := isApp
        lblRawMacroInfo.Visible := isMacro
        btnRawEditMacro.Visible := isMacro
    }
    ddlRawAction.OnEvent("Change", ToggleRawActionControls)
    ToggleRawActionControls()

    btnSave := gm.Add("Button", "xm y+20 w100", "Save")
    btnSave.OnEvent("Click", (*) => SaveRawMapping(page, bytesHex, edDesc.Value, ddlRawAction.Value, edRawAppPath.Value, edRawAppArgs.Value, gm))
    btnCancel := gm.Add("Button", "x+10 w100", "Cancel")
    btnCancel.OnEvent("Click", (*) => gm.Destroy())
    gm.OnEvent("Close", (*) => gm.Destroy())
    gm.Show()
}

SetRawMacroSteps(steps, lbl) {
    global rawMacroSteps
    rawMacroSteps := steps
    lbl.Value := "Macro: " steps.Length " step(s)"
}

StartRawMapTargetCapture(edTarget) {
    edTarget.Value := "Press a key..."
    edTarget.Focus()
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := (ihObj, VK, SC) => RawMapTargetKeyDown(ihObj, VK, SC, edTarget)
    ih.OnKeyUp := (ihObj, VK, SC) => RawMapTargetKeyUp(ihObj, VK, SC, edTarget)
    ih.Start()
}

RawMapTargetKeyDown(ihObj, VK, SC, edTarget) {
    global rawMapTargetString
    if IsModifierVK(VK)
        return
    ihObj.Stop()
    modStr := ""
    if GetKeyState("Ctrl", "P")
        modStr .= "^"
    if GetKeyState("Alt", "P")
        modStr .= "!"
    if GetKeyState("Shift", "P")
        modStr .= "+"
    if GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        modStr .= "#"
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    rawMapTargetString := modStr FormatSendKey(keyName)
    edTarget.Value := rawMapTargetString
}

RawMapTargetKeyUp(ihObj, VK, SC, edTarget) {
    global rawMapTargetString
    if !IsModifierVK(VK)
        return
    if GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P") || GetKeyState("Shift", "P")
        || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        return
    ihObj.Stop()
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    rawMapTargetString := keyName
    edTarget.Value := rawMapTargetString
}

SaveRawMapping(page, bytesHex, desc, actionVal, appPath, appArgs, gm) {
    global mappings, mapOrder, rawMapTargetString, editingProfileName, rawMacroSteps
    isApp := actionVal = 2
    isMacro := actionVal = 3
    if isApp {
        if appPath = "" {
            MsgBox("Enter an app/file path first (or use Browse...).", "Missing target", "Icon!")
            return
        }
    } else if isMacro {
        if rawMacroSteps.Length = 0 {
            MsgBox("Add at least one step with Edit Macro... first.", "Empty macro", "Icon!")
            return
        }
    } else {
        if rawMapTargetString = "" {
            MsgBox("Capture a key/combo to send first.", "Missing target", "Icon!")
            return
        }
    }
    buttonKey := "RAW_" Format("{:X}", page) "_" bytesHex
    key := GenerateId(editingProfileName, buttonKey)   ; adds a new mapping rather than overwriting one already on this event
    mapOrder.Push(key)
    dispId := SubStr(key, StrLen(editingProfileName) + 3)   ; strip "<profile>::" prefix for a friendlier default description
    finalDesc := desc != "" ? desc : Format("Raw 0x{:X} {} ({})", page, bytesHex, dispId)
    if isApp
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "app", page: page, bytesHex: bytesHex, desc: finalDesc, target: appPath, appArgs: appArgs, macroSteps: [], enabled: true, pressType: "short", runMode: "single", repeatMs: 100}
    else if isMacro {
        stepsCopy := []
        for s in rawMacroSteps
            stepsCopy.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "macro", page: page, bytesHex: bytesHex, desc: finalDesc, target: "", appArgs: "", macroSteps: stepsCopy, enabled: true, pressType: "short", runMode: "single", repeatMs: 100}
    } else
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "key", page: page, bytesHex: bytesHex, desc: finalDesc, target: rawMapTargetString, appArgs: "", macroSteps: [], enabled: true, pressType: "short", runMode: "single", repeatMs: 100}
    SaveMappings()
    RefreshList()
    gm.Destroy()
    txtStatus.Value := "Saved raw mapping for " dispId "."
}

; ---------------- Macro editor ----------------
; A macro is an ordered list of steps, each one a Send (key/combo), a Launch
; App, or a pure Wait, with an optional delay after it before the next step
; runs. This dialog is shared by the main form (editing a scancode mapping's
; macro) and the Raw HID map dialog - the caller passes in the steps to
; start from and a callback that receives the finished array back, so this
; code doesn't need to know which context invoked it.
macroEditSteps := []
gMacro := ""
lvMacroSteps := ""
macroStepCapturedTarget := ""

; ---- Record Macro state ----
; Lets the user press real keys on their keyboard instead of adding each
; step by hand: while armed, every key/combo that comes through is appended
; as its own "key" step, and the previous step's delayAfterMs is backfilled
; with the actual gap (ms) between it and this new one, so played back the
; macro reproduces the timing it was recorded with. See
; StartMacroRecordingFlow/RecordMacroKeyDown/RecordMacroKeyUp/CommitRecordedStep.
macroRecording := false
recordHook := ""
recordHeldMods := Map()
recordComboFired := false
recordLastEventTick := 0
macroStepControls := []

OpenMacroEditor(initialSteps, onSave) {
    global gMacro, macroEditSteps, lvMacroSteps
    global macroRecording, recordHook, recordHeldMods, recordComboFired, recordLastEventTick
    global macroStepControls
    macroEditSteps := []
    macroRecording := false
    recordHook := ""
    recordHeldMods := Map()
    recordComboFired := false
    recordLastEventTick := 0
    for s in initialSteps
        macroEditSteps.Push({type: s.type, target: s.HasOwnProp("target") ? s.target : "", args: s.HasOwnProp("args") ? s.args : "", delayAfterMs: s.HasOwnProp("delayAfterMs") ? s.delayAfterMs : 0})

    gMacro := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Edit Macro")
    gMacro.SetFont("s10", "Segoe UI")
    gMacro.Add("Text", "w560", "Steps run top to bottom, in order, each time this macro fires. Double-click a step's Delay after value to change it.")

    lvMacroSteps := gMacro.Add("ListView", "xm y+10 w560 h200", ["#", "Type", "Target", "Delay after (ms)"])
    lvMacroSteps.ModifyCol(1, 30)
    lvMacroSteps.ModifyCol(2, 70)
    lvMacroSteps.ModifyCol(3, 350)
    lvMacroSteps.ModifyCol(4, 100)
    lvMacroSteps.OnEvent("DoubleClick", OnMacroStepDoubleClick)
    RefreshMacroStepsList()

    ; Add Step / Move Up / Move Down / Remove sit in a single horizontal
    ; row, to the left of the step-type radios. No width is specified for
    ; these buttons, so each auto-sizes to fit its own label instead of
    ; using a fixed/shared width.
    btnAddStep := gMacro.Add("Button", "xm y+12", "Add Step")
    btnMoveUp := gMacro.Add("Button", "x+2", "Move Up")
    btnMoveDown := gMacro.Add("Button", "x+2", "Move Down")
    btnRemoveStep := gMacro.Add("Button", "x+2", "Remove")
    btnAddStep.OnEvent("Click", (*) => AddMacroStep(GetStepTypeValue(), edStepKey, edStepApp, edStepArgs, edStepDelay))
    btnRemoveStep.OnEvent("Click", (*) => RemoveMacroStep())
    btnMoveUp.OnEvent("Click", (*) => MoveMacroStep(-1))
    btnMoveDown.OnEvent("Click", (*) => MoveMacroStep(1))

    ; Push-styled (BS_PUSHLIKE, "+0x8") radio buttons: look and click like a
    ; row of buttons, but behave as a mutually-exclusive group like the
    ; DropDownList this replaces did. GetStepTypeValue() below reads whichever
    ; one is checked, standing in for the old ddlStepType.Value. There's no
    ; "Wait only" option here - that's what the Insert Delay button is for
    ; (see below), which adds a standalone wait step directly.
    radStepKey := gMacro.Add("Radio", "x+15 w140 +0x8 Group Checked", "Send Key/Combo")
    radStepApp := gMacro.Add("Radio", "x+3 w110 +0x8", "Launch App")

    GetStepTypeValue(*) {
        return radStepKey.Value ? 1 : 2
    }

    lblStepKey := gMacro.Add("Text", "xm y+15", "Key/Combo:")
    edStepKey := gMacro.Add("Edit", "x+10 w214 ReadOnly Background0xFFFFFF")
    ; Same behavior as the main Sends field: clicking/tabbing into this
    ; field starts capture directly (no separate "Capture Key" button), and
    ; it keeps listening and re-capturing on every subsequent keypress for
    ; as long as it has focus - see StartMacroStepKeyCapture/
    ; StopMacroStepKeyCapture.
    edStepKey.OnEvent("Focus", (*) => StartMacroStepKeyCapture(edStepKey))
    edStepKey.OnEvent("LoseFocus", (*) => StopMacroStepKeyCapture(edStepKey))
    ; Key/Combo and App path+args are two alternative views of the same row
    ; - only one is visible at a time (see ToggleStepTypeControls) - so both
    ; start at this same anchor row instead of always stacking on top of one
    ; another regardless of visibility, which used to leave a gap below
    ; Key/Combo (only needs this one row) and above App path (which needs
    ; this row plus Arguments below it, sized for both rows either way).
    stepRow1X := stepRow1Y := stepRow1H := 0
    lblStepKey.GetPos(&stepRow1X, &stepRow1Y, , &stepRow1H)

    lblStepApp := gMacro.Add("Text", "xm y" stepRow1Y, "App/File path:")
    edStepApp := gMacro.Add("Edit", "x+10 w260")
    btnStepBrowse := gMacro.Add("Button", "x+8 w80", "Browse...")
    btnStepBrowse.OnEvent("Click", (*) => BrowseForAppInto(edStepApp))

    lblStepArgs := gMacro.Add("Text", "xm y+10", "Arguments (optional):")
    editStepArgsRow2Y := editStepArgsRow2H := 0
    edStepArgs := gMacro.Add("Edit", "x+10 w300")
    lblStepArgs.GetPos(, &editStepArgsRow2Y)
    edStepArgs.GetPos(, , , &editStepArgsRow2H)

    ; Record Macro / Insert Delay / delay field (and Done/Cancel below them)
    ; are built at the "collapsed" one-row position (matching the default
    ; Send Key/Combo selection); ReflowStepAreaForType() shifts this whole
    ; tail down while Launch App is selected (the only type needing the
    ; extra Arguments row) and back up otherwise, instead of permanently
    ; reserving that row's space.
    btnRecordMacro := gMacro.Add("Button", "xm y" (stepRow1Y + stepRow1H + 10) " w120", "Record Macro")
    btnInsertWait := gMacro.Add("Button", "x+10 w150", "Insert Delay")
    edStepDelay := gMacro.Add("Edit", "x+10 w70", "0")
    lblStepMs := gMacro.Add("Text", "x+5", "ms")
    stepExtraRowShift := (editStepArgsRow2Y + editStepArgsRow2H) - (stepRow1Y + stepRow1H)
    stepAreaExpanded := false
    ; Shortcut: adds a standalone "wait" step using whatever's in the field
    ; right now, regardless of which step type radio is currently selected.
    btnInsertWait.OnEvent("Click", (*) => InsertWaitStep(edStepDelay))
    ; Records real keypresses as steps instead of adding them one at a time
    ; by hand - see the "Record Macro state" block up top for how timing is
    ; captured.
    lblRecordStatus := gMacro.Add("Text", "xm y+10 w400 cRed", "Recording... press keys now.")
    lblRecordStatus.Visible := false
    btnRecordMacro.OnEvent("Click", (*) => ToggleMacroRecording(btnRecordMacro, lblRecordStatus))

    ToggleStepTypeControls(*) {
        v := GetStepTypeValue()
        isKey := v = 1
        isApp := v = 2
        lblStepKey.Visible := isKey
        edStepKey.Visible := isKey
        lblStepApp.Visible := isApp
        edStepApp.Visible := isApp
        btnStepBrowse.Visible := isApp
        lblStepArgs.Visible := isApp
        edStepArgs.Visible := isApp
        if isApp && !stepAreaExpanded {
            ReflowStepAreaForType(stepExtraRowShift)
            stepAreaExpanded := true
        } else if !isApp && stepAreaExpanded {
            ReflowStepAreaForType(-stepExtraRowShift)
            stepAreaExpanded := false
        }
    }
    ; Shifts Record Macro/Insert Delay/Done/Cancel down (positive) or up
    ; (negative) by the same amount, then forces a full repaint - moving
    ; controls doesn't always make Windows redraw the area they vacated,
    ; which otherwise leaves ghosted pixels behind after a shift.
    ReflowStepAreaForType(deltaY) {
        if deltaY = 0
            return
        for ctrl in [btnRecordMacro, btnInsertWait, edStepDelay, lblStepMs, lblRecordStatus, btnDone, btnCancelM] {
            ctrl.GetPos(&cx, &cy)
            ctrl.Move(, cy + deltaY)
        }
        ; Moving the controls down (or up) doesn't grow/shrink the window
        ; itself, so without this the Launch App layout's Done/Cancel row
        ; ends up below the window's bottom edge (or, on the way back to
        ; Send Key/Combo, leaves dead space). Resize the window by the same
        ; delta so it always exactly fits whichever layout is showing.
        gMacro.GetPos(&gx, &gy, &gw, &gh)
        gMacro.Move(gx, gy, gw, gh + deltaY)
        DllCall("RedrawWindow", "ptr", gMacro.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0004 | 0x0080 | 0x0100)
    }
    radStepKey.OnEvent("Click", ToggleStepTypeControls)
    radStepApp.OnEvent("Click", ToggleStepTypeControls)

    btnDone := gMacro.Add("Button", "xm y+20 w100", "Done")
    btnDone.OnEvent("Click", (*) => FinishMacroEditor(onSave))
    btnCancelM := gMacro.Add("Button", "x+10 w100", "Cancel")
    btnCancelM.OnEvent("Click", (*) => (StopRecordingIfActive(), gMacro.Destroy()))
    gMacro.OnEvent("Close", (*) => (StopRecordingIfActive(), gMacro.Destroy()))
    ; Disabled for the duration of a recording so nothing else can add,
    ; remove, reorder, or edit steps out from under it, and so tabbing into
    ; Key/Combo or App/File path can't start a second, competing capture
    ; hook at the same time as the recording one.
    macroStepControls := [btnAddStep, btnMoveUp, btnMoveDown, btnRemoveStep,
        radStepKey, radStepApp, edStepKey, edStepApp, btnStepBrowse, edStepArgs,
        btnInsertWait, edStepDelay, btnDone, btnCancelM]
    ToggleStepTypeControls()
    gMacro.Show()
}

RefreshMacroStepsList() {
    global macroEditSteps, lvMacroSteps
    lvMacroSteps.Delete()
    for i, s in macroEditSteps {
        typeLabel := s.type = "key" ? "Key" : (s.type = "app" ? "App" : "Delay")
        if s.type = "key"
            targetLabel := HumanizeSendKey(s.target)
        else if s.type = "app"
            targetLabel := s.target (s.args != "" ? " " s.args : "")
        else
            targetLabel := "-"
        lvMacroSteps.Add(, i, typeLabel, targetLabel, s.delayAfterMs)
    }
}

; ListView cells aren't natively editable in AHK, so a double-click on any
; part of a step's row prompts for a new Delay after value instead - that's
; the only per-step field there's ever a reason to tweak after the fact
; (Type/Target come from re-adding a step, not editing this one in place).
OnMacroStepDoubleClick(ctrl, row) {
    global macroEditSteps, macroRecording
    if macroRecording
        return
    if !row || row > macroEditSteps.Length
        return
    OpenEditDelayDialog(row)
}

; A plain InputBox() isn't owned by gMacro, so it doesn't inherit gMacro's
; +AlwaysOnTop/owner relationship and can end up opening behind both the
; macro editor and the main window. Building this as its own small Gui,
; explicitly owned by gMacro (same pattern gMacro itself uses relative to
; the main window g), keeps it on top of both instead.
OpenEditDelayDialog(row) {
    global macroEditSteps, lvMacroSteps, gMacro
    step := macroEditSteps[row]
    gDelay := Gui("+AlwaysOnTop +Owner" gMacro.Hwnd, "Edit Delay")
    gDelay.SetFont("s10", "Segoe UI")
    gDelay.Add("Text", "xm y10", "Delay after this step (ms):")
    edDelayVal := gDelay.Add("Edit", "x+10 yp-3 w100 Number", String(step.delayAfterMs))
    btnOk := gDelay.Add("Button", "xm y+15 w90 Default", "OK")
    btnCancel := gDelay.Add("Button", "x+10 w90", "Cancel")
    btnOk.OnEvent("Click", (*) => CommitDelayEdit(row, edDelayVal, gDelay))
    btnCancel.OnEvent("Click", (*) => gDelay.Destroy())
    gDelay.OnEvent("Close", (*) => gDelay.Destroy())
    gDelay.Show("AutoSize")
    edDelayVal.Focus()
}

CommitDelayEdit(row, edDelayVal, gDelay) {
    global macroEditSteps, lvMacroSteps
    if edDelayVal.Value = "" || !IsInteger(edDelayVal.Value) || Integer(edDelayVal.Value) < 0 {
        MsgBox("Enter a whole number of milliseconds (0 or more).", "Invalid delay", "Icon!")
        return
    }
    macroEditSteps[row].delayAfterMs := Integer(edDelayVal.Value)
    RefreshMacroStepsList()
    lvMacroSteps.Modify(row, "Select Focus Vis")
    gDelay.Destroy()
}

; ---------------- Record Macro ----------------
ToggleMacroRecording(btn, statusText) {
    global macroRecording
    if macroRecording
        StopMacroRecording(btn, statusText)
    else
        StartMacroRecordingFlow(btn, statusText)
}

StartMacroRecordingFlow(btn, statusText) {
    global macroRecording, recordHeldMods, recordComboFired, recordLastEventTick, recordHook, macroStepControls
    macroRecording := true
    recordHeldMods := Map()
    recordComboFired := false
    ; 0 is a sentinel meaning "no prior step to backfill a delay onto yet" -
    ; see CommitRecordedStep. The first key recorded always gets delayAfterMs
    ; 0 for the same reason: there's nothing before it in this session to
    ; charge the click-to-first-keypress gap against.
    recordLastEventTick := 0
    for ctrl in macroStepControls
        ctrl.Enabled := false
    btn.Text := "Stop Recording"
    statusText.Visible := true
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := RecordMacroKeyDown
    ih.OnKeyUp := RecordMacroKeyUp
    ih.Start()
    recordHook := ih
}

StopMacroRecording(btn, statusText) {
    StopRecordingIfActive()
    btn.Text := "Record Macro"
    statusText.Visible := false
}

; Also used from Cancel/window-Close so an in-progress recording's InputHook
; never keeps running (and keeps re-enabling itself against a destroyed
; window) after the macro editor itself is gone.
StopRecordingIfActive() {
    global macroRecording, recordHook, macroStepControls
    if !macroRecording
        return
    macroRecording := false
    if IsObject(recordHook) {
        try recordHook.Stop()
        recordHook := ""
    }
    for ctrl in macroStepControls
        ctrl.Enabled := true
}

; Appends a freshly-captured key/combo as a new step and backfills the
; PREVIOUS step's delayAfterMs with the real gap since it was recorded, so
; the recorded timing lives on the step that should wait it out during
; playback rather than on the step that just fired.
CommitRecordedStep(target) {
    global macroEditSteps, recordLastEventTick, lvMacroSteps
    now := A_TickCount
    if recordLastEventTick != 0 && macroEditSteps.Length > 0
        macroEditSteps[macroEditSteps.Length].delayAfterMs := now - recordLastEventTick
    macroEditSteps.Push({type: "key", target: target, args: "", delayAfterMs: 0})
    recordLastEventTick := now
    RefreshMacroStepsList()
    lvMacroSteps.Modify(macroEditSteps.Length, "Select Focus Vis")
}

; Mirrors MacroStepKeyDown/MacroStepKeyUp's modifier-tracking state machine
; (see those for the full rationale), but commits a new step on every
; finalized key/combo instead of overwriting a single display field, so a
; whole sequence gets captured rather than just the last keystroke.
RecordMacroKeyDown(ihObj, VK, SC) {
    global recordHeldMods, recordComboFired
    if IsModifierVK(VK) {
        recordHeldMods[VK] := true
        return
    }
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    CommitRecordedStep(BuildModStrFromHeld(recordHeldMods) FormatSendKey(keyName))
    recordComboFired := true
}

RecordMacroKeyUp(ihObj, VK, SC) {
    global recordHeldMods, recordComboFired
    if !IsModifierVK(VK)
        return
    recordHeldMods.Delete(VK)
    allModsUp := (recordHeldMods.Count = 0)
    if recordComboFired {
        if allModsUp
            recordComboFired := false
        return
    }
    if !allModsUp
        return
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    CommitRecordedStep(FormatSendKey(keyName))
}

AddMacroStep(v, edStepKey, edStepApp, edStepArgs, edStepDelay) {
    global macroEditSteps, macroStepCapturedTarget, lvMacroSteps
    delayVal := IsInteger(edStepDelay.Value) ? Integer(edStepDelay.Value) : 0
    if delayVal < 0
        delayVal := 0
    if v = 1 {
        if edStepKey.Value = "" {
            MsgBox("Capture a key/combo for this step first.", "Missing target", "Icon!")
            return
        }
        newStep := {type: "key", target: macroStepCapturedTarget, args: "", delayAfterMs: delayVal}
    } else {
        if edStepApp.Value = "" {
            MsgBox("Enter an app/file path for this step first.", "Missing target", "Icon!")
            return
        }
        newStep := {type: "app", target: edStepApp.Value, args: edStepArgs.Value, delayAfterMs: delayVal}
    }
    ; With a step selected, drop the new one in right after it rather than
    ; always tacking it onto the end - matches Insert Delay/Move Up/Move
    ; Down/Remove, which all key off the current selection the same way. No
    ; selection just falls back to appending, same as before.
    row := lvMacroSteps.GetNext()
    if row {
        macroEditSteps.InsertAt(row + 1, newStep)
        insertedAt := row + 1
    } else {
        macroEditSteps.Push(newStep)
        insertedAt := macroEditSteps.Length
    }
    RefreshMacroStepsList()
    lvMacroSteps.Modify(insertedAt, "Select Focus Vis")
    macroStepCapturedTarget := ""
    edStepKey.Value := ""
    edStepApp.Value := ""
    edStepArgs.Value := ""
    edStepDelay.Value := "0"
}

; Adds a standalone wait step directly from the "Insert Delay" button,
; independent of whatever step type is currently selected in the radio
; group - see the comment where the button is created. Deliberately leaves
; the field's value in place afterward (unlike Add Step) so inserting
; several waits of the same length doesn't mean re-typing it each time.
InsertWaitStep(edStepDelay) {
    global macroEditSteps, lvMacroSteps
    delayVal := IsInteger(edStepDelay.Value) ? Integer(edStepDelay.Value) : 0
    if delayVal <= 0 {
        MsgBox("Enter a delay greater than 0ms first.", "Missing delay", "Icon!")
        return
    }
    newStep := {type: "wait", target: "", args: "", delayAfterMs: delayVal}
    ; With a step selected, drop the new delay in right after it rather than
    ; always tacking it onto the end - matches how Move Up/Move Down and
    ; Remove already key off the current selection. No selection just falls
    ; back to appending, same as before.
    row := lvMacroSteps.GetNext()
    if row {
        macroEditSteps.InsertAt(row + 1, newStep)
        insertedAt := row + 1
    } else {
        macroEditSteps.Push(newStep)
        insertedAt := macroEditSteps.Length
    }
    RefreshMacroStepsList()
    lvMacroSteps.Modify(insertedAt, "Select Focus Vis")
}

RemoveMacroStep() {
    global macroEditSteps, lvMacroSteps
    row := lvMacroSteps.GetNext()
    if !row {
        MsgBox("Select a step first.", "Nothing selected", "Icon!")
        return
    }
    macroEditSteps.RemoveAt(row)
    RefreshMacroStepsList()
}

MoveMacroStep(dir) {
    global macroEditSteps, lvMacroSteps
    row := lvMacroSteps.GetNext()
    if !row {
        MsgBox("Select a step first.", "Nothing selected", "Icon!")
        return
    }
    newRow := row + dir
    if newRow < 1 || newRow > macroEditSteps.Length
        return
    tmp := macroEditSteps[row]
    macroEditSteps[row] := macroEditSteps[newRow]
    macroEditSteps[newRow] := tmp
    RefreshMacroStepsList()
    lvMacroSteps.Modify(newRow, "Select Focus")
}

FinishMacroEditor(onSave) {
    global macroEditSteps, gMacro
    if macroEditSteps.Length = 0 {
        result := MsgBox("This macro has no steps yet. Save an empty macro anyway?", "Empty macro", "YesNo Icon!")
        if result != "Yes"
            return
    }
    stepsCopy := []
    for s in macroEditSteps
        stepsCopy.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
    onSave(stepsCopy)
    gMacro.Destroy()
}

; Captures a key/combo for one macro step, writing into that step's own Edit
; control - deliberately separate state from targetCaptureHook/targetHeldMods/
; targetComboFired/targetSendString so editing a macro step never clobbers
; the main form's own captured target. Otherwise this works exactly like the
; main Sends field (see StartTargetCapture and friends for the full
; rationale): arms on Focus, keeps listening and re-capturing on every
; subsequent keypress - including multi-modifier combos like Ctrl+Shift+U -
; for as long as the field has focus, and disarms on LoseFocus.
macroStepCaptureHook := ""
macroStepHeldMods := Map()
macroStepComboFired := false

StartMacroStepKeyCapture(edCtrl) {
    global macroStepCaptureHook, macroStepComboFired, macroStepHeldMods, macroStepCapturedTarget
    if IsObject(macroStepCaptureHook) {
        try macroStepCaptureHook.Stop()
    }
    macroStepComboFired := false
    macroStepHeldMods := Map()
    macroStepCapturedTarget := ""
    edCtrl.Value := ""
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := (ihObj, VK, SC) => MacroStepKeyDown(ihObj, VK, SC, edCtrl)
    ih.OnKeyUp := (ihObj, VK, SC) => MacroStepKeyUp(ihObj, VK, SC, edCtrl)
    ih.Start()
    macroStepCaptureHook := ih
}

; Bound to the Key/Combo field's LoseFocus event - ends the listening session
; started by StartMacroStepKeyCapture. If the field lost focus without ever
; capturing a key this time, restore whatever value was last committed
; instead of leaving the field blank.
StopMacroStepKeyCapture(edCtrl) {
    global macroStepCaptureHook, macroStepCapturedTarget
    if IsObject(macroStepCaptureHook) {
        try macroStepCaptureHook.Stop()
        macroStepCaptureHook := ""
    }
    edCtrl.Value := HumanizeSendKey(macroStepCapturedTarget)
}

MacroStepKeyDown(ihObj, VK, SC, edCtrl) {
    global macroStepHeldMods, macroStepComboFired, macroStepCapturedTarget
    if IsModifierVK(VK) {
        macroStepHeldMods[VK] := true
        return   ; keep waiting - this might just be a modifier being held
    }
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    macroStepCapturedTarget := BuildModStrFromHeld(macroStepHeldMods) FormatSendKey(keyName)
    edCtrl.Value := HumanizeSendKey(macroStepCapturedTarget)
    macroStepComboFired := true
    ; No ihObj.Stop() here - the same hook stays armed so the next keypress
    ; (while the field still has focus) re-captures and overwrites this one.
}

MacroStepKeyUp(ihObj, VK, SC, edCtrl) {
    global macroStepHeldMods, macroStepComboFired, macroStepCapturedTarget
    if !IsModifierVK(VK)
        return
    macroStepHeldMods.Delete(VK)
    allModsUp := (macroStepHeldMods.Count = 0)
    if macroStepComboFired {
        ; A non-modifier already finalized this gesture. Every modifier-up
        ; from here out is just the tail end of releasing that combo, never
        ; a trigger to finalize something new (see OnTargetKeyUp for the
        ; full race explanation this avoids).
        if allModsUp
            macroStepComboFired := false
        return
    }
    ; No non-modifier fired yet this gesture - this might be a bare modifier
    ; used as the whole target (e.g. Win alone). Only finalize once every
    ; modifier we saw go down has come back up.
    if !allModsUp
        return
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    macroStepCapturedTarget := FormatSendKey(keyName)
    edCtrl.Value := HumanizeSendKey(macroStepCapturedTarget)
    ; Hook stays armed - see note in MacroStepKeyDown.
}

; ---------------- Macro step (de)serialization ----------------
; Steps are packed into a single INI value using non-printable separators
; (Chr(1) between a step's own fields, Chr(2) between steps). Real key
; combos, app paths, and arguments essentially never contain these bytes, so
; no escaping of user-entered text is needed, unlike a printable delimiter.
MacroStepsEncode(steps) {
    out := ""
    for i, s in steps {
        if i > 1
            out .= Chr(2)
        out .= s.type Chr(1) String(s.delayAfterMs) Chr(1) s.target Chr(1) (s.HasOwnProp("args") ? s.args : "")
    }
    return out
}

MacroStepsDecode(str) {
    steps := []
    if str = ""
        return steps
    for chunk in StrSplit(str, Chr(2)) {
        parts := StrSplit(chunk, Chr(1))
        type := parts.Length >= 1 ? parts[1] : "wait"
        delayMs := (parts.Length >= 2 && IsInteger(parts[2])) ? Integer(parts[2]) : 0
        target := parts.Length >= 3 ? parts[3] : ""
        args := parts.Length >= 4 ? parts[4] : ""
        steps.Push({type: type, target: target, args: args, delayAfterMs: delayMs})
    }
    return steps
}

; ---------------- Mapping management ----------------
; A single physical button (scancode, or raw HID event) can now have MULTIPLE
; mappings attached to it - each stored under its own id in `mappings`/`mapOrder`.
; The first mapping for a button keeps the plain button id (e.g. "SC01E" or
; "RAW_6_02"); additional ones get a "#2", "#3", ... suffix. All enabled
; mappings sharing a button fire together when that button is pressed.

; Finds an unused mapping id for a given profile+button, so a new mapping
; never clobbers an existing one on the same button - including one with the
; same buttonKey text living in a *different* profile, since ids are now
; prefixed with the profile name ("<Profile>::SCxxx", "<Profile>::SCxxx#2", ...).
GenerateId(profile, buttonKey) {
    base := profile "::" buttonKey
    if !mappings.Has(base)
        return base
    n := 2
    loop {
        cand := base "#" n
        if !mappings.Has(cand)
            return cand
        n++
    }
}

; isNew=true  -> always creates a brand-new mapping (Add Mapping button)
; isNew=false -> overwrites the mapping currently selected in the list (Update Mapping button)
SaveMapping(isNew) {
    global lastCaptureKind, capturedSC, capturedRawPage, capturedRawBytesHex, editingId, editingProfileName, currentMacroSteps
    actionVal := ddlActionType.Value
    isApp := actionVal = 2
    isMacro := actionVal = 3
    macroStepsToSave := []
    if isApp {
        target := editAppPath.Value
        if target = "" {
            MsgBox("Enter an app/file path first (or use Browse...).", "Missing target", "Icon!")
            return
        }
        appArgs := editAppArgs.Value
    } else if isMacro {
        if currentMacroSteps.Length = 0 {
            MsgBox("Add at least one step with Edit Macro... first.", "Empty macro", "Icon!")
            return
        }
        target := ""
        appArgs := ""
        for s in currentMacroSteps
            macroStepsToSave.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
    } else {
        target := targetSendString
        if target = "" {
            MsgBox("Capture a key/combo to send first.", "Missing target", "Icon!")
            return
        }
        appArgs := ""
    }
    actionType := isApp ? "app" : (isMacro ? "macro" : "key")

    ; Run mode only makes sense for scancode buttons - see the notes near
    ; FireButtonMappings/RegisterHotkeyForButton for why raw HID mappings
    ; can't measure a hold. Raw captures always end up saved as "single"
    ; below regardless of what's selected here.
    runModeVal := ddlRunMode.Value
    runMode := runModeVal = 2 ? "repeat" : (runModeVal = 3 ? "toggle" : "single")
    repeatMs := IsInteger(edRepeatMs.Value) ? Integer(edRepeatMs.Value) : 100
    if repeatMs < 10
        repeatMs := 10

    if !isNew && (editingId = "" || !mappings.Has(editingId)) {
        MsgBox("Select a mapping in the list first, then click Update Mapping.`n`nTo create a new mapping (even on the same button), use Add Mapping instead.", "Nothing selected", "Icon!")
        return
    }

    id := ""
    if lastCaptureKind = "raw" {
        if capturedRawBytesHex = "" {
            MsgBox("Capture a button first.", "Missing input", "Icon!")
            return
        }
        buttonKey := "RAW_" Format("{:X}", capturedRawPage) "_" capturedRawBytesHex
        id := isNew ? GenerateId(editingProfileName, buttonKey) : editingId
        prevEnabled := mappings.Has(id) ? mappings[id].enabled : true
        dispId := SubStr(id, StrLen(editingProfileName) + 3)
        desc := editDesc.Value != "" ? editDesc.Value : Format("Raw 0x{:X} {} ({})", capturedRawPage, capturedRawBytesHex, dispId)
        if !mappings.Has(id)
            mapOrder.Push(id)
        mappings[id] := {profile: editingProfileName, kind: "raw", actionType: actionType, page: capturedRawPage, bytesHex: capturedRawBytesHex, desc: desc, target: target, appArgs: appArgs, macroSteps: macroStepsToSave, enabled: prevEnabled, pressType: "short", runMode: "single", repeatMs: repeatMs}
    } else {
        if !capturedSC {
            MsgBox("Capture a button first.", "Missing input", "Icon!")
            return
        }
        buttonKey := Format("SC{:03X}", capturedSC)
        id := isNew ? GenerateId(editingProfileName, buttonKey) : editingId

        ; If updating a mapping whose captured button changed (user re-captured
        ; a different physical button while editing), the OLD button also
        ; needs its hotkey state refreshed once this mapping moves off it.
        oldButtonKey := ""
        if !isNew && (mappings[editingId].HasOwnProp("kind") ? mappings[editingId].kind : "sc") = "sc" {
            ob := Format("SC{:03X}", mappings[editingId].sc)
            if ob != buttonKey
                oldButtonKey := ob
        }

        prevEnabled := mappings.Has(id) ? mappings[id].enabled : true
        dispId := SubStr(id, StrLen(editingProfileName) + 3)
        desc := editDesc.Value != "" ? editDesc.Value : dispId
        if !mappings.Has(id)
            mapOrder.Push(id)
        mappings[id] := {profile: editingProfileName, kind: "sc", actionType: actionType, sc: capturedSC, desc: desc, target: target, appArgs: appArgs, macroSteps: macroStepsToSave, enabled: prevEnabled, pressType: (runMode = "single" ? PressTypeFromDdlIndex(ddlPressType.Value) : "short"), runMode: runMode, repeatMs: repeatMs}
        ; A mapping being edited while its own repeat/toggle loop happens to
        ; be running shouldn't leave a stale timer going under the old
        ; settings (interval, target, or even run mode may have just changed).
        StopRepeat(id)
        RegisterHotkeyForButton(buttonKey)
        if oldButtonKey != ""
            RegisterHotkeyForButton(oldButtonKey)
    }

    SaveMappings()
    RefreshList()
    ResetCaptureUI()
    txtStatus.Value := (isNew ? "Added mapping " : "Updated mapping ") id "."
}

; Registers (or re-registers) the single OS hotkey for a scancode button,
; firing SendTarget for that button. Its On/Off state reflects whether ANY
; mapping currently attached to this button is enabled (with master enabled).
; Raw-report mappings never go through here - they're matched directly in
; OnRawInput against every mapping sharing that raw event.
RegisterHotkeyForButton(buttonKey) {
    global activeProfileName
    ; Only mappings belonging to the currently EFFECTIVE profile for this
    ; specific button are considered here - a button mapped only in some
    ; other (inactive, non-fallback) profile must not keep this hotkey
    ; registered. Called for every distinct buttonKey across ALL profiles
    ; whenever the active profile changes (via RefreshAllScHotkeyStates), so
    ; a button that loses its only firing mapping when switching away from a
    ; profile correctly goes Off.
    effProfile := EffectiveProfileForButton(buttonKey, "sc")
    hasFiring := false
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if (m.HasOwnProp("profile") ? m.profile : "Default") != effProfile
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        hasFiring := true
        break
    }
    state := (masterEnabled && hasFiring) ? "On" : "Off"
    try {
        Hotkey(buttonKey, (*) => OnButtonDown(buttonKey), state)
        Hotkey(buttonKey " Up", (*) => OnButtonUp(buttonKey), state)
    } catch as e {
        MsgBox("Could not register hotkey for " buttonKey ":`n" e.Message, "Error", "Icon!")
    }
}

; Resolves which profile's mappings should actually be used for one specific
; physical button: the active profile itself, if it defines ANY mapping
; (enabled or not) on that button - otherwise Default, as a per-button
; fallback. This is deliberately per-button, not a blanket merge: as soon as
; the active profile defines even one mapping on a given button, that
; button is "claimed" and Default's mapping(s) for it are ignored entirely;
; only buttons the active profile never touches fall through to Default.
; kind is "sc" or "raw" - buttonKey must be in the matching format
; ("SCxxx" for sc, "RAW_<page>_<bytesHex>" for raw).
EffectiveProfileForButton(buttonKey, kind := "sc") {
    global activeProfileName, mapOrder, mappings
    if activeProfileName = "Default"
        return "Default"
    for id in mapOrder {
        m := mappings[id]
        mKind := m.HasOwnProp("kind") ? m.kind : "sc"
        if mKind != kind
            continue
        if (m.HasOwnProp("profile") ? m.profile : "Default") != activeProfileName
            continue
        mButtonKey := mKind = "raw" ? ("RAW_" Format("{:X}", m.page) "_" m.bytesHex) : Format("SC{:03X}", m.sc)
        if mButtonKey = buttonKey
            return activeProfileName
    }
    return "Default"
}

; ---------------- Long-press timing (scancode buttons) ----------------
; A physical hold on most remotes/keyboards arrives as one Down, then
; either OS/driver auto-repeat Downs while held, then a final Up when
; released - or (rarer) just Down then Up with nothing in between. Both
; are handled the same way: the FIRST Down of a press starts a one-shot
; timer for longPressMs; further Downs before the matching Up are treated
; as repeats of the same hold and don't restart the timer. If the timer
; elapses while still held, the button's "long" mapping(s) fire immediately
; and the eventual Up is a no-op. If Up arrives first, the button's
; "short" mapping(s) fire instead. A per-press token guards against a
; stale timer from an earlier press firing after a new press has begun.
OnButtonDown(buttonKey) {
    global buttonPressState, longPressMs, mapOrder, mappings, activeProfileName
    st := buttonPressState.Has(buttonKey) ? buttonPressState[buttonKey] : ""
    if st && st.pressed
        return   ; auto-repeat while already held - same gesture, don't restart anything
    effProfile := EffectiveProfileForButton(buttonKey, "sc")
    ; Kick off any "repeat while holding" mappings on this button immediately;
    ; they run on their own timer (see StartRepeat) until OnButtonUp stops
    ; them, independent of the long-press timer below, which only concerns
    ; "single run" mappings.
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if (m.HasOwnProp("profile") ? m.profile : "Default") != effProfile
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        if (m.HasOwnProp("runMode") ? m.runMode : "single") = "repeat"
            StartRepeat(id)
    }
    token := (st ? st.token : 0) + 1
    buttonPressState[buttonKey] := {pressed: true, token: token, longFired: false}
    ; "press"-triggered single-run mappings fire right here, immediately and
    ; unconditionally - no hold-duration judgment involved, unlike short/long
    ; which are decided on release (see CheckLongPress/OnButtonUp below).
    FireButtonMappings(buttonKey, "press")
    SetTimer(() => CheckLongPress(buttonKey, token), -Max(1, longPressMs))
}

CheckLongPress(buttonKey, token) {
    global buttonPressState
    if !buttonPressState.Has(buttonKey)
        return
    st := buttonPressState[buttonKey]
    if st.token != token || !st.pressed || st.longFired
        return   ; released already, or superseded by a newer press
    st.longFired := true
    FireButtonMappings(buttonKey, "long")
}

OnButtonUp(buttonKey) {
    global buttonPressState, mapOrder, mappings, activeProfileName
    if !buttonPressState.Has(buttonKey)
        return
    st := buttonPressState[buttonKey]
    if !st.pressed
        return
    st.pressed := false
    effProfile := EffectiveProfileForButton(buttonKey, "sc")
    ; "Repeat while holding" mappings stop the instant the button is
    ; released; "Toggle" mappings flip between running and stopped on every
    ; press - neither cares whether this was a short or long press.
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if (m.HasOwnProp("profile") ? m.profile : "Default") != effProfile
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
        if runMode = "repeat"
            StopRepeat(id)
        else if runMode = "toggle"
            ToggleRepeat(id)
    }
    ; "release" fires on every Up regardless of hold duration; "short" only
    ; fires when this Up wasn't already claimed by a long press firing mid-hold.
    FireButtonMappings(buttonKey, "release")
    if !st.longFired
        FireButtonMappings(buttonKey, "short")
}

; Fires every enabled scancode mapping attached to this button whose
; pressType matches ("press"/"long"/"short"/"release"). Mappings created
; before this feature existed have no stored pressType and default to
; "short", so they behave exactly as before. Called from OnButtonDown (for
; "press", the instant the button goes down), from CheckLongPress (for
; "long", mid-hold once the threshold elapses), and from OnButtonUp (for
; "release", every time - and for "short", only when this Up wasn't already
; claimed by a long press firing mid-hold).
;
; Raw HID mappings aren't included here (or given a pressType option in the
; UI): type-1 raw keyboard reports are only read on key-down (see
; OnRawInput's "if flags & 1 return"), and generic type-2 HID reports are
; typically single momentary reports from the remote with no separate
; press/release pair to time in the first place - so there's nothing
; reliable here to measure a hold against, or to fire a distinct "press"
; action separately from.
FireButtonMappings(buttonKey, pressType) {
    global activeProfileName
    effProfile := EffectiveProfileForButton(buttonKey, "sc")
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if (m.HasOwnProp("profile") ? m.profile : "Default") != effProfile
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        ; "Repeat" and "Toggle" mappings are driven directly from
        ; OnButtonDown/OnButtonUp (see StartRepeat/StopRepeat/ToggleRepeat) -
        ; only "single run" mappings fire from here.
        if (m.HasOwnProp("runMode") ? m.runMode : "single") != "single"
            continue
        mPressType := m.HasOwnProp("pressType") ? m.pressType : "short"
        if mPressType != pressType
            continue
        FireMapping(m)
    }
}

; ---------------- Continuous run: Repeat-while-holding / Toggle ----------------
; Both modes work the same way once started: fire the mapping's action
; immediately, then again every repeatMs until stopped. The only difference
; is what starts/stops them - see OnButtonDown/OnButtonUp.
StartRepeat(id) {
    global repeatActive, repeatTimerFns, mappings
    if repeatActive.Has(id) && repeatActive[id]
        return   ; already looping
    if !mappings.Has(id)
        return
    m := mappings[id]
    ms := m.HasOwnProp("repeatMs") ? m.repeatMs : 100
    if ms < 10
        ms := 10
    fn := () => RepeatTick(id)
    repeatTimerFns[id] := fn
    repeatActive[id] := true
    FireMapping(m)
    SetTimer(fn, ms)
}

; Re-reads the mapping fresh on every tick (rather than closing over the
; object captured at start time) so a mapping that gets disabled or deleted
; mid-loop stops cleanly instead of continuing to fire stale settings.
RepeatTick(id) {
    global mappings
    if !mappings.Has(id) || !mappings[id].enabled {
        StopRepeat(id)
        return
    }
    FireMapping(mappings[id])
}

StopRepeat(id) {
    global repeatActive, repeatTimerFns
    if repeatTimerFns.Has(id) {
        SetTimer(repeatTimerFns[id], 0)
        repeatTimerFns.Delete(id)
    }
    repeatActive[id] := false
}

ToggleRepeat(id) {
    global repeatActive
    if repeatActive.Has(id) && repeatActive[id]
        StopRepeat(id)
    else
        StartRepeat(id)
}

; Stops every in-flight repeat/toggle loop - used when master remapping is
; turned off or the active profile changes, so nothing keeps firing under
; settings that no longer apply.
StopAllRepeats() {
    global repeatActive, repeatTimerFns
    for id, fn in repeatTimerFns
        SetTimer(fn, 0)
    repeatTimerFns := Map()
    repeatActive := Map()
}

; Fires a mapping's configured action once: sends a key/combo, launches an
; app, or plays a macro start-to-finish. Repeat/toggle just call this
; repeatedly (see StartRepeat/RepeatTick above).
FireMapping(m) {
    actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
    if actionType = "app"
        LaunchApp(m.target, m.HasOwnProp("appArgs") ? m.appArgs : "")
    else if actionType = "macro"
        RunMacroOnce(m.HasOwnProp("macroSteps") ? m.macroSteps : [])
    else
        Send(m.target)
}

; Runs a macro's steps in order once. "wait" steps have no action of their
; own; every step's delayAfterMs (if any) is a Sleep before the next step.
RunMacroOnce(steps) {
    for s in steps {
        if s.type = "key"
            Send(s.target)
        else if s.type = "app"
            LaunchApp(s.target, s.HasOwnProp("args") ? s.args : "")
        if s.delayAfterMs > 0
            Sleep(s.delayAfterMs)
    }
}

LaunchApp(path, args) {
    if path = ""
        return
    try {
        cmd := '"' path '"'
        if args != ""
            cmd .= " " args
        Run(cmd)
    } catch as e {
        MsgBox("Could not launch:`n" path (args != "" ? " " args : "") "`n`n" e.Message, "Launch Error", "Icon!")
    }
}

ResetCaptureUI() {
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, lastCaptureKind, rawCaptureArmed, editingId, currentMacroSteps
    capturedSC := 0
    capturedRawPage := 0
    capturedRawBytesHex := ""
    lastCaptureKind := "sc"
    rawCaptureArmed := false
    editingId := ""
    targetSendString := ""
    currentMacroSteps := []
    editDesc.Value := ""
    txtTarget.Value := ""
    editAppPath.Value := ""
    editAppArgs.Value := ""
    ddlActionType.Choose(1)
    OnActionTypeChange()
    ddlRunMode.Choose(1)
    edRepeatMs.Value := "100"
    OnRunModeChange()
    ddlPressType.Choose(DdlIndexFromPressType("short"))
    UpdateMacroInfoLabel()
    txtCaptureStatus.Value := "Not captured yet."
}

; ---------------- ListView handling ----------------
; lv shows only mappings belonging to editingProfileName (a pure GUI/CRUD
; scope - see handoff §4), so its row indices no longer line up 1:1 with
; mapOrder once more than one profile exists. lvKeys is the parallel,
; filtered array: lvKeys[rowNum] is the mapOrder id backing that visible row.
lvKeys := []

RefreshList() {
    global lvKeys, editingProfileName
    lv.Delete()
    lvKeys := []
    for key in mapOrder {
        m := mappings[key]
        if (m.HasOwnProp("profile") ? m.profile : "Default") != editingProfileName
            continue
        actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
        if actionType = "app" {
            args := m.HasOwnProp("appArgs") ? m.appArgs : ""
            sendsDisplay := "Launch: " m.target (args != "" ? " " args : "")
        } else if actionType = "macro" {
            n := m.HasOwnProp("macroSteps") ? m.macroSteps.Length : 0
            sendsDisplay := "Macro (" n " step" (n = 1 ? "" : "s") ")"
        } else {
            sendsDisplay := HumanizeSendKey(m.target)
        }
        runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
        if runMode = "repeat"
            pressDisplay := "Repeat"
        else if runMode = "toggle"
            pressDisplay := "Toggle"
        else {
            mPressType := m.HasOwnProp("pressType") ? m.pressType : "short"
            pressDisplay := mPressType = "press" ? "Press" : (mPressType = "long" ? "Long" : (mPressType = "release" ? "Release" : "Short"))
        }
        lv.Add(, m.enabled ? "Yes" : "No", m.desc, sendsDisplay, pressDisplay)
        lvKeys.Push(key)
    }
}

LVSelect(lvObj, rowNum, selected) {
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, lastCaptureKind, editingId, lvKeys, currentMacroSteps
    if !selected
        return
    if rowNum < 1 || rowNum > lvKeys.Length
        return
    key := lvKeys[rowNum]
    m := mappings[key]
    editingId := key
    currentMacroSteps := m.HasOwnProp("macroSteps") ? m.macroSteps : []
    ApplyActionFieldsFromMapping(m)
    ddlPressType.Choose(DdlIndexFromPressType(m.HasOwnProp("pressType") ? m.pressType : "short"))
    runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
    ddlRunMode.Choose(runMode = "repeat" ? 2 : (runMode = "toggle" ? 3 : 1))
    edRepeatMs.Value := String(m.HasOwnProp("repeatMs") ? m.repeatMs : 100)
    OnRunModeChange()
    if (m.HasOwnProp("kind") ? m.kind : "sc") = "raw" {
        capturedSC := 0
        capturedRawPage := m.page
        capturedRawBytesHex := m.bytesHex
        lastCaptureKind := "raw"
        editDesc.Value := m.desc
        ; Raw HID mappings always save as run mode "single" (see SaveMapping) -
        ; reflect that here regardless of what's currently selected above.
        ddlRunMode.Choose(1)
        OnRunModeChange()
        txtCaptureStatus.Value := Format("Editing raw mapping (Page:0x{:X} Bytes:{}) - press Update Mapping to save changes, or Add Mapping for a new one on this same button", m.page, m.bytesHex)
        return
    }
    lastCaptureKind := "sc"
    capturedSC := m.sc
    editDesc.Value := m.desc
    txtCaptureStatus.Value := "Editing " key " (press Update Mapping to save changes, or Add Mapping for a new one on this same button)"
}

; Right-click (or Menu key) on a mapping row: offer to copy that mapping into
; any other profile. Item is the 1-based row number under the cursor, or 0 if
; the click landed on empty list space.
LVContextMenu(GuiCtrlObj, Item, IsRightClick, X, Y) {
    global lvKeys, editingProfileName, profiles
    if !Item || Item > lvKeys.Length
        return
    lv.Modify(Item, "Select Focus")   ; make sure the right-clicked row is the selected one
    key := lvKeys[Item]
    if !mappings.Has(key)
        return
    m := mappings[key]

    ctxMenu := Menu()
    otherCount := 0
    for pname in profiles {
        if pname = editingProfileName
            continue
        otherCount++
        ctxMenu.Add("Copy to " pname, CopyMappingToProfile.Bind(key, pname))
    }
    if !otherCount {
        ctxMenu.Add("No other profiles to copy to", (*) => "")
        ctxMenu.Disable("No other profiles to copy to")
    }
    ; Use the actual mouse position for the popup rather than the event's X/Y
    ; (which are relative to the control, not the screen) - simplest way to
    ; get a correctly-placed menu regardless of how it was invoked.
    MouseGetPos(&mx, &my)
    ctxMenu.Show(mx, my)
}

; Duplicates one mapping into another profile, leaving the original in place
; and untouched. The copy gets its own id (via GenerateId, same as a brand
; new mapping) so it never collides with anything already in the target
; profile - if that profile already has a mapping on the same physical
; button, this simply becomes an additional mapping on that button rather
; than overwriting the existing one.
CopyMappingToProfile(sourceKey, targetProfile, *) {
    if !mappings.Has(sourceKey)
        return
    src := mappings[sourceKey]
    kind := src.HasOwnProp("kind") ? src.kind : "sc"
    buttonKey := kind = "raw" ? ("RAW_" Format("{:X}", src.page) "_" src.bytesHex) : Format("SC{:03X}", src.sc)
    newId := GenerateId(targetProfile, buttonKey)

    newMap := {
        profile: targetProfile,
        kind: kind,
        actionType: src.HasOwnProp("actionType") ? src.actionType : "key",
        desc: src.desc,
        target: src.target,
        appArgs: src.HasOwnProp("appArgs") ? src.appArgs : "",
        macroSteps: src.HasOwnProp("macroSteps") ? CloneMacroSteps(src.macroSteps) : [],
        enabled: src.enabled,
        pressType: src.HasOwnProp("pressType") ? src.pressType : "short",
        runMode: src.HasOwnProp("runMode") ? src.runMode : "single",
        repeatMs: src.HasOwnProp("repeatMs") ? src.repeatMs : 100
    }
    if kind = "raw" {
        newMap.page := src.page
        newMap.bytesHex := src.bytesHex
    } else {
        newMap.sc := src.sc
    }

    mappings[newId] := newMap
    mapOrder.Push(newId)
    if kind = "sc"
        RegisterHotkeyForButton(buttonKey)

    SaveMappings()
    if targetProfile = editingProfileName
        RefreshList()
    txtStatus.Value := "Copied '" src.desc "' to profile '" targetProfile "'."
}

; Deep-copies a mapping's macro steps so the two profiles' copies don't share
; the same underlying array/objects (editing one macro later shouldn't be
; able to silently mutate the other profile's copy).
CloneMacroSteps(steps) {
    out := []
    for s in steps
        out.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
    return out
}

; Populates the action-type dropdown, key-target field, and app fields from
; an existing mapping object (used when selecting a row to edit).
ApplyActionFieldsFromMapping(m) {
    global targetSendString
    actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
    if actionType = "app" {
        ddlActionType.Choose(2)
        editAppPath.Value := m.target
        editAppArgs.Value := m.HasOwnProp("appArgs") ? m.appArgs : ""
        targetSendString := ""
        txtTarget.Value := ""
    } else if actionType = "macro" {
        ddlActionType.Choose(3)
        targetSendString := ""
        txtTarget.Value := ""
        editAppPath.Value := ""
        editAppArgs.Value := ""
    } else {
        ddlActionType.Choose(1)
        targetSendString := m.target
        txtTarget.Value := HumanizeSendKey(m.target)
        editAppPath.Value := ""
        editAppArgs.Value := ""
    }
    OnActionTypeChange()
    UpdateMacroInfoLabel()
}

GetSelectedKey() {
    global lvKeys
    row := lv.GetNext()
    if !row || row > lvKeys.Length
        return ""
    return lvKeys[row]
}

ToggleSelected(*) {
    key := GetSelectedKey()
    if key = "" {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    mappings[key].enabled := !mappings[key].enabled
    m := mappings[key]
    if !m.enabled
        StopRepeat(key)
    if (m.HasOwnProp("kind") ? m.kind : "sc") = "sc"
        RegisterHotkeyForButton(Format("SC{:03X}", m.sc))
    SaveMappings()
    RefreshList()
}

RemoveSelected(*) {
    key := GetSelectedKey()
    if key = "" {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    buttonKeyToRefresh := ""
    if mappings.Has(key) {
        m := mappings[key]
        if (m.HasOwnProp("kind") ? m.kind : "sc") = "sc"
            buttonKeyToRefresh := Format("SC{:03X}", m.sc)
    }
    StopRepeat(key)
    mappings.Delete(key)
    idx := 0
    for i, k in mapOrder {
        if k = key {
            idx := i
            break
        }
    }
    if idx
        mapOrder.RemoveAt(idx)
    ; Recompute the hotkey state for that button - it may still have other
    ; enabled mappings, or this may have been the last one (turns it Off).
    if buttonKeyToRefresh != ""
        RegisterHotkeyForButton(buttonKeyToRefresh)
    SaveMappings()
    RefreshList()
    ResetCaptureUI()
}

; ---------------- Master enable/disable ----------------
; Re-registers (or unregisters) the OS hotkey for every scancode button that
; has at least one mapping attached, reflecting current master-enabled and
; active-profile state. Raw-report mappings don't need this - they're
; matched directly in OnRawInput and were never gated by an OS hotkey.
RefreshAllScHotkeyStates() {
    seenButtons := Map()
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        bk := Format("SC{:03X}", m.sc)
        if seenButtons.Has(bk)
            continue
        seenButtons[bk] := true
        RegisterHotkeyForButton(bk)
    }
}

; ---------------- App-based profile switching (active profile) ----------------
; Resolves which profile SHOULD be active for a given foreground exe name.
; Returns "Default" whenever app-watching is off, or when no non-Default
; profile claims that exe. Matching is case-insensitive, exact-filename only
; (no paths/wildcards - see handoff decision #2). If two profiles somehow
; claim the same exe (shouldn't happen once Batch 4's save-time validation
; lands), the first match in profile definition/iteration order wins, per
; decision #3.
ProfileForProcess(exeName) {
    global profiles, appWatchEnabled
    if !appWatchEnabled
        return "Default"
    for pname, pdata in profiles {
        if pname = "Default"
            continue
        for procName in pdata.processNames {
            if StrLower(procName) = StrLower(exeName)
                return pname
        }
    }
    return "Default"
}

; Polled every 500ms so app switching feels responsive. Cheap when
; app-watching is off: just makes sure the
; engine has fallen back to Default (covers the moment the checkbox is
; turned off mid-session) and returns without touching the foreground window.
CheckActiveProfile() {
    global appWatchEnabled, activeProfileName
    if !appWatchEnabled {
        if activeProfileName != "Default"
            SwitchActiveProfile("Default")
        return
    }
    try
        exeName := WinGetProcessName("A")
    catch {
        return   ; no foreground window (e.g. transient focus loss) - leave the active profile as-is
    }
    newProfile := ProfileForProcess(exeName)
    if newProfile != activeProfileName
        SwitchActiveProfile(newProfile)
}

; Switches the firing engine over to a different profile. Clears in-flight
; long-press state (a stale timer from the old profile must not fire a
; mapping belonging to the newly active one - decision #8), then re-derives
; On/Off and re-registers the OS hotkey for every distinct buttonKey across
; ALL profiles, not just the new one: a button that was only mapped in the
; profile being switched AWAY from has to be turned Off, and
; RefreshAllScHotkeyStates already walks every mapping regardless of profile
; to collect those buttonKeys, so no separate pass is needed here.
SwitchActiveProfile(newName) {
    global activeProfileName, buttonPressState
    StopAllRepeats()
    activeProfileName := newName
    buttonPressState := Map()
    RefreshAllScHotkeyStates()
    UpdateActiveProfileStatus()
}

; GUI/tray readout of which profile the engine is currently firing from - a
; separate concept from editingProfileName (which profile the GUI list/form
; is showing), see handoff §4. This text is the "active profile" half of
; that split; the "editing profile" list box is the other half.
UpdateActiveProfileStatus() {
    global activeProfileName
    if IsObject(txtActiveProfile)
        txtActiveProfile.Value := "Active profile: " activeProfileName
    A_IconTip := "Remote Button Mapper (" activeProfileName ")"
}

; ---------------- Editing-profile selector & profile CRUD ----------------
; Rebuilds the profile list box from the current `profiles` registry
; (Default first, then whatever else exists in Map iteration order), and
; re-selects whichever name is currently in editingProfileName so a rebuild
; never silently changes what the user is looking at. Called after
; LoadMappings() and after any New/Rename/Delete profile action.
RefreshProfileList() {
    global profiles, editingProfileName
    names := ["Default"]
    for pname, pdata in profiles {
        if pname = "Default"
            continue
        names.Push(pname)
    }
    lbProfiles.Delete()
    lbProfiles.Add(names)
    idx := 1
    for i, n in names {
        if n = editingProfileName {
            idx := i
            break
        }
    }
    lbProfiles.Choose(idx)
}

; The list box only changes which profile the GUI is showing/editing - it
; never touches activeProfileName or the firing engine (see handoff §4).
OnEditingProfileChange() {
    global editingProfileName
    editingProfileName := lbProfiles.Text
    RefreshList()
    ResetCaptureUI()
}

; Shared dialog for both "New Profile..." and "Rename Profile...": mode
; "rename" pre-fills the name/process fields from the profile currently
; being edited (Default is exempt - guarded here before the dialog even
; opens, per decision #4).
OpenProfileDialog(mode) {
    global editingProfileName, profiles
    if mode = "rename" && editingProfileName = "Default" {
        MsgBox("The Default profile can't be renamed.", "Not allowed", "Icon!")
        return
    }
    existingName := mode = "rename" ? editingProfileName : ""
    existingProcCsv := mode = "rename" ? JoinCsv(profiles[editingProfileName].processNames) : ""
    gp := Gui("+AlwaysOnTop +Owner" g.Hwnd, mode = "rename" ? "Rename Profile" : "New Profile")
    gp.SetFont("s10", "Segoe UI")
    gp.Add("Text", "w400", "Profile name:")
    edName := gp.Add("Edit", "x+10 w200", existingName)
    gp.Add("Text", "xm y+12 w420", "Process names this profile activates for (comma-separated, e.g. kodi.exe, kodi64.exe):")
    edProc := gp.Add("Edit", "xm y+6 w330", existingProcCsv)
    btnBrowseProc := gp.Add("Button", "x+8 w80", "Browse...")
    btnBrowseProc.OnEvent("Click", (*) => BrowseForProcessNameInto(edProc))
    btnSave := gp.Add("Button", "xm y+15 w100", "Save")
    btnSave.OnEvent("Click", (*) => SaveProfileDialog(mode, existingName, edName.Value, edProc.Value, gp))
    btnCancel := gp.Add("Button", "x+10 w100", "Cancel")
    btnCancel.OnEvent("Click", (*) => gp.Destroy())
    gp.OnEvent("Close", (*) => gp.Destroy())
    gp.Show()
}

; Lets the user pick an .exe via a file browser instead of typing its name
; from memory. Only the bare filename is kept (not the full path) - matching
; in ProfileForProcess is by exact filename only, per decision #2, so a full
; path would never match anything at runtime. Appends to whatever's already
; in the field (comma-separated) rather than replacing it, so this can be
; used repeatedly to add several process names to the same profile.
BrowseForProcessNameInto(edProc) {
    file := FileSelect(, , "Select application", "Executables (*.exe)")
    if file = ""
        return
    SplitPath(file, &exeName)
    current := Trim(edProc.Value)
    edProc.Value := current = "" ? exeName : current ", " exeName
}

; Returns "" if none of procList's process names are already claimed by any
; OTHER profile (excludeProfileName - the profile currently being saved - is
; skipped so editing a profile against its own existing list never flags
; itself; Default is always skipped since it has no process list). Otherwise
; returns a human-readable, newline-prefixed list of the conflicts found, for
; use in a warning dialog. Implements decision #3's "warn... if they try to
; assign a process name already claimed by another profile" - this is a
; warning the user can override, not a hard block, since "first match in
; profile definition order wins" is already the defined runtime resolution.
FindProcessNameConflicts(procList, excludeProfileName) {
    global profiles
    conflicts := ""
    for procName in procList {
        for pname, pdata in profiles {
            if pname = "Default" || pname = excludeProfileName
                continue
            for other in pdata.processNames {
                if StrLower(other) = StrLower(procName) {
                    conflicts .= Format("`n- '{}' is already claimed by profile '{}'", procName, pname)
                    break
                }
            }
        }
    }
    return conflicts
}

; Handles both New and Rename saves.
;
; Validation: non-empty name, no "::" (that's the id-prefix delimiter - see
; decision #6/#7), no name collision with an existing profile, and a
; save-time warning (not a hard block) on cross-profile process-name
; conflicts via FindProcessNameConflicts, per decision #3.
SaveProfileDialog(mode, oldName, newNameRaw, procCsv, gp) {
    global profiles, editingProfileName, activeProfileName, mappings, mapOrder
    newName := Trim(newNameRaw)
    if newName = "" {
        MsgBox("Enter a profile name.", "Missing name", "Icon!")
        return
    }
    if InStr(newName, "::") {
        MsgBox("Profile names can't contain '::'.", "Invalid name", "Icon!")
        return
    }
    procList := []
    for p in StrSplit(procCsv, ",") {
        p := Trim(p)
        if p != ""
            procList.Push(p)
    }
    conflictMsg := FindProcessNameConflicts(procList, mode = "rename" ? oldName : "")
    if conflictMsg != "" {
        result := MsgBox("Some of these process names are already claimed by another profile (whichever profile comes first wins at runtime):" conflictMsg "`n`nSave anyway?", "Process name conflict", "YesNo Icon!")
        if result != "Yes"
            return
    }
    if mode = "new" {
        if profiles.Has(newName) {
            MsgBox("A profile named '" newName "' already exists.", "Name taken", "Icon!")
            return
        }
        profiles[newName] := {processNames: procList}
        editingProfileName := newName
        RefreshProfileList()
        RefreshList()
        ResetCaptureUI()
        SaveMappings()
        txtStatus.Value := "Created profile '" newName "'."
    } else {
        if newName != oldName && profiles.Has(newName) {
            MsgBox("A profile named '" newName "' already exists.", "Name taken", "Icon!")
            return
        }
        profiles[oldName].processNames := procList
        if newName != oldName {
            profiles[newName] := profiles[oldName]
            profiles.Delete(oldName)
            ; Update every owned mapping's `profile` field AND its id prefix
            ; (e.g. "OldName::SC01E" -> "NewName::SC01E"), so ids stay
            ; consistent with the profile that owns them rather than merely
            ; relying on the `profile` field being authoritative. Collected
            ; into renamedIds first, then applied, so the mapOrder rewrite
            ; below doesn't have to worry about mutating `mappings` mid-scan.
            renamedIds := Map()
            for key in mapOrder {
                m := mappings[key]
                if (m.HasOwnProp("profile") ? m.profile : "Default") != oldName
                    continue
                m.profile := newName
                suffix := SubStr(key, StrLen(oldName) + 3)   ; strip the "OldName::" prefix
                renamedIds[key] := newName "::" suffix
            }
            for id, newId in renamedIds {
                mappings[newId] := mappings[id]
                mappings.Delete(id)
            }
            for i, key in mapOrder {
                if renamedIds.Has(key)
                    mapOrder[i] := renamedIds[key]
            }
            if activeProfileName = oldName
                activeProfileName := newName
            if editingProfileName = oldName
                editingProfileName := newName
            ResetCaptureUI()   ; editingId (if any) referenced an id that no longer exists post-rename
        }
        RefreshProfileList()
        RefreshList()
        UpdateActiveProfileStatus()
        SaveMappings()
        txtStatus.Value := "Updated profile '" newName "'."
    }
    gp.Destroy()
}

; Deletes the profile currently being edited (Default is exempt, per
; decision #4) along with every mapping it owns. Confirms first, showing the
; mapping count about to be removed.
DeleteProfileFlow() {
    global editingProfileName, profiles, mappings, mapOrder, activeProfileName
    if editingProfileName = "Default" {
        MsgBox("The Default profile can't be deleted.", "Not allowed", "Icon!")
        return
    }
    target := editingProfileName
    count := 0
    for key in mapOrder {
        if (mappings[key].HasOwnProp("profile") ? mappings[key].profile : "Default") = target
            count++
    }
    result := MsgBox(Format("Delete profile '{}'? This will permanently remove its {} mapping(s).", target, count), "Delete Profile", "YesNo Icon!")
    if result != "Yes"
        return
    removeSet := Map()
    for key in mapOrder {
        if (mappings[key].HasOwnProp("profile") ? mappings[key].profile : "Default") = target
            removeSet[key] := true
    }
    for key in removeSet {
        StopRepeat(key)
        mappings.Delete(key)
    }
    newOrder := []
    for key in mapOrder {
        if !removeSet.Has(key)
            newOrder.Push(key)
    }
    mapOrder := newOrder
    profiles.Delete(target)
    if activeProfileName = target
        SwitchActiveProfile("Default")
    if editingProfileName = target
        editingProfileName := "Default"
    RefreshProfileList()
    RefreshList()
    ResetCaptureUI()
    SaveMappings()
    txtStatus.Value := "Deleted profile '" target "' and its mappings."
}

; ---------------- App-based profile switching setting ----------------
SetAppWatchEnabled(val) {
    global appWatchEnabled
    appWatchEnabled := !!val
    chkAppWatch.Value := appWatchEnabled
    if appWatchEnabled
        A_TrayMenu.Check("Enable App-Based Auto Profile Switching")
    else
        A_TrayMenu.Uncheck("Enable App-Based Auto Profile Switching")
    SaveMappings()
    CheckActiveProfile()   ; reflect the new setting immediately rather than waiting for the next 500ms poll
    txtStatus.Value := appWatchEnabled
        ? "App-based profile switching enabled - profiles will follow the foreground app."
        : "App-based profile switching disabled - Default profile is always active."
}

ToggleAppWatchFromTray(*) {
    SetAppWatchEnabled(!appWatchEnabled)
}

; ---------------- Run-elevated setting ----------------
; Turning this ON while not already elevated has nowhere to go but an
; immediate restart - a running process can't gain admin rights on the fly
; - so it confirms, then relaunches via RelaunchElevated() (which exits this
; instance once the elevated one is confirmed to be starting). Turning it
; OFF can't de-elevate an already-elevated running instance either, so that
; just saves the preference for the next normal-privilege launch.
SetRunElevated(val) {
    global runElevated
    val := !!val
    if val && !A_IsAdmin {
        answer := MsgBox("Restart Remote Button Mapper as Administrator now?`n`nThis fixes mappings getting stuck sending the button's factory function while Voice Access, Narrator, Magnifier, or the on-screen keyboard has focus.", "Restart elevated?", "YesNo Icon!")
        if answer != "Yes" {
            chkRunElevated.Value := false   ; undo the click - user declined the restart
            return
        }
        runElevated := true
        SaveMappings()
        RelaunchElevated()
        return
    }
    runElevated := val
    SaveMappings()
    if !val && A_IsAdmin
        MsgBox("This takes effect the next time the app is started normally - it's already running elevated for this session.", "Run elevated", "Icon!")
}

; Relaunches the script/exe elevated (triggers a UAC prompt) and exits this
; instance once that succeeds. If the user cancels the UAC prompt (or it
; otherwise fails), Run() throws, this instance stays running exactly as it
; was, and the preference remains saved for next time.
RelaunchElevated() {
    try {
        if A_IsCompiled
            Run("*RunAs `"" A_ScriptFullPath "`"")
        else
            Run("*RunAs `"" A_AhkPath "`" /restart `"" A_ScriptFullPath "`"")
    } catch as e {
        MsgBox("Could not restart elevated (UAC prompt cancelled or blocked):`n" e.Message, "Elevation failed", "Icon!")
        return
    }
    ExitApp()
}

; ---------------- Run-at-startup setting ----------------
; Two methods, picked via the dropdown next to the checkbox:
;   - "shortcut": a .lnk in the current user's Startup folder (A_Startup).
;     Simple and needs no admin rights, but if "Run elevated" is also on,
;     this still triggers a UAC prompt on every login (a Startup-folder
;     shortcut can't launch pre-elevated).
;   - "admin": a Task Scheduler task that runs elevated ("Run with highest
;     privileges") for the current user with no logon-time UAC prompt.
;     Preferred when "Run elevated" is on. Uses PowerShell's ScheduledTasks
;     cmdlets rather than schtasks.exe, because schtasks.exe's /create
;     switches can't reach the task's Conditions tab (battery behavior) or
;     disable the default 3-day execution time limit.
;     Registering a task with -RunLevel Highest requires the calling
;     PowerShell process itself to already be elevated, not just the user
;     account to be an administrator - and since "Run elevated" (whether
;     the app itself runs as admin) is a separate, optional setting, most
;     people enable this from an ordinary non-elevated session and would
;     hit "Access is denied". SetStartupTask() below handles that by
;     retrying once via a one-shot elevated PowerShell (its own UAC prompt)
;     when the plain attempt fails and the app isn't already elevated.
StartupShortcutPath() {
    return A_Startup "\Remote Button Mapper.lnk"
}

CreateStartupShortcut() {
    try {
        if A_IsCompiled
            FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir, "", "Remote Button Mapper", A_ScriptFullPath)
        else
            FileCreateShortcut(A_AhkPath, StartupShortcutPath(), A_ScriptDir, '"' A_ScriptFullPath '"', "Remote Button Mapper", A_ScriptFullPath)
        return true
    } catch as e {
        MsgBox("Could not create the startup shortcut:`n" e.Message, "Startup shortcut failed", "Icon!")
        return false
    }
}

RemoveStartupShortcut() {
    try {
        if FileExist(StartupShortcutPath())
            FileDelete(StartupShortcutPath())
    } catch as e {
        MsgBox("Could not remove the startup shortcut:`n" e.Message, "Startup shortcut failed", "Icon!")
    }
}

; ---- Task Scheduler method ----
PSQuote(str) {
    ; Escape a string for safe embedding inside a PowerShell single-quoted
    ; literal ('...'): the only character that needs escaping there is a
    ; literal single quote, which PowerShell wants doubled ('').
    return StrReplace(str, "'", "''")
}

RunPowerShellScript(psContent, elevated := false) {
    ; Writes psContent to a temp .ps1 file, runs it, returns {code, error},
    ; then cleans up the temp file(s). Pass elevated:=true to launch the
    ; PowerShell helper itself via a UAC prompt (see SetStartupTask below
    ; for why that's sometimes required) rather than as a normal child
    ; process - everything else about the flow is identical either way.
    ;
    ; Wrapped so ANY cmdlet error becomes a terminating error (via
    ; $ErrorActionPreference = 'Stop') and is caught, written to an error
    ; file, and turned into a non-zero exit code. Without this, PowerShell
    ; cmdlet errors just print in red and the .ps1 keeps going / exits 0 -
    ; so callers here would wrongly think the task was created.
    psFile  := A_Temp "\RBM_TaskSetup_" A_TickCount ".ps1"
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

    ; The program path must be quoted for the "*RunAs" verb prefix to parse
    ; it correctly (same convention RelaunchElevated() uses below) - the
    ; plain, non-elevated Run doesn't need that quoting but tolerates it.
    psArgs := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' psFile '"'
    psCmd  := (elevated ? '*RunAs ' : '') '"powershell" ' psArgs
    try {
        exitCode := RunWait(psCmd, , "Hide")
    } catch as e {
        ; Only reachable when elevated:=true - the UAC prompt was cancelled
        ; or blocked (e.g. by policy), so no PowerShell process ever ran and
        ; there's nothing in errFile to read.
        try FileDelete(psFile)
        try FileDelete(errFile)
        return {code: -1, error: "The elevation (UAC) prompt was cancelled or blocked."}
    }

    errMsg := ""
    if FileExist(errFile)
        try errMsg := Trim(FileRead(errFile, "UTF-8"))

    try FileDelete(psFile)
    try FileDelete(errFile)
    return {code: exitCode, error: errMsg}
}

IsStartupTaskRegistered() {
    global RunAtStartupTaskName
    psContent := "if (Get-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
    return RunPowerShellScript(psContent).code = 0
}

; Returns {ok, error}.
SetStartupTask(enable) {
    global RunAtStartupTaskName
    if enable {
        ; Build the launch command: for a compiled .exe just the exe itself
        ; with no argument; for a plain script, the AutoHotkey interpreter
        ; as the executable and the quoted script path as its argument.
        execPath := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
        execArg  := A_IsCompiled ? "" : '"' A_ScriptFullPath '"'

        ; Only pass -Argument when there actually is one: an empty string
        ; makes New-ScheduledTaskAction throw ("Cannot bind argument to
        ; parameter 'Argument' because it is an empty string"), which would
        ; otherwise silently kill task creation for every compiled build.
        if execArg = ""
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "'`n"
        else
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "' -Argument '" PSQuote(execArg) "'`n"

        psContent .= "$trigger = New-ScheduledTaskTrigger -AtLogOn`n"
        ; Explorer's tray isn't always ready the instant the "at logon"
        ; trigger fires; a short delay avoids the tray icon silently
        ; getting dropped because the tray host isn't up yet.
        psContent .= "$trigger.Delay = 'PT15S'`n"
        psContent .= "$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive`n"
        ; -AllowStartIfOnBatteries / -DontStopIfGoingOnBatteries turn off
        ; the Conditions-tab settings that would otherwise block this from
        ; starting/staying running on battery power. -ExecutionTimeLimit
        ; ([TimeSpan]::Zero) disables the default 3-day run-time limit.
        psContent .= "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)`n"
        psContent .= "Register-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null"

        result := RunPowerShellScript(psContent)
        if result.code != 0 && !A_IsAdmin {
            ; Register-ScheduledTask with -RunLevel Highest requires the
            ; CALLING process itself to already be elevated - being an
            ; administrator account isn't enough on its own, and a plain
            ; (non-admin-token) PowerShell gets "Access is denied" here even
            ; though the resulting task runs fine at logon. "Run elevated"
            ; is a separate, optional app setting (see the Elevation comment
            ; near the top of the script), so most people flip on "run at
            ; startup as admin" from an ordinary non-elevated session and
            ; would hit that denial. Retry once via a one-shot elevated
            ; PowerShell instead of failing outright - this only elevates
            ; the helper process for this single call, not the whole app,
            ; and shows a single UAC prompt.
            result := RunPowerShellScript(psContent, true)
        }
        return {ok: result.code = 0, error: result.error}
    } else {
        ; Deleting a task that doesn't exist is treated as success too,
        ; since that still leaves us in the desired "not registered" state.
        psContent := "Unregister-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Confirm:$false -ErrorAction SilentlyContinue"
        RunPowerShellScript(psContent)
        return {ok: true, error: ""}
    }
}

; ---- Shared enable/disable + mode-switch glue ----
SetRunAtStartup(val) {
    global runAtStartup, runAtStartupMode
    val := !!val
    mode := ddlRunStartupMode.Text = "As admin (Task Scheduler)" ? "admin" : "shortcut"
    if val {
        if mode = "admin" {
            result := SetStartupTask(true)
            if !result.ok {
                msg := "Couldn't create the startup task."
                if result.error != ""
                    msg .= "`n`nDetails:`n" result.error
                MsgBox(msg, "Startup", "Icon!")
                chkRunStartup.Value := false   ; undo the click
                return
            }
        } else {
            if !CreateStartupShortcut() {
                chkRunStartup.Value := false   ; undo the click - shortcut creation failed
                return
            }
        }
        runAtStartupMode := mode
    } else {
        if runAtStartupMode = "admin"
            SetStartupTask(false)
        else
            RemoveStartupShortcut()
    }
    runAtStartup := val
    chkRunStartup.Value := runAtStartup
    SaveMappings()
    txtStatus.Value := runAtStartup
        ? (runAtStartupMode = "admin"
            ? "Added to Windows startup (elevated, via Task Scheduler) - no UAC prompt at login."
            : "Added to Windows startup - the app will launch automatically at login.")
        : "Removed from Windows startup."
}

; Switching the method while startup is already enabled tears down the old
; method and sets up the new one. If the new method fails to set up, the
; dropdown snaps back and the old method is left in place untouched.
OnRunStartupModeChange() {
    global runAtStartupMode
    newMode := ddlRunStartupMode.Text = "As admin (Task Scheduler)" ? "admin" : "shortcut"
    if newMode = runAtStartupMode
        return
    if runAtStartup {
        if newMode = "admin" {
            result := SetStartupTask(true)
            if !result.ok {
                msg := "Couldn't create the startup task."
                if result.error != ""
                    msg .= "`n`nDetails:`n" result.error
                MsgBox(msg, "Startup", "Icon!")
                ddlRunStartupMode.Choose(1)   ; revert to shortcut
                return
            }
            RemoveStartupShortcut()
        } else {
            if !CreateStartupShortcut() {
                ddlRunStartupMode.Choose(2)   ; revert to admin
                return
            }
            SetStartupTask(false)
        }
    }
    runAtStartupMode := newMode
    SaveMappings()
}

SetMasterEnabled(val) {
    global masterEnabled
    masterEnabled := !!val
    chkMaster.Value := masterEnabled
    if masterEnabled
        A_TrayMenu.Check("Remapping Enabled")
    else {
        A_TrayMenu.Uncheck("Remapping Enabled")
        StopAllRepeats()
    }
    RefreshAllScHotkeyStates()
    SaveMappings()
    txtStatus.Value := masterEnabled ? "Remapping enabled." : "Remapping paused."
}

ToggleMasterFromTray(*) {
    SetMasterEnabled(!masterEnabled)
}

; ---------------- Start-hidden setting ----------------
SetStartHidden(val) {
    global startHidden
    startHidden := !!val
    chkStartHidden.Value := startHidden
    if startHidden
        A_TrayMenu.Check("Start Hidden")
    else
        A_TrayMenu.Uncheck("Start Hidden")
    SaveMappings()
}

ToggleStartHiddenFromTray(*) {
    SetStartHidden(!startHidden)
}

; ---------------- Long-press threshold setting ----------------
; Validates as the user types; ignores anything that isn't a positive
; integer yet (e.g. mid-edit/blank) rather than fighting their typing.
; A small floor keeps a stray "0" from making every press register as long.
OnLongPressMsChange() {
    global longPressMs
    val := edLongPressMs.Value
    if !IsInteger(val)
        return
    n := Integer(val)
    if n < 50
        n := 50
    longPressMs := n
    SaveMappings()
}

; ---------------- Test ----------------
TestSend(*) {
    global currentMacroSteps
    if ddlActionType.Value = 2 {
        path := editAppPath.Value
        if path = "" {
            MsgBox("Enter an app/file path first.", "Nothing to launch", "Icon!")
            return
        }
        LaunchApp(path, editAppArgs.Value)
        txtStatus.Value := "Launched: " path
        return
    }
    if ddlActionType.Value = 3 {
        if currentMacroSteps.Length = 0 {
            MsgBox("Add at least one step with Edit Macro... first.", "Nothing to run", "Icon!")
            return
        }
        stepsCopy := currentMacroSteps
        ToolTip("Switch to a text field now`nRunning macro in 2 seconds...")
        SetTimer(() => TestSendRunMacro(stepsCopy), -2000)
        return
    }
    t := targetSendString
    if t = "" {
        MsgBox("Capture a target key/combo first.", "Nothing to send", "Icon!")
        return
    }
    ToolTip("Switch to a text field now`nSending in 2 seconds...")
    SetTimer(() => (ToolTip(), Send(t)), -2000)
}

TestSendRunMacro(steps) {
    ToolTip()
    RunMacroOnce(steps)
}

; ---------------- Persistence ----------------
; Small helper since AHK v2 has no built-in array-join.
JoinCsv(arr) {
    s := ""
    for i, v in arr {
        if i > 1
            s .= ","
        s .= v
    }
    return s
}

SaveMappings() {
    global profiles, appWatchEnabled, runElevated, runAtStartup
    try FileDelete(mapFile)
    IniWrite(masterEnabled ? "1" : "0", mapFile, "Settings", "MasterEnabled")
    IniWrite(startHidden ? "1" : "0", mapFile, "Settings", "StartHidden")
    IniWrite(longPressMs, mapFile, "Settings", "LongPressMs")
    IniWrite(appWatchEnabled ? "1" : "0", mapFile, "Settings", "AppWatchEnabled")
    IniWrite(runElevated ? "1" : "0", mapFile, "Settings", "RunElevated")
    IniWrite(runAtStartup ? "1" : "0", mapFile, "Settings", "RunAtStartup")
    IniWrite(runAtStartupMode, mapFile, "Settings", "RunAtStartupMode")
    ; Profile registry: which profiles exist, and (for non-Default ones) which
    ; process names activate them. Default isn't listed with a process list -
    ; it has none by definition - but IS listed in ProfileNames so an empty
    ; Default (zero mappings) still round-trips correctly.
    profileNamesList := []
    for pname, pdata in profiles
        profileNamesList.Push(pname)
    IniWrite(JoinCsv(profileNamesList), mapFile, "Settings", "ProfileNames")
    for pname, pdata in profiles {
        if pname = "Default"
            continue
        IniWrite(JoinCsv(pdata.processNames), mapFile, "Profile::" pname, "ProcessNames")
    }
    for key in mapOrder {
        m := mappings[key]
        kind := m.HasOwnProp("kind") ? m.kind : "sc"
        actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
        IniWrite(m.HasOwnProp("profile") ? m.profile : "Default", mapFile, key, "Profile")
        IniWrite(kind, mapFile, key, "Kind")
        IniWrite(actionType, mapFile, key, "ActionType")
        IniWrite(m.desc, mapFile, key, "Desc")
        IniWrite(m.target, mapFile, key, "Target")
        IniWrite(m.HasOwnProp("appArgs") ? m.appArgs : "", mapFile, key, "AppArgs")
        IniWrite(m.enabled ? "1" : "0", mapFile, key, "Enabled")
        IniWrite(m.HasOwnProp("pressType") ? m.pressType : "short", mapFile, key, "PressType")
        IniWrite(m.HasOwnProp("runMode") ? m.runMode : "single", mapFile, key, "RunMode")
        IniWrite(m.HasOwnProp("repeatMs") ? m.repeatMs : 100, mapFile, key, "RepeatMs")
        if actionType = "macro"
            IniWrite(MacroStepsEncode(m.HasOwnProp("macroSteps") ? m.macroSteps : []), mapFile, key, "MacroSteps")
        if kind = "raw" {
            IniWrite(m.page, mapFile, key, "Page")
            IniWrite(m.bytesHex, mapFile, key, "BytesHex")
        } else {
            ; Stored explicitly (not parsed from the section name) because ids
            ; for a button's 2nd/3rd+ mapping look like "SC01E#2", "SC01E#3".
            IniWrite(Format("{:X}", m.sc), mapFile, key, "ScHex")
        }
    }
}

LoadMappings() {
    global masterEnabled, mappings, mapOrder, startHidden, longPressMs
    global profiles, appWatchEnabled, runElevated, runAtStartup
    if !FileExist(mapFile)
        return
    masterEnabled := IniRead(mapFile, "Settings", "MasterEnabled", "1") = "1"
    startHidden := IniRead(mapFile, "Settings", "StartHidden", "0") = "1"
    longPressMs := Integer(IniRead(mapFile, "Settings", "LongPressMs", "500"))
    appWatchEnabled := IniRead(mapFile, "Settings", "AppWatchEnabled", "0") = "1"
    runElevated := IniRead(mapFile, "Settings", "RunElevated", "0") = "1"
    runAtStartup := IniRead(mapFile, "Settings", "RunAtStartup", "0") = "1"
    runAtStartupMode := IniRead(mapFile, "Settings", "RunAtStartupMode", "shortcut")

    ; Rebuild the profile registry. Files saved before this feature existed
    ; have no "ProfileNames" key, so this just leaves the default
    ; Default-only registry in place - the migration path below then folds
    ; every legacy mapping section into Default automatically.
    profiles := Map("Default", {processNames: []})
    profileNamesCsv := IniRead(mapFile, "Settings", "ProfileNames", "")
    for pname in StrSplit(profileNamesCsv, ",") {
        pname := Trim(pname)
        if pname = "" || pname = "Default"
            continue
        procCsv := IniRead(mapFile, "Profile::" pname, "ProcessNames", "")
        procList := []
        for p in StrSplit(procCsv, ",") {
            p := Trim(p)
            if p != ""
                procList.Push(p)
        }
        profiles[pname] := {processNames: procList}
    }

    sections := IniRead(mapFile)
    for section in StrSplit(sections, "`n", "`r") {
        if section = "" || section = "Settings" || SubStr(section, 1, 9) = "Profile::"
            continue
        kind := IniRead(mapFile, section, "Kind", "sc")
        actionType := IniRead(mapFile, section, "ActionType", "key")
        desc := IniRead(mapFile, section, "Desc", section)
        target := IniRead(mapFile, section, "Target", "")
        appArgs := IniRead(mapFile, section, "AppArgs", "")
        enabled := IniRead(mapFile, section, "Enabled", "1") = "1"
        pressType := IniRead(mapFile, section, "PressType", "short")
        runMode := IniRead(mapFile, section, "RunMode", "single")
        repeatMs := Integer(IniRead(mapFile, section, "RepeatMs", "100"))
        macroSteps := actionType = "macro" ? MacroStepsDecode(IniRead(mapFile, section, "MacroSteps", "")) : []
        profileVal := IniRead(mapFile, section, "Profile", "")
        ; Macro mappings have no Target of their own (their content lives in
        ; MacroSteps instead), so only treat an empty Target as "not a real
        ; mapping" for the other action types.
        if target = "" && actionType != "macro"
            continue
        ; Migration: a section with no "Profile" key predates this feature.
        ; Fold it into Default and give it a properly-prefixed id so the next
        ; save rewrites it in the current format.
        isLegacy := profileVal = ""
        mProfile := isLegacy ? "Default" : profileVal
        id := isLegacy ? ("Default::" section) : section
        if !profiles.Has(mProfile)
            profiles[mProfile] := {processNames: []}   ; guards against a hand-edited/corrupt ini
        if kind = "raw" {
            page := Integer(IniRead(mapFile, section, "Page", "0"))
            bytesHex := IniRead(mapFile, section, "BytesHex", "")
            mappings[id] := {profile: mProfile, kind: "raw", actionType: actionType, page: page, bytesHex: bytesHex, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, enabled: enabled, pressType: "short", runMode: "single", repeatMs: repeatMs}
            mapOrder.Push(id)
        } else {
            ; Prefer the explicitly-stored ScHex (needed for ids like "SC01E#2").
            ; Fall back to parsing the section name for mapping files saved by
            ; older versions that only ever had one mapping per button.
            scHexStr := IniRead(mapFile, section, "ScHex", "")
            if scHexStr = "" {
                base := section
                hashPos := InStr(base, "#")
                if hashPos
                    base := SubStr(base, 1, hashPos - 1)
                scHexStr := SubStr(base, 3)
            }
            sc := Integer("0x" scHexStr)
            mappings[id] := {profile: mProfile, kind: "sc", actionType: actionType, sc: sc, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, enabled: enabled, pressType: pressType, runMode: runMode, repeatMs: repeatMs}
            mapOrder.Push(id)
            RegisterHotkeyForButton(Format("SC{:03X}", sc))
        }
    }
    chkMaster.Value := masterEnabled
    if masterEnabled
        A_TrayMenu.Check("Remapping Enabled")
    else
        A_TrayMenu.Uncheck("Remapping Enabled")
    chkStartHidden.Value := startHidden
    if startHidden
        A_TrayMenu.Check("Start Hidden")
    else
        A_TrayMenu.Uncheck("Start Hidden")
    chkAppWatch.Value := appWatchEnabled
    if appWatchEnabled
        A_TrayMenu.Check("Enable App-Based Auto Profile Switching")
    else
        A_TrayMenu.Uncheck("Enable App-Based Auto Profile Switching")
    chkRunElevated.Value := runElevated
    chkRunStartup.Value := runAtStartup
    ddlRunStartupMode.Choose(runAtStartupMode = "admin" ? 2 : 1)
    ; Self-heal: if the setting says startup should be active but the
    ; underlying shortcut/task is missing (user deleted it by hand, or the
    ; ini was copied to a new PC), recreate it silently rather than leaving
    ; the checkbox and reality out of sync.
    if runAtStartup {
        if runAtStartupMode = "admin" {
            if !IsStartupTaskRegistered()
                SetStartupTask(true)
        } else {
            if !FileExist(StartupShortcutPath())
                CreateStartupShortcut()
        }
    }
    edLongPressMs.Value := longPressMs
}

; ---------------- Startup ----------------
chkMaster.Value := masterEnabled
chkStartHidden.Value := startHidden
chkAppWatch.Value := appWatchEnabled
chkRunElevated.Value := runElevated
chkRunStartup.Value := runAtStartup
ddlRunStartupMode.Choose(runAtStartupMode = "admin" ? 2 : 1)
edLongPressMs.Value := longPressMs
LoadMappings()
RefreshProfileList()   ; profiles registry is only known after LoadMappings has run
RegisterAllRawInputDevices()   ; enables raw-report mappings to fire even with no ini yet
RefreshList()
CheckActiveProfile()   ; establish the correct active profile immediately (in case AppWatchEnabled loaded as true and a matching app is already focused), rather than waiting up to 500ms
UpdateActiveProfileStatus()
SetTimer(CheckActiveProfile, 500)   ; poll every 500ms for foreground-app changes
if !startHidden
    ShowGui()
