#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

DllCall("winmm\timeBeginPeriod", "UInt", 1)


mapFile := A_ScriptDir "\remote_mappings.ini"
DataDir() => A_ScriptDir "\Data"
SettingsFile() => DataDir() "\settings.ini"
MacrosFile() => DataDir() "\macros.ini"
ProfilesDir() => DataDir() "\Profiles"

EnsureDataDirs() {
    try DirCreate(DataDir())
    try DirCreate(ProfilesDir())
}

SanitizeProfileFileName(name) {
    out := ""
    loop parse name {
        ch := A_LoopField
        code := Ord(ch)
        if code < 32 || InStr('\/:*?"<>|', ch)
            out .= "_"
        else
            out .= ch
    }
    while (out != "" && (SubStr(out, -1) = "." || SubStr(out, -1) = " "))
        out := SubStr(out, 1, StrLen(out) - 1)
    if out = ""
        out := "_"
    reserved := "CON PRN AUX NUL COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9"
    for r in StrSplit(reserved, " ") {
        if (out = r) {
            out := "_" out
            break
        }
    }
    return out
}

EnsureDataDirs()

RunAtStartupTaskName := "MF Button Mapper Startup"

MapKind(m)       => m.HasOwnProp("kind") ? m.kind : "sc"
MapProfile(m)    => m.HasOwnProp("profile") ? m.profile : "Default"
MapList(m)       => m.HasOwnProp("list") ? m.list : "Main"
MapActionType(m) => m.HasOwnProp("actionType") ? m.actionType : "key"

MakeRawButtonKey(page, bytesHex) => "RAW_" Format("{:X}", page) "_" bytesHex
KeyNameFor(VK, SC) => GetKeyName(Format("vk{:X}sc{:X}", VK, SC))

NewCaptureInputHook(onDown, onUp := (*) => {}) {
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := onDown
    ih.OnKeyUp := onUp
    ih.Start()
    return ih
}

StartupRunElevatedPref() {
    if FileExist(SettingsFile())
        return IniRead(SettingsFile(), "Settings", "RunElevated", "0")
    if FileExist(mapFile)
        return IniRead(mapFile, "Settings", "RunElevated", "0")
    return "0"
}
if StartupRunElevatedPref() = "1" && !A_IsAdmin
    RelaunchElevated()

mappings := Map()
mapOrder := []
masterEnabled := true
capturedSC := 0
startHidden := false
runElevated := false
runAtStartup := false
runAtStartupMode := "shortcut"
targetSendString := ""
captureHook := ""
captureSuspended := false

captureSuspendDepth := 0

profiles := Map("Default", {processNames: []})
activeProfileName := "Default"
editingProfileName := "Default"
appWatchEnabled := false
notifyModifierToggle := false
sendScrollLockOnModifierToggle := false

editingListName := "Main"

longPressMs := 500
buttonPressState := Map()

lvColW1 := 43
lvColW2 := 169
lvColW3 := 206
lvColW4 := 66
macroLvColW1 := 30
macroLvColW2 := 85
macroLvColW3 := 335
macroLvColW4 := 100

modifierKind := "none"
modifierSc := 0
modifierRawPage := 0
modifierRawBytesHex := ""
modifierMode := "hold"
modifierActive := false
modifierHotkeyRegisteredSc := 0
captureModifierRawMode := false
modifierCaptureHook := ""
modifierCaptureSuspended := false
modifierRawCaptureArmed := false
modifierRawUpBytesHex := ""
modifierRawCaptureAwaitingRelease := false
modifierRawCaptureDownHDevice := 0
modifierRawCaptureDownTick := 0
modifierRawCaptureReleaseWindowToken := 0

profileModCaptureHook := ""
profileModCaptureSuspended := false
profileModRawCaptureArmed := false
profileModCaptureCallback := ""
profileModCaptureStatusCallback := ""
profileModRawCaptureAwaitingRelease := false
profileModRawCaptureDownHDevice := 0
profileModRawCaptureDownTick := 0
profileModRawCaptureDownPage := 0
profileModRawCaptureDownBytesHex := ""
profileModRawCaptureReleaseWindowToken := 0

rawMapCaptureArmed := false
rawMapCaptureExpectedPage := 0
rawMapCaptureExpectedBytesHex := ""
rawMapCaptureCallback := ""
rawMapCaptureStatusCallback := ""
rawMapCaptureAwaitingRelease := false
rawMapCaptureDownHDevice := 0
rawMapCaptureDownTick := 0
rawMapCaptureReleaseWindowToken := 0

CancelPendingRawMapCapture() {
    global rawMapCaptureArmed, rawMapCaptureAwaitingRelease, rawMapCaptureCallback, rawMapCaptureStatusCallback
    rawMapCaptureArmed := false
    rawMapCaptureAwaitingRelease := false
    rawMapCaptureCallback := ""
    rawMapCaptureStatusCallback := ""
}

CancelPendingProfileModifierCapture() {
    global profileModCaptureHook, profileModRawCaptureArmed, profileModCaptureCallback
    global profileModCaptureStatusCallback, profileModRawCaptureAwaitingRelease
    if IsObject(profileModCaptureHook) {
        try profileModCaptureHook.Stop()
        profileModCaptureHook := ""
    }
    profileModRawCaptureArmed := false
    profileModRawCaptureAwaitingRelease := false
    profileModCaptureCallback := ""
    profileModCaptureStatusCallback := ""
    ResumeProfileModifierHotkeysIfNeeded()
}

ResumeProfileModifierHotkeysIfNeeded() {
    global profileModCaptureSuspended
    if profileModCaptureSuspended {
        DecrementCaptureSuspend()
        profileModCaptureSuspended := false
    }
}

EffectiveModifier(profileName) {
    global profiles, modifierKind, modifierSc, modifierRawPage, modifierRawBytesHex, modifierRawUpBytesHex, modifierMode
    if profiles.Has(profileName) {
        p := profiles[profileName]
        pk := p.HasOwnProp("modKind") ? p.modKind : "none"
        if pk != "none" && pk != ""
            return {kind: pk
                , sc: p.HasOwnProp("modSc") ? p.modSc : 0
                , rawPage: p.HasOwnProp("modRawPage") ? p.modRawPage : 0
                , rawBytesHex: p.HasOwnProp("modRawBytesHex") ? p.modRawBytesHex : ""
                , rawUpBytesHex: p.HasOwnProp("modRawUpBytesHex") ? p.modRawUpBytesHex : ""
                , mode: p.HasOwnProp("modMode") ? p.modMode : "hold"}
    }
    return {kind: modifierKind, sc: modifierSc, rawPage: modifierRawPage, rawBytesHex: modifierRawBytesHex, rawUpBytesHex: modifierRawUpBytesHex, mode: modifierMode}
}

repeatActive := Map()
repeatTimerFns := Map()
repeatStartQpc := Map()
repeatFireCount := Map()

QpcFreq() {
    static freq := 0
    if freq = 0 {
        DllCall("QueryPerformanceFrequency", "Int64*", &f := 0)
        freq := f
    }
    return freq
}

QpcNow() {
    DllCall("QueryPerformanceCounter", "Int64*", &t := 0)
    return t
}

currentMacroSteps := []

captureRawMode := false
rawCaptureArmed := false
capturedRawPage := 0
capturedRawBytesHex := ""
capturedRawUpBytesHex := ""
rawCaptureAwaitingRelease := false
rawCaptureDownHDevice := 0
rawCaptureDownTick := 0
rawCaptureReleaseWindowToken := 0
RawCaptureReleaseWindowMs := 3000
MinHoldReleaseGapMs := 100
lastCaptureKind := "sc"
editingId := ""

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
A_IconTip := "MF Button Mapper"

OnMessage(0x404, OnTrayMsg)
OnTrayMsg(wParam, lParam, msg, hwnd) {
    if (lParam = 0x203)
        ShowGui()
}

OnExit((*) => (SaveKeymapColumnWidths(), ReleaseAllHolds(), DllCall("winmm\timeEndPeriod", "UInt", 1)))

g := Gui("", "MF Button Mapper")
g.OnEvent("Close", (*) => (CancelPendingButtonCapture(), CancelPendingModifierCapture(), SaveKeymapColumnWidths(), g.Hide()))
g.SetFont("s10", "Segoe UI")

grpLearnButton := g.Add("GroupBox", "x8 y10 w572 h390", "Learn a button")
g.Add("Text", "x20 y30", "1. Click Capture, then press a button:")
btnCapture := g.Add("Button", "x20 y+8 w100", "Capture")
btnCapture.OnEvent("Click", StartCapture)
btnRawSniffer := g.Add("Button", "x+10 yp w130", "Raw HID Sniffer...")
btnRawSniffer.OnEvent("Click", OpenRawSniffer)
chkCaptureRaw := g.Add("Checkbox", "x20 y+6", "Capture raw HID event (use if the button isn't detected)")
chkCaptureRaw.OnEvent("Click", (*) => SetCaptureRawMode(chkCaptureRaw.Value))
txtCaptureStatus := g.Add("Text", "x20 y+8 w380", "Not captured yet.")

g.Add("Text", "x20 y+15", "Description:")
editDesc := g.Add("Edit", "x+10 w150")
g.Add("Text", "x+15", "Action:")
ddlActionType := g.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App", "Multimedia", "Mouse", "Macro"])
ddlActionType.OnEvent("Change", (*) => OnActionTypeChange())

lblSends := g.Add("Text", "x20 y+8", "Sends:")
txtTarget := g.Add("Edit", "x+10 w200 ReadOnly Background0xFFFFFF")
txtTarget.OnEvent("Focus", StartTargetCapture)
txtTarget.OnEvent("LoseFocus", StopTargetCapture)

lblSends.GetPos(&actionRow1X, &actionRow1Y, , &actionRow1H)

lblAppPath := g.Add("Text", "x20 y" actionRow1Y, "App/File path:")
editAppPath := g.Add("Edit", "x+10 w230")
btnBrowseApp := g.Add("Button", "x+8 w80", "Browse...")
btnBrowseApp.OnEvent("Click", (*) => BrowseForAppInto(editAppPath))

lblAppArgs := g.Add("Text", "x20 y+10", "Arguments (optional):")
editAppArgs := g.Add("Edit", "x+10 w220")
lblAppArgs.GetPos(&actionRow2X, &actionRow2Y)
editAppArgs.GetPos(, , , &actionRow2H)

lblMacroSelect := g.Add("Text", "x20 y" actionRow1Y, "Macro:")
ddlMacroSelect := g.Add("DropDownList", "x+10 w220 Choose1", ["(Custom / unsaved)"])
ddlMacroSelect.OnEvent("Change", OnMacroSelectChange)
btnEditMacro := g.Add("Button", "x+5 w70", "Macros")
btnEditMacro.OnEvent("Click", OnEditMacroClick)

lblMultimedia := g.Add("Text", "x20 y" actionRow1Y, "Multimedia action:")
ddlMultimedia := g.Add("DropDownList", "x+10 w200 Choose1", MultimediaNames())
ddlMultimedia.OnEvent("Change", OnMultimediaChange)

lblMouse := g.Add("Text", "x20 y" actionRow1Y, "Mouse action:")
ddlMouse := g.Add("DropDownList", "x+10 w200 Choose1", MouseNames())
ddlMouse.OnEvent("Change", OnMouseChange)

HoldOnlyTriggerIdx := [2, 3]
HoldOnlyRunModeIdx := [1, 3]

RegisterHoldDdl(ctrl, items, greyIdx0Based, checkFn) {
    ctrl.HoldItems := items
    ctrl.HoldGreyIdx := greyIdx0Based
    ctrl.HoldCheckFn := checkFn
}

RefreshHoldDdl(ctrl) {
    DllCall("InvalidateRect", "ptr", ctrl.Hwnd, "ptr", 0, "int", true)
}

EnforceHoldDdlSelection(ctrl, greyIdx0Based, checkFn, fallbackIdx1Based, afterFn := "") {
    if checkFn.Call() && HasVal(greyIdx0Based, ctrl.Value - 1) {
        ctrl.Choose(fallbackIdx1Based)
        if IsObject(afterFn)
            afterFn.Call()
    }
    RefreshHoldDdl(ctrl)
}

HasVal(arr, val) {
    for v in arr
        if v = val
            return true
    return false
}

ComboItemHeightForCtrl(hwndCtrl) {
    hDC := DllCall("GetDC", "ptr", hwndCtrl, "ptr")
    hFont := SendMessage(0x0031, 0, 0, , "ahk_id " hwndCtrl)
    hOldFont := hFont ? DllCall("SelectObject", "ptr", hDC, "ptr", hFont, "ptr") : 0
    tm := Buffer(64, 0)
    DllCall("GetTextMetricsW", "ptr", hDC, "ptr", tm)
    tmHeight := NumGet(tm, 0, "Int")
    if hOldFont
        DllCall("SelectObject", "ptr", hDC, "ptr", hOldFont)
    DllCall("ReleaseDC", "ptr", hwndCtrl, "ptr", hDC)
    return tmHeight + 6
}

DrawItemHwndOff := A_PtrSize = 8 ? 24 : 20
DrawItemHdcOff := DrawItemHwndOff + A_PtrSize
DrawItemRectOff := DrawItemHdcOff + A_PtrSize

OnDdlMeasureItem(wParam, lParam, msg, hwnd) {
    ctrlHwnd := DllCall("GetDlgItem", "ptr", hwnd, "int", wParam, "ptr")
    ctrl := ctrlHwnd ? GuiCtrlFromHwnd(ctrlHwnd) : ""
    if !ctrl || !ctrl.HasOwnProp("HoldItems")
        return
    NumPut("UInt", ComboItemHeightForCtrl(ctrlHwnd), lParam, 16)
    return 1
}

OnDdlDrawItem(wParam, lParam, msg, hwnd) {
    global DrawItemHwndOff, DrawItemHdcOff, DrawItemRectOff
    ctrl := GuiCtrlFromHwnd(NumGet(lParam, DrawItemHwndOff, "Ptr"))
    if !ctrl || !ctrl.HasOwnProp("HoldItems")
        return
    itemId := NumGet(lParam, 8, "UInt")
    itemState := NumGet(lParam, 16, "UInt")
    hDC := NumGet(lParam, DrawItemHdcOff, "Ptr")
    left := NumGet(lParam, DrawItemRectOff, "Int")
    top := NumGet(lParam, DrawItemRectOff + 4, "Int")
    right := NumGet(lParam, DrawItemRectOff + 8, "Int")
    bottom := NumGet(lParam, DrawItemRectOff + 12, "Int")

    items := ctrl.HoldItems
    text := (itemId != 0xFFFFFFFF && itemId + 1 <= items.Length) ? items[itemId + 1] : ""
    isSelected := (itemState & 0x0001) != 0
    isGreyed := ctrl.HoldCheckFn.Call() && HasVal(ctrl.HoldGreyIdx, itemId)

    bgColor := (isSelected && !isGreyed)
        ? DllCall("GetSysColor", "int", 13, "uint")
        : DllCall("GetSysColor", "int", 5, "uint")
    textColor := isGreyed
        ? DllCall("GetSysColor", "int", 17, "uint")
        : (isSelected ? DllCall("GetSysColor", "int", 14, "uint") : DllCall("GetSysColor", "int", 8, "uint"))

    hBrush := DllCall("CreateSolidBrush", "uint", bgColor, "ptr")
    rc := Buffer(16, 0)
    NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rc, 0)
    DllCall("FillRect", "ptr", hDC, "ptr", rc, "ptr", hBrush)
    DllCall("DeleteObject", "ptr", hBrush)

    DllCall("SetBkMode", "ptr", hDC, "int", 1)
    DllCall("SetTextColor", "ptr", hDC, "uint", textColor)
    NumPut("Int", left + 3, rc, 0)
    DllCall("DrawTextW", "ptr", hDC, "str", text, "int", -1, "ptr", rc, "uint", 0x0024)

    if (itemState & 0x0010) && !isGreyed
        DllCall("DrawFocusRect", "ptr", hDC, "ptr", rc)
    return 1
}
OnMessage(0x002B, OnDdlDrawItem)
OnMessage(0x002C, OnDdlMeasureItem)

firstOptionRowY := actionRow1Y + actionRow1H + 17
lblRunMode := g.Add("Text", "x20 y" firstOptionRowY, "Run mode:")
RunModeDdlItems := ["Single run", "Repeat while holding", "Toggle repeat (press to start/stop)", "Hold (send while held)", "Toggle Hold (press to start/stop)"]
ddlRunMode := g.Add("DropDownList", "x+10 w220 Choose1 +0x10", RunModeDdlItems)
ddlRunMode.OnEvent("Change", (*) => OnRunModeChange())
lblRepeatMs := g.Add("Text", "x+15", "Interval (ms):")
edRepeatMs := g.Add("Edit", "x+8 w60", "100")
appExtraRowShift := (actionRow2Y + actionRow2H) - (actionRow1Y + actionRow1H)
actionAreaExpanded := false

lblTrigger := g.Add("Text", "x20 y+12", "Trigger:")
PressTypeDdlItems := ["On press (immediate)", "On release (short tap)", "On long press (while held)", "On release (any duration)"]
ddlPressType := g.Add("DropDownList", "x+10 w230 Choose1 +0x10", PressTypeDdlItems)

IsMainCaptureSingleShot() {
    global lastCaptureKind, capturedRawUpBytesHex
    return lastCaptureKind = "raw" && capturedRawUpBytesHex = ""
}

RegisterHoldDdl(ddlPressType, PressTypeDdlItems, HoldOnlyTriggerIdx, IsMainCaptureSingleShot)
RegisterHoldDdl(ddlRunMode, RunModeDdlItems, HoldOnlyRunModeIdx, IsMainCaptureSingleShot)
ddlPressType.OnEvent("Change", (*) => EnforceHoldDdlSelection(ddlPressType, HoldOnlyTriggerIdx, IsMainCaptureSingleShot, DdlIndexFromPressType("short")))
ddlRunMode.OnEvent("Change", (*) => EnforceHoldDdlSelection(ddlRunMode, HoldOnlyRunModeIdx, IsMainCaptureSingleShot, 1, OnRunModeChange))

ReconcileMainHoldDdls() {
    global ddlPressType, ddlRunMode
    if IsMainCaptureSingleShot() {
        if HasVal(HoldOnlyRunModeIdx, ddlRunMode.Value - 1) {
            ddlRunMode.Choose(1)
            OnRunModeChange()
        }
        if HasVal(HoldOnlyTriggerIdx, ddlPressType.Value - 1)
            ddlPressType.Choose(DdlIndexFromPressType("short"))
    }
    RefreshHoldDdl(ddlPressType)
    RefreshHoldDdl(ddlRunMode)
}

btnAddNew := g.Add("Button", "x20 y+18 w110", "Add to Main")
btnAddNew.OnEvent("Click", (*) => SaveMapping(true, "Main"))
btnAddMod := g.Add("Button", "x+8 w100", "Add to Mod")
btnAddMod.OnEvent("Click", (*) => SaveMapping(true, "Mod"))
btnTest := g.Add("Button", "x+8 w90", "Test Send")
btnTest.OnEvent("Click", TestSend)
btnClearForm := g.Add("Button", "x+8 w70", "Clear")
btnClearForm.OnEvent("Click", (*) => ResetCaptureUI())
ResizeLearnButtonBox()
grpLearnButton.GetPos(&glbX, &glbY, &glbW, &glbH)
leftColBottomY := glbY + glbH + 15
leftColRight := glbX + glbW
rightColGap := 20
rightColX := leftColRight + rightColGap

lblProfilesHeader := g.Add("Text", "x" (rightColX + 12) " y20", "Profiles")
lblProfilesHeader.GetPos(&lphX, &lphY, &lphW, &lphH)
lbProfiles := g.Add("ListBox", "x" (rightColX + 12) " y+2 w150 r26", ["Default"])
lbProfiles.OnEvent("Change", (*) => OnEditingProfileChange())
lbProfiles.GetPos(&lbProfilesX, &lbProfilesY, &lbProfilesW, &lbProfilesH)

radListMain := g.Add("Radio", "x" (lbProfilesX + lbProfilesW + 10) " y" lphY " w90 +0x8 Group Checked", "Main")
radListMain.OnEvent("Click", (*) => SetEditingList("Main"))
radListMod := g.Add("Radio", "x+6 yp w90 +0x8", "Mod")
radListMod.OnEvent("Click", (*) => SetEditingList("Mod"))
radListMain.GetPos(&lbmX, &lbmY, &lbmW, &lbmH)

lvTopY := lbProfilesY
radRowY := lvTopY - lbmH - 6

lblKeymapsHeader := g.Add("Text", "x" (lbProfilesX + lbProfilesW + 10) " y" radRowY, "Keymaps")
lblKeymapsHeader.GetPos(&lkhX, &lkhY, &lkhW, &lkhH)

radListMain.Move(lkhX + lkhW + 10, radRowY)
radListMod.Move(lkhX + lkhW + 10 + lbmW + 6, radRowY)
lv := g.Add("ListView", "x" (lbProfilesX + lbProfilesW + 10) " y" lvTopY " w484 h" (lbProfilesY + lbProfilesH - lvTopY), ["On", "Remote Button", "Sends", "Mode"])
lv.OnEvent("ItemSelect", LVSelect)
lv.OnEvent("ContextMenu", LVContextMenu)
lv.OnEvent("DoubleClick", OnKeymapDoubleClick)
lv.ModifyCol(1, lvColW1)
lv.ModifyCol(2, lvColW2)
lv.ModifyCol(3, lvColW3)
lv.ModifyCol(4, lvColW4)
lv.GetPos(&lvX, &lvY, &lvW, &lvH)

profileBtnGap := 3
profileBtnW := (lbProfilesW - 2 * profileBtnGap) // 3
newBtnW := Round(profileBtnW * 0.8)
renameBtnW := Round(profileBtnW * 1.2)
deleteBtnW := profileBtnW
btnNewProfile := g.Add("Button", "x" lbProfilesX " y" (lbProfilesY + lbProfilesH + 10) " w" newBtnW, "New")
btnNewProfile.OnEvent("Click", (*) => OpenProfileDialog("new"))
btnRenameProfile := g.Add("Button", "x+" profileBtnGap " yp w" renameBtnW, "Edit")
btnRenameProfile.OnEvent("Click", (*) => OpenProfileDialog("rename"))
btnDeleteProfile := g.Add("Button", "x+" profileBtnGap " yp w" deleteBtnW, "Delete")
btnDeleteProfile.OnEvent("Click", (*) => DeleteProfileFlow())
btnDeleteProfile.GetPos(&dpX, &dpY, &dpW, &dpH)

btnUpdate := g.Add("Button", "x" lvX " y" (lvY + lvH + 10) " w110", "Update Mapping")
btnUpdate.OnEvent("Click", (*) => SaveMapping(false))
btnToggle := g.Add("Button", "x+10", "Enable/Disable")
btnToggle.OnEvent("Click", ToggleSelected)
btnMacros := g.Add("Button", "x+10", "Macros")
btnMacros.OnEvent("Click", (*) => OpenMacroEditor([], (*) => ""))
btnMoveKeymapUp := g.Add("Button", "x+10 w30", "⌃")
btnMoveKeymapUp.OnEvent("Click", (*) => MoveKeymapRow(-1))
btnMoveKeymapDown := g.Add("Button", "x+2 w30", "⌄")
btnMoveKeymapDown.OnEvent("Click", (*) => MoveKeymapRow(1))
btnRemove := g.Add("Button", "x+10", "Remove")
btnRemove.OnEvent("Click", RemoveSelected)
btnRemove.GetPos(&rmX, &rmY, &rmW, &rmH)

belowProfileColsY := Max(dpY + dpH, rmY + rmH) + 15

grpModifier := g.Add("GroupBox", "x" rightColX " y" belowProfileColsY " w656 h95", "Modifier Button (Main/Mod)")
btnCaptureModifier := g.Add("Button", "x" (rightColX + 12) " y" (belowProfileColsY + 20) " w130", "Capture Modifier")
btnCaptureModifier.OnEvent("Click", StartModifierCapture)
chkCaptureModifierRaw := g.Add("Checkbox", "x+15 yp+4", "Capture as raw HID")
chkCaptureModifierRaw.OnEvent("Click", (*) => SetCaptureModifierRawMode(chkCaptureModifierRaw.Value))
g.Add("Text", "x+20 yp", "Mode:")
ddlModifierMode := g.Add("DropDownList", "x+8 yp-4 w100 Choose1", ["Held", "Toggled"])
ddlModifierMode.OnEvent("Change", (*) => OnModifierModeChange())
chkNotifyModifierToggle := g.Add("Checkbox", "x" (rightColX + 12) " y+10", "Show notification when modifier is toggled")
chkNotifyModifierToggle.OnEvent("Click", (*) => SetNotifyModifierToggle(chkNotifyModifierToggle.Value))
chkSendScrollLockOnModifierToggle := g.Add("Checkbox", "x" (rightColX + 12) " y+6", "Send scroll lock press on modifier toggle (indicator of Mod maps being active)")
chkSendScrollLockOnModifierToggle.OnEvent("Click", (*) => SetSendScrollLockOnModifierToggle(chkSendScrollLockOnModifierToggle.Value))
txtModifierStatus := g.Add("Text", "x" (rightColX + 12) " y+10 w628", "Modifier: not set")
ResizeModifierGroupBox()

chkStartHidden := g.Add("Checkbox", "x20 y" leftColBottomY, "Start hidden in systray (don't show this window on launch)")
chkStartHidden.OnEvent("Click", (*) => SetStartHidden(chkStartHidden.Value))
chkMaster := g.Add("Checkbox", "x20 y+8", "Remapping enabled")
chkMaster.OnEvent("Click", (*) => SetMasterEnabled(chkMaster.Value))

chkAppWatch := g.Add("Checkbox", "x20 y+10", "Enable app-based auto profile switching")
chkAppWatch.OnEvent("Click", (*) => SetAppWatchEnabled(chkAppWatch.Value))

chkRunElevated := g.Add("Checkbox", "x20 y+10", "Run elevated (Administrator)")
chkRunElevated.OnEvent("Click", (*) => SetRunElevated(chkRunElevated.Value))
lblElevatedInfo := g.Add("Text", "x38 y+2 w" (leftColRight - 38) " cGray", "Fixes mappings getting blocked by system apps with special permissions.")

chkRunStartup := g.Add("Checkbox", "x20 y+10", "Run on startup")
chkRunStartup.OnEvent("Click", (*) => SetRunAtStartup(chkRunStartup.Value))
ddlRunStartupMode := g.Add("DropDownList", "x+10 yp-2 w220", ["Shortcut in shell:startup", "As admin (Task Scheduler)"])
ddlRunStartupMode.Choose(1)
ddlRunStartupMode.OnEvent("Change", (*) => OnRunStartupModeChange())

lblLongPress := g.Add("Text", "x20 y+12", "Long press threshold (ms):")
edLongPressMs := g.Add("Edit", "x+10 w70", String(longPressMs))
edLongPressMs.OnEvent("Change", (*) => OnLongPressMsChange())

txtStatus := g.Add("Text", "x20 y+15 w" (leftColRight - 20), "Ready.")
txtActiveProfile := g.Add("Text", "x20 y+8 w" (leftColRight - 20), "Active profile: Default")
txtModifierActive := g.Add("Text", "x20 y+8 w" (leftColRight - 20), "Modifier: off")

controlsBelowActionRow := [lblTrigger, ddlPressType, lblRunMode, ddlRunMode, lblRepeatMs, edRepeatMs,
    btnAddNew, btnAddMod, btnTest, btnClearForm,
    chkStartHidden, chkMaster, chkAppWatch, chkRunElevated, lblElevatedInfo,
    chkRunStartup, ddlRunStartupMode,
    lblLongPress, edLongPressMs, txtStatus, txtActiveProfile, txtModifierActive]

ResizeLearnButtonBox() {
    global grpLearnButton, btnClearForm
    btnClearForm.GetPos(&bcx, &bcy, &bcw, &bch)
    grpLearnButton.GetPos(&gbx, &gby, &gbw, &gbh)
    newBottom := bcy + bch + 15
    maxRight := 0
    for ctrl in [btnRawSniffer, chkCaptureRaw, txtCaptureStatus, ddlActionType,
        txtTarget, btnBrowseApp, editAppArgs, btnEditMacro, ddlMultimedia, ddlMouse,
        ddlPressType, edRepeatMs, btnClearForm] {
        ctrl.GetPos(&crx, , &crw)
        right := crx + crw
        if right > maxRight
            maxRight := right
    }
    newWidth := maxRight - gbx + 15
    grpLearnButton.Move(, , newWidth, newBottom - gby)
}

ResizeModifierGroupBox() {
    global grpModifier, txtModifierStatus
    txtModifierStatus.GetPos(&lrX, &lrY, &lrW, &lrH)
    grpModifier.GetPos(&gmX, &gmY, &gmW, &gmH)
    newBottom := lrY + lrH + 15
    grpModifier.Move(, , gmW, newBottom - gmY)
}

ReflowActionAreaForType(deltaY) {
    global controlsBelowActionRow, g
    if deltaY = 0
        return
    for ctrl in controlsBelowActionRow {
        ctrl.GetPos(&cx, &cy)
        ctrl.Move(, cy + deltaY)
    }
    ResizeLearnButtonBox()
    g.GetPos(&gx, &gy, &gw, &gh)
    g.Move(gx, gy, gw, gh + deltaY)
    DllCall("RedrawWindow", "ptr", g.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0004 | 0x0080 | 0x0100)
}

OnActionTypeChange(*) {
    global actionAreaExpanded, appExtraRowShift
    isApp := ddlActionType.Value = 2
    isMultimedia := ddlActionType.Value = 3
    isMouse := ddlActionType.Value = 4
    isMacro := ddlActionType.Value = 5
    isKey := !isApp && !isMacro && !isMultimedia && !isMouse
    lblSends.Visible := isKey
    txtTarget.Visible := isKey
    lblAppPath.Visible := isApp
    editAppPath.Visible := isApp
    btnBrowseApp.Visible := isApp
    lblAppArgs.Visible := isApp
    editAppArgs.Visible := isApp
    lblMacroSelect.Visible := isMacro
    ddlMacroSelect.Visible := isMacro
    btnEditMacro.Visible := isMacro
    lblMultimedia.Visible := isMultimedia
    ddlMultimedia.Visible := isMultimedia
    lblMouse.Visible := isMouse
    ddlMouse.Visible := isMouse
    if isMultimedia
        OnMultimediaChange()
    if isMouse
        OnMouseChange()
    if isApp && !actionAreaExpanded {
        ReflowActionAreaForType(appExtraRowShift)
        actionAreaExpanded := true
    } else if !isApp && actionAreaExpanded {
        ReflowActionAreaForType(-appExtraRowShift)
        actionAreaExpanded := false
    }
}
OnActionTypeChange()

OnMultimediaChange(*) {
    global targetSendString
    targetSendString := MultimediaSendForIndex(ddlMultimedia.Value)
    txtCaptureStatus.Value := "Multimedia action: " ddlMultimedia.Text
}

OnMouseChange(*) {
    global targetSendString
    targetSendString := MouseSendForIndex(ddlMouse.Value)
    txtCaptureStatus.Value := "Mouse action: " ddlMouse.Text
}

OnRunModeChange(*) {
    isSingle := ddlRunMode.Value = 1
    showRepeatMs := (ddlRunMode.Value = 2 || ddlRunMode.Value = 3)
    lblRepeatMs.Visible := showRepeatMs
    edRepeatMs.Visible := showRepeatMs
    ddlPressType.Visible := isSingle
    if !isSingle
        ddlPressType.Choose(DdlIndexFromPressType("short"))
}
OnRunModeChange()

PressTypeFromDdlIndex(idx) {
    return idx = 1 ? "press" : (idx = 3 ? "long" : (idx = 4 ? "release" : "short"))
}
DdlIndexFromPressType(pt) {
    return pt = "press" ? 1 : (pt = "long" ? 3 : (pt = "release" ? 4 : 2))
}

OnEditMacroClick(*) {
    global currentMacroSteps
    OpenMacroEditor(currentMacroSteps, SaveMacroStepsFromMainEditor)
}

SaveMacroStepsFromMainEditor(steps) {
    global currentMacroSteps
    currentMacroSteps := steps
    UpdateMacroSelectDdl()
}

OnMacroSelectChange(*) {
    global currentMacroSteps, savedMacros, savedMacroOrder, ddlMacroSelect
    idx := ddlMacroSelect.Value
    if idx <= 1
        return
    name := savedMacroOrder[idx - 1]
    if !savedMacros.Has(name)
        return
    currentMacroSteps := CloneMacroSteps(savedMacros[name])
}

UpdateMacroSelectDdl() {
    global currentMacroSteps, savedMacroOrder, ddlMacroSelect
    items := ["(Custom / unsaved)"]
    for name in savedMacroOrder
        items.Push(name)
    ddlMacroSelect.Delete()
    ddlMacroSelect.Add(items)
    matchIdx := 1
    matchName := FindSavedMacroNameForSteps(currentMacroSteps)
    if matchName != "" {
        for i, name in savedMacroOrder {
            if name = matchName {
                matchIdx := i + 1
                break
            }
        }
    }
    ddlMacroSelect.Choose(matchIdx)
}

BrowseForAppInto(editCtrl) {
    file := FileSelect(, , "Select application or file", "Executables (*.exe)")
    if file != ""
        editCtrl.Value := file
}

ShowGui() {
    g.Show()
}

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

IncrementCaptureSuspend() {
    global captureSuspendDepth
    captureSuspendDepth += 1
    if (captureSuspendDepth = 1)
        Suspend(1)
}

DecrementCaptureSuspend() {
    global captureSuspendDepth
    if (captureSuspendDepth <= 0)
        return
    captureSuspendDepth -= 1
    if (captureSuspendDepth = 0)
        Suspend(0)
}

ResumeButtonHotkeysIfNeeded() {
    global captureSuspended
    if captureSuspended {
        DecrementCaptureSuspend()
        captureSuspended := false
    }
}

CancelPendingButtonCapture() {
    global captureHook, targetCaptureHook
    if IsObject(captureHook) {
        try captureHook.Stop()
        captureHook := ""
    }
    if IsObject(targetCaptureHook) {
        try targetCaptureHook.Stop()
        targetCaptureHook := ""
    }
    ResumeButtonHotkeysIfNeeded()
}

StartCapture(*) {
    global captureRawMode, rawCaptureArmed, captureHook, captureSuspended
    if IsObject(captureHook) {
        try captureHook.Stop()
        captureHook := ""
    }
    ResumeButtonHotkeysIfNeeded()
    if captureRawMode {
        rawCaptureArmed := false
        txtCaptureStatus.Value := "Get ready... (waiting for your click to finish)"
        SetTimer(ArmRawCapture, -300)
        return
    }
    IncrementCaptureSuspend()
    captureSuspended := true
    txtCaptureStatus.Value := "Waiting for button press..."
    captureHook := NewCaptureInputHook(OnCaptureKey)
}

ArmRawCapture() {
    global rawCaptureArmed
    rawCaptureArmed := true
    txtCaptureStatus.Value := "Waiting for button press (raw HID)..."
}

FinalizeRawCapture(token) {
    global rawCaptureAwaitingRelease, rawCaptureReleaseWindowToken, capturedRawUpBytesHex, capturedRawPage, capturedRawBytesHex
    if !rawCaptureAwaitingRelease || token != rawCaptureReleaseWindowToken
        return
    rawCaptureAwaitingRelease := false
    capturedRawUpBytesHex := ""
    if IsObject(txtCaptureStatus) {
        txtCaptureStatus.Value := Format("Captured: Page:0x{:X} Bytes:{} - Single shot", capturedRawPage, capturedRawBytesHex)
        ReconcileMainHoldDdls()
    }
}

FinalizeModifierRawCapture(token) {
    global modifierRawCaptureAwaitingRelease, modifierRawCaptureReleaseWindowToken, modifierRawUpBytesHex
    if !modifierRawCaptureAwaitingRelease || token != modifierRawCaptureReleaseWindowToken
        return
    modifierRawCaptureAwaitingRelease := false
    modifierRawUpBytesHex := ""
    CompleteModifierRawCaptureConfig()
}

CompleteModifierRawCaptureConfig() {
    RefreshModifierStatusText()
    UpdateModifierModeUI()
    RegisterModifierHotkey()
    SaveMappings()
}

FinalizeProfileModifierRawCapture(token) {
    global profileModRawCaptureAwaitingRelease, profileModRawCaptureReleaseWindowToken
    if !profileModRawCaptureAwaitingRelease || token != profileModRawCaptureReleaseWindowToken
        return
    profileModRawCaptureAwaitingRelease := false
    CompleteProfileModifierRawCaptureConfig("")
}

CompleteProfileModifierRawCaptureConfig(upBytesHex) {
    global profileModCaptureCallback, profileModCaptureStatusCallback, profileModRawCaptureDownPage, profileModRawCaptureDownBytesHex
    if IsObject(profileModCaptureCallback)
        profileModCaptureCallback.Call(profileModRawCaptureDownPage, profileModRawCaptureDownBytesHex, upBytesHex)
    profileModCaptureCallback := ""
    profileModCaptureStatusCallback := ""
    ResumeProfileModifierHotkeysIfNeeded()
}

FinalizeRawMapCapture(token) {
    global rawMapCaptureAwaitingRelease, rawMapCaptureReleaseWindowToken
    if !rawMapCaptureAwaitingRelease || token != rawMapCaptureReleaseWindowToken
        return
    rawMapCaptureAwaitingRelease := false
    CompleteRawMapCaptureConfig("")
}

CompleteRawMapCaptureConfig(upBytesHex) {
    global rawMapCaptureCallback, rawMapCaptureStatusCallback
    if IsObject(rawMapCaptureCallback)
        rawMapCaptureCallback.Call(upBytesHex)
    rawMapCaptureCallback := ""
    rawMapCaptureStatusCallback := ""
}

SetCaptureModifierRawMode(val) {
    global captureModifierRawMode
    captureModifierRawMode := !!val
}

CancelPendingModifierCapture() {
    global modifierCaptureHook
    if IsObject(modifierCaptureHook) {
        try modifierCaptureHook.Stop()
        modifierCaptureHook := ""
    }
    ResumeModifierHotkeysIfNeeded()
}

ResumeModifierHotkeysIfNeeded() {
    global modifierCaptureSuspended
    if modifierCaptureSuspended {
        DecrementCaptureSuspend()
        modifierCaptureSuspended := false
    }
}

StartModifierCapture(*) {
    global captureModifierRawMode, modifierRawCaptureArmed, modifierCaptureHook, modifierCaptureSuspended
    if IsObject(modifierCaptureHook) {
        try modifierCaptureHook.Stop()
        modifierCaptureHook := ""
    }
    ResumeModifierHotkeysIfNeeded()
    if captureModifierRawMode {
        modifierRawCaptureArmed := false
        txtModifierStatus.Value := "Get ready... (waiting for your click to finish)"
        SetTimer(ArmModifierRawCapture, -300)
        return
    }
    IncrementCaptureSuspend()
    modifierCaptureSuspended := true
    txtModifierStatus.Value := "Waiting for button press..."
    modifierCaptureHook := NewCaptureInputHook(OnModifierCaptureKey)
}

ArmModifierRawCapture() {
    global modifierRawCaptureArmed
    modifierRawCaptureArmed := true
    txtModifierStatus.Value := "Waiting for button press (raw HID)..."
}

OnModifierCaptureKey(ihObj, VK, SC) {
    global modifierKind, modifierSc, modifierRawPage, modifierRawBytesHex, modifierRawUpBytesHex
    ihObj.Stop()
    modifierKind := "sc"
    modifierSc := SC
    modifierRawPage := 0
    modifierRawBytesHex := ""
    modifierRawUpBytesHex := ""
    RefreshModifierStatusText()
    UpdateModifierModeUI()
    RegisterModifierHotkey()
    SaveMappings()
    ResumeModifierHotkeysIfNeeded()
}

RefreshModifierStatusText() {
    global modifierKind, modifierSc, modifierRawPage, modifierRawBytesHex, modifierRawUpBytesHex
    if modifierKind = "sc"
        txtModifierStatus.Value := Format("Modifier: SC{:03X}", modifierSc)
    else if modifierKind = "raw" {
        holdNote := modifierRawUpBytesHex != "" ? Format(" - hold-capable (release: Bytes:{})", modifierRawUpBytesHex) : " - Toggle-only (no distinct release report detected)"
        txtModifierStatus.Value := Format("Modifier: Raw Page:0x{:X} Bytes:{}{}", modifierRawPage, modifierRawBytesHex, holdNote)
    } else
        txtModifierStatus.Value := "Modifier: not set"
}

UpdateModifierModeUI() {
    global modifierKind, modifierMode, modifierRawUpBytesHex
    if modifierKind = "raw" && modifierRawUpBytesHex = "" {
        modifierMode := "toggle"
        ddlModifierMode.Choose(2)
        ddlModifierMode.Enabled := false
    } else {
        ddlModifierMode.Enabled := true
        ddlModifierMode.Choose(modifierMode = "toggle" ? 2 : 1)
    }
}

RefreshModifierLiveIndicator() {
    global modifierActive, activeProfileName
    if !IsObject(txtModifierActive)
        return
    if !modifierActive {
        txtModifierActive.Value := "Modifier: off"
        return
    }
    effMod := EffectiveModifier(activeProfileName)
    effectiveMode := (effMod.kind = "raw") ? "toggle" : effMod.mode
    txtModifierActive.Value := "Modifier: ON (" (effectiveMode = "toggle" ? "toggled" : "held") ")"
}

OnModifierModeChange(*) {
    global modifierMode
    modifierMode := ddlModifierMode.Value = 2 ? "toggle" : "hold"
    RegisterModifierHotkey()
    SaveMappings()
}

IsModifierVK(vk) {
    return vk = 0x10 || vk = 0x11 || vk = 0x12 || vk = 0x5B || vk = 0x5C
        || (vk >= 0xA0 && vk <= 0xA5)
}

ModPrefixForVK(vk) {
    if (vk = 0x10 || vk = 0xA0 || vk = 0xA1)
        return "+"
    if (vk = 0x11 || vk = 0xA2 || vk = 0xA3)
        return "^"
    if (vk = 0x12 || vk = 0xA4 || vk = 0xA5)
        return "!"
    if (vk = 0x5B || vk = 0x5C)
        return "#"
    return ""
}

MultimediaOptions() {
    static opts := [
        {name: "Volume Up", send: "{Volume_Up}"},
        {name: "Volume Down", send: "{Volume_Down}"},
        {name: "Mute", send: "{Volume_Mute}"},
        {name: "Play / Pause", send: "{Media_Play_Pause}"},
        {name: "Stop", send: "{Media_Stop}"},
        {name: "Next Track", send: "{Media_Next}"},
        {name: "Previous Track", send: "{Media_Prev}"},
        {name: "Launch Media Player", send: "{Launch_Media}"},
        {name: "Launch Mail", send: "{Launch_Mail}"},
        {name: "Launch App 1", send: "{Launch_App1}"},
        {name: "Launch App 2", send: "{Launch_App2}"},
        {name: "Browser Back", send: "{Browser_Back}"},
        {name: "Browser Forward", send: "{Browser_Forward}"},
        {name: "Browser Refresh", send: "{Browser_Refresh}"},
        {name: "Browser Stop", send: "{Browser_Stop}"},
        {name: "Browser Search", send: "{Browser_Search}"},
        {name: "Browser Favorites", send: "{Browser_Favorites}"},
        {name: "Browser Home", send: "{Browser_Home}"}
    ]
    return opts
}

MultimediaNames() {
    names := []
    for o in MultimediaOptions()
        names.Push(o.name)
    return names
}

MultimediaSendForIndex(idx) {
    opts := MultimediaOptions()
    if idx >= 1 && idx <= opts.Length
        return opts[idx].send
    return ""
}

MultimediaIndexForSend(sendStr) {
    opts := MultimediaOptions()
    for idx, o in opts
        if o.send = sendStr
            return idx
    return 0
}

MouseOptions() {
    static opts := [
        {name: "Left Click", send: "{LButton}"},
        {name: "Right Click", send: "{RButton}"},
        {name: "Middle Click", send: "{MButton}"},
        {name: "Double Left Click", send: "{LButton 2}"},
        {name: "Mouse Button 4 (Back)", send: "{XButton1}"},
        {name: "Mouse Button 5 (Forward)", send: "{XButton2}"},
        {name: "Scroll Up", send: "{WheelUp}"},
        {name: "Scroll Down", send: "{WheelDown}"},
        {name: "Scroll Left", send: "{WheelLeft}"},
        {name: "Scroll Right", send: "{WheelRight}"}
    ]
    return opts
}

MouseNames() {
    names := []
    for o in MouseOptions()
        names.Push(o.name)
    return names
}

MouseSendForIndex(idx) {
    opts := MouseOptions()
    if idx >= 1 && idx <= opts.Length
        return opts[idx].send
    return ""
}

MouseIndexForSend(sendStr) {
    opts := MouseOptions()
    for idx, o in opts
        if o.send = sendStr
            return idx
    return 0
}

FormatSendKey(keyName) {
    if StrLen(keyName) = 1 {
        if InStr("^!+#{}", keyName)
            return "{" keyName "}"
        return keyName
    }
    return "{" keyName "}"
}

KeyDisplayName(keyName) {
    static names := Map(
        "LWin", "Win", "RWin", "Win",
        "LControl", "Ctrl", "RControl", "Ctrl", "Control", "Ctrl",
        "LShift", "Shift", "RShift", "Shift",
        "LAlt", "Alt", "RAlt", "Alt",
        "Volume_Up", "Volume Up", "Volume_Down", "Volume Down", "Volume_Mute", "Mute",
        "Media_Play_Pause", "Play/Pause", "Media_Stop", "Media Stop",
        "Media_Next", "Next Track", "Media_Prev", "Previous Track",
        "Launch_Media", "Launch Media Player", "Launch_Mail", "Launch Mail",
        "Launch_App1", "Launch App 1", "Launch_App2", "Launch App 2",
        "Browser_Back", "Browser Back", "Browser_Forward", "Browser Forward",
        "Browser_Refresh", "Browser Refresh", "Browser_Stop", "Browser Stop",
        "Browser_Search", "Browser Search", "Browser_Favorites", "Browser Favorites",
        "Browser_Home", "Browser Home",
        "LButton", "Left Click", "LButton 2", "Double Left Click", "RButton", "Right Click", "MButton", "Middle Click",
        "XButton1", "Mouse Button 4", "XButton2", "Mouse Button 5",
        "WheelUp", "Scroll Up", "WheelDown", "Scroll Down",
        "WheelLeft", "Scroll Left", "WheelRight", "Scroll Right")
    return names.Has(keyName) ? names[keyName] : keyName
}

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
        keyLabel := StrUpper(rest)
    parts := modNames
    if keyLabel != ""
        parts.Push(keyLabel)
    label := ""
    for idx, p in parts
        label .= (idx = 1 ? "" : "+") p
    return label
}

FinalizeTarget(modStr, keyName) {
    global targetSendString
    targetSendString := modStr FormatSendKey(keyName)
    txtTarget.Value := HumanizeSendKey(targetSendString)
    txtCaptureStatus.Value := "Captured target key: " HumanizeSendKey(targetSendString) " (still listening - press another key to change it, or click away to stop)"
}

targetHeldMods := Map()
targetComboFired := false

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
        return
    }
    keyName := KeyNameFor(VK, SC)
    FinalizeTarget(BuildModStrFromHeld(targetHeldMods), keyName)
    targetComboFired := true
}

OnTargetKeyUp(ihObj, VK, SC) {
    global targetHeldMods, targetComboFired
    if !IsModifierVK(VK)
        return
    targetHeldMods.Delete(VK)
    allModsUp := (targetHeldMods.Count = 0)
    if targetComboFired {
        if allModsUp
            targetComboFired := false
        return
    }
    if !allModsUp
        return
    keyName := KeyNameFor(VK, SC)
    FinalizeTarget("", keyName)
}

targetCaptureHook := ""
StartTargetCapture(*) {
    global targetCaptureHook, targetComboFired, targetHeldMods, captureSuspended
    if IsObject(targetCaptureHook) {
        try targetCaptureHook.Stop()
    }
    ResumeButtonHotkeysIfNeeded()
    IncrementCaptureSuspend()
    captureSuspended := true
    targetComboFired := false
    targetHeldMods := Map()
    txtTarget.Value := ""
    txtCaptureStatus.Value := "Waiting for target key/combo... (press it now, e.g. Space, Win, Ctrl+Alt+S)"
    targetCaptureHook := NewCaptureInputHook(OnTargetKeyDown, OnTargetKeyUp)
}

StopTargetCapture(*) {
    global targetCaptureHook, targetSendString
    if IsObject(targetCaptureHook) {
        try targetCaptureHook.Stop()
        targetCaptureHook := ""
    }
    ResumeButtonHotkeysIfNeeded()
    txtTarget.Value := HumanizeSendKey(targetSendString)
    if targetSendString != ""
        txtCaptureStatus.Value := "Captured target key: " HumanizeSendKey(targetSendString)
}

NowStamp() {
    return FormatTime(A_Now, "HH:mm:ss") "." Format("{:03}", A_MSec)
}

IsGenuineHoldRelease(downTick) {
    global MinHoldReleaseGapMs
    return (A_TickCount - downTick) >= MinHoldReleaseGapMs
}

RIDEV_INPUTSINK := 0x00000100
rawSniffing := false
gRaw := ""
lstRawLog := ""
gRawStartBtn := ""

OpenRawSniffer(*) {
    global gRaw, lstRawLog, gRawStartBtn
    if IsObject(gRaw) {
        gRaw.Show()
        return
    }
    gRaw := Gui("", "Raw HID Sniffer")
    gRaw.OnEvent("Close", StopSniffingOnClose)
    gRaw.SetFont("s9", "Consolas")
    gRaw.Add("Text", "w600", "Click Start, then press the remote button. Raw reports from ALL connected HID collections (keyboard, consumer control, vendor-defined, etc.) are logged below.")
    btnStart := gRaw.Add("Button", "w130", "Start Sniffing")
    btnStart.OnEvent("Click", (*) => ToggleSniffing(btnStart))
    gRawStartBtn := btnStart
    btnClear := gRaw.Add("Button", "x+10 w100", "Clear Log")
    btnClear.OnEvent("Click", ClearRawLog)
    btnMapSelected := gRaw.Add("Button", "x+10 w170", "Map Selected to Key...")
    btnMapSelected.OnEvent("Click", MapSelectedRawLine)
    lstRawLog := gRaw.Add("ListBox", "x10 y+10 w600 h350")
    gRaw.Show()
}

StopSniffingOnClose(*) {
    global rawSniffing, gRaw, gRawStartBtn
    rawSniffing := false
    if IsObject(gRawStartBtn)
        gRawStartBtn.Text := "Start Sniffing"
    gRaw.Hide()
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
        info := GetRawDeviceInfo(hDevice)
        if !info
            continue
        if info.usagePage = 0x01 && info.usage = 0x06 {
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
            g_regLog.Push(NowStamp() " [Registered] " tag)
        } else {
            g_regLog.Push(NowStamp() " [FAILED] " tag " LastError:" A_LastError)
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
    if dwType = 0
        return {usagePage: 0x01, usage: 0x02}
    if dwType = 1
        return {usagePage: 0x01, usage: 0x06}
    return {usagePage: NumGet(buf, 20, "UShort"), usage: NumGet(buf, 22, "UShort")}
}

StrJoin(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i = 1 ? "" : sep) v
    return out
}

LogRawSniffEvent(line, rowData) {
    global rawSniffing, lstRawLog, g_rawLogCount, g_rawLogData
    if !(rawSniffing && IsObject(lstRawLog))
        return
    lstRawLog.Add([NowStamp() " " line])
    g_rawLogData.Push(rowData)
    g_rawLogCount++
    lstRawLog.Choose(g_rawLogCount)
}

OnRawInput(wParam, lParam, msg, hwnd) {
    global mapOrder, mappings, masterEnabled
    global rawCaptureArmed, capturedRawPage, capturedRawBytesHex, lastCaptureKind, capturedSC
    global capturedRawUpBytesHex, rawCaptureAwaitingRelease, rawCaptureDownHDevice, rawCaptureDownTick, rawCaptureReleaseWindowToken, RawCaptureReleaseWindowMs, MinHoldReleaseGapMs
    global activeProfileName
    global modifierRawCaptureArmed, modifierKind, modifierRawPage, modifierRawBytesHex, modifierActive
    global modifierRawUpBytesHex, modifierRawCaptureAwaitingRelease, modifierRawCaptureDownHDevice, modifierRawCaptureDownTick, modifierRawCaptureReleaseWindowToken
    global profileModRawCaptureArmed, profileModCaptureCallback, profileModCaptureStatusCallback
    global profileModRawCaptureAwaitingRelease, profileModRawCaptureDownHDevice, profileModRawCaptureDownTick
    global profileModRawCaptureDownPage, profileModRawCaptureDownBytesHex, profileModRawCaptureReleaseWindowToken
    global rawMapCaptureArmed, rawMapCaptureExpectedPage, rawMapCaptureExpectedBytesHex, rawMapCaptureCallback, rawMapCaptureStatusCallback
    global rawMapCaptureAwaitingRelease, rawMapCaptureDownHDevice, rawMapCaptureDownTick, rawMapCaptureReleaseWindowToken
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
        if flags & 1
            return
        line := Format("[Keyboard] MakeCode:0x{:X} VKey:0x{:X} Flags:0x{:X}", makeCode, vkey, flags)
    } else if dwType = 0 {
        base := cbHeader
        usButtonFlags := NumGet(buf, base + 4, "UShort")
        if usButtonFlags = 0
            return
        info := {usagePage: 0x01, usage: 0x02}
        bytesNorm := ""
        line := ""
        isButtonUpReport := false
        upBytesHexForCapture := ""
        if usButtonFlags & 0x0800 {
            wheelDelta := NumGet(buf, base + 6, "Short")
            bytesNorm := wheelDelta > 0 ? "0801" : "0802"
            line := Format("[Mouse] Wheel Tilt {} (Delta:{})", wheelDelta > 0 ? "Right" : "Left", wheelDelta)
        } else if usButtonFlags & 0x0400 {
            return
        } else {
            downFlags := usButtonFlags & 0x0155
            upFlags := usButtonFlags & 0x02AA
            if downFlags = 0 && upFlags = 0
                return
            if downFlags != 0 {
                names := []
                if downFlags & 0x0001
                    names.Push("Left")
                if downFlags & 0x0004
                    names.Push("Right")
                if downFlags & 0x0010
                    names.Push("Middle")
                if downFlags & 0x0040
                    names.Push("Button4")
                if downFlags & 0x0100
                    names.Push("Button5")
                bytesNorm := Format("{:04X}", downFlags)
                line := Format("[Mouse] Page:0x01 Usage:0x02 Button: {} (Flags:0x{:04X})", names.Length ? StrJoin(names, "+") : "?", downFlags)
                upBytesHexForCapture := Format("{:04X}", downFlags << 1)
            } else {
                isButtonUpReport := true
                names := []
                if upFlags & 0x0002
                    names.Push("Left")
                if upFlags & 0x0008
                    names.Push("Right")
                if upFlags & 0x0020
                    names.Push("Middle")
                if upFlags & 0x0080
                    names.Push("Button4")
                if upFlags & 0x0200
                    names.Push("Button5")
                bytesNorm := Format("{:04X}", upFlags)
                line := Format("[Mouse] Page:0x01 Usage:0x02 Button Released: {} (Flags:0x{:04X})", names.Length ? StrJoin(names, "+") : "?", upFlags)
            }
        }
        rowData := {page: info.usagePage, bytesHex: bytesNorm}
        if isButtonUpReport {
            effMod := EffectiveModifier(activeProfileName)
            if effMod.kind = "raw" && effMod.mode = "hold" && effMod.rawUpBytesHex != "" && info.usagePage = effMod.rawPage && bytesNorm = effMod.rawUpBytesHex {
                modifierActive := false
                RefreshModifierLiveIndicator()
            } else {
                upDownBytes := FindRawMappingDownBytesForUp(info.usagePage, bytesNorm)
                if upDownBytes != "" {
                    if masterEnabled
                        OnButtonUp(MakeRawButtonKey(info.usagePage, upDownBytes), "raw")
                }
            }
        } else {
            if rawCaptureArmed {
                rawCaptureArmed := false
                capturedRawPage := info.usagePage
                capturedRawBytesHex := bytesNorm
                lastCaptureKind := "raw"
                capturedSC := 0
                capturedRawUpBytesHex := upBytesHexForCapture
                if IsObject(txtCaptureStatus) {
                    txtCaptureStatus.Value := upBytesHexForCapture != ""
                        ? Format("Captured: Page:0x{:X} Bytes:{} - hold capable", info.usagePage, bytesNorm)
                        : Format("Captured: Page:0x{:X} Bytes:{}", info.usagePage, bytesNorm)
                    ReconcileMainHoldDdls()
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if modifierRawCaptureArmed {
                modifierRawCaptureArmed := false
                modifierKind := "raw"
                modifierRawPage := info.usagePage
                modifierRawBytesHex := bytesNorm
                modifierRawUpBytesHex := upBytesHexForCapture
                if IsObject(txtModifierStatus) {
                    RefreshModifierStatusText()
                    UpdateModifierModeUI()
                }
                RegisterModifierHotkey()
                SaveMappings()
                LogRawSniffEvent(line, rowData)
                return
            }
            if profileModRawCaptureArmed {
                profileModRawCaptureArmed := false
                if IsObject(profileModCaptureCallback)
                    profileModCaptureCallback.Call(info.usagePage, bytesNorm, upBytesHexForCapture)
                profileModCaptureCallback := ""
                profileModCaptureStatusCallback := ""
                ResumeProfileModifierHotkeysIfNeeded()
                LogRawSniffEvent(line, rowData)
                return
            }
            if rawMapCaptureArmed {
                if info.usagePage != rawMapCaptureExpectedPage || bytesNorm != rawMapCaptureExpectedBytesHex {
                    if IsObject(rawMapCaptureStatusCallback)
                        rawMapCaptureStatusCallback.Call(Format("That was a different button (Page:0x{:X} Bytes:{}) - press the SAME button that generated the selected line (Page:0x{:X} Bytes:{}).", info.usagePage, bytesNorm, rawMapCaptureExpectedPage, rawMapCaptureExpectedBytesHex))
                } else {
                    rawMapCaptureArmed := false
                    CompleteRawMapCaptureConfig(upBytesHexForCapture)
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            effMod := EffectiveModifier(activeProfileName)
            if effMod.kind = "raw" && info.usagePage = effMod.rawPage && bytesNorm = effMod.rawBytesHex {
                if effMod.mode = "hold" && effMod.rawUpBytesHex != "" {
                    modifierActive := true
                } else {
                    modifierActive := !modifierActive
                    NotifyModifierToggled()
                }
                RefreshModifierLiveIndicator()
                LogRawSniffEvent(line, rowData)
                return
            }
            rawButtonKey := MakeRawButtonKey(info.usagePage, bytesNorm)
            downUpBytes := FindRawMappingUpBytes(info.usagePage, bytesNorm)
            if downUpBytes != "" {
                if masterEnabled
                    OnButtonDown(rawButtonKey, "raw")
            } else {
                effProfile := EffectiveProfileForButton(rawButtonKey, "raw")
                activeList := modifierActive ? "Mod" : "Main"
                for key in mapOrder {
                    m := mappings[key]
                    if (MapKind(m)) != "raw"
                        continue
                    if (MapProfile(m)) != effProfile
                        continue
                    if (MapList(m)) != activeList
                        continue
                    if m.page = info.usagePage && m.bytesHex = bytesNorm {
                        if masterEnabled && m.enabled
                            FireMapping(m)
                    }
                }
            }
        }
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
            if rawCaptureAwaitingRelease && hDevice = rawCaptureDownHDevice {
                if bytesNorm != capturedRawBytesHex {
                    if IsGenuineHoldRelease(rawCaptureDownTick) {
                        capturedRawUpBytesHex := bytesNorm
                        rawCaptureAwaitingRelease := false
                        if IsObject(txtCaptureStatus) {
                            txtCaptureStatus.Value := Format("Captured: Page:0x{:X} Bytes:{} - hold capable", capturedRawPage, capturedRawBytesHex)
                            ReconcileMainHoldDdls()
                        }
                    } else if IsObject(txtCaptureStatus)
                        txtCaptureStatus.Value := Format("Captured: Page:0x{:X} Bytes:{} - release came too fast (<{}ms), ignoring - hold/release the button now to enable hold support...", capturedRawPage, capturedRawBytesHex, MinHoldReleaseGapMs)
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if rawCaptureArmed {
                rawCaptureArmed := false
                capturedRawPage := info.usagePage
                capturedRawBytesHex := bytesNorm
                capturedRawUpBytesHex := ""
                lastCaptureKind := "raw"
                capturedSC := 0
                rawCaptureAwaitingRelease := true
                rawCaptureDownHDevice := hDevice
                rawCaptureDownTick := A_TickCount
                windowToken := ++rawCaptureReleaseWindowToken
                SetTimer(() => FinalizeRawCapture(windowToken), -RawCaptureReleaseWindowMs)
                if IsObject(txtCaptureStatus) {
                    txtCaptureStatus.Value := Format("Captured: Page:0x{:X} Bytes:{} - hold/release the button now to enable hold support...", info.usagePage, bytesNorm)
                    ReconcileMainHoldDdls()
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if modifierRawCaptureAwaitingRelease && hDevice = modifierRawCaptureDownHDevice {
                if bytesNorm != modifierRawBytesHex {
                    if IsGenuineHoldRelease(modifierRawCaptureDownTick) {
                        modifierRawUpBytesHex := bytesNorm
                        modifierRawCaptureAwaitingRelease := false
                        CompleteModifierRawCaptureConfig()
                    } else if IsObject(txtModifierStatus)
                        txtModifierStatus.Value := Format("Modifier: Raw Page:0x{:X} Bytes:{} - release came too fast (<{}ms), ignoring - hold/release the button now to enable Held mode...", modifierRawPage, modifierRawBytesHex, MinHoldReleaseGapMs)
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if modifierRawCaptureArmed {
                modifierRawCaptureArmed := false
                modifierKind := "raw"
                modifierRawPage := info.usagePage
                modifierRawBytesHex := bytesNorm
                modifierRawUpBytesHex := ""
                modifierRawCaptureAwaitingRelease := true
                modifierRawCaptureDownHDevice := hDevice
                modifierRawCaptureDownTick := A_TickCount
                windowToken := ++modifierRawCaptureReleaseWindowToken
                SetTimer(() => FinalizeModifierRawCapture(windowToken), -RawCaptureReleaseWindowMs)
                if IsObject(txtModifierStatus)
                    txtModifierStatus.Value := Format("Modifier: Raw Page:0x{:X} Bytes:{} - hold/release the button now to enable Held mode...", info.usagePage, bytesNorm)
                LogRawSniffEvent(line, rowData)
                return
            }
            if profileModRawCaptureAwaitingRelease && hDevice = profileModRawCaptureDownHDevice {
                if bytesNorm != profileModRawCaptureDownBytesHex {
                    if IsGenuineHoldRelease(profileModRawCaptureDownTick) {
                        profileModRawCaptureAwaitingRelease := false
                        CompleteProfileModifierRawCaptureConfig(bytesNorm)
                    } else if IsObject(profileModCaptureStatusCallback)
                        profileModCaptureStatusCallback.Call(Format("Modifier: Raw Page:0x{:X} Bytes:{} - release came too fast (<{}ms), ignoring - hold/release the button now to enable Held mode...", profileModRawCaptureDownPage, profileModRawCaptureDownBytesHex, MinHoldReleaseGapMs))
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if rawMapCaptureAwaitingRelease && hDevice = rawMapCaptureDownHDevice {
                if bytesNorm != rawMapCaptureExpectedBytesHex {
                    rawMapCaptureAwaitingRelease := false
                    if IsGenuineHoldRelease(rawMapCaptureDownTick)
                        CompleteRawMapCaptureConfig(bytesNorm)
                    else
                        CompleteRawMapCaptureConfig("")
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            if profileModRawCaptureArmed {
                profileModRawCaptureArmed := false
                profileModRawCaptureDownPage := info.usagePage
                profileModRawCaptureDownBytesHex := bytesNorm
                profileModRawCaptureAwaitingRelease := true
                profileModRawCaptureDownHDevice := hDevice
                profileModRawCaptureDownTick := A_TickCount
                windowToken := ++profileModRawCaptureReleaseWindowToken
                SetTimer(() => FinalizeProfileModifierRawCapture(windowToken), -RawCaptureReleaseWindowMs)
                if IsObject(profileModCaptureStatusCallback)
                    profileModCaptureStatusCallback.Call(Format("Modifier: Raw Page:0x{:X} Bytes:{} - hold/release the button now to enable Held mode...", info.usagePage, bytesNorm))
                LogRawSniffEvent(line, rowData)
                return
            }
            if rawMapCaptureArmed {
                if info.usagePage != rawMapCaptureExpectedPage || bytesNorm != rawMapCaptureExpectedBytesHex {
                    if IsObject(rawMapCaptureStatusCallback)
                        rawMapCaptureStatusCallback.Call(Format("That was a different event (Page:0x{:X} Bytes:{}) - press the SAME button that generated the selected line (Page:0x{:X} Bytes:{}).", info.usagePage, bytesNorm, rawMapCaptureExpectedPage, rawMapCaptureExpectedBytesHex))
                } else {
                    rawMapCaptureArmed := false
                    rawMapCaptureAwaitingRelease := true
                    rawMapCaptureDownHDevice := hDevice
                    rawMapCaptureDownTick := A_TickCount
                    windowToken := ++rawMapCaptureReleaseWindowToken
                    SetTimer(() => FinalizeRawMapCapture(windowToken), -RawCaptureReleaseWindowMs)
                    if IsObject(rawMapCaptureStatusCallback)
                        rawMapCaptureStatusCallback.Call(Format("Page:0x{:X} Bytes:{} - hold/release the button now to enable hold support...", info.usagePage, bytesNorm))
                }
                LogRawSniffEvent(line, rowData)
                return
            }
            effMod := EffectiveModifier(activeProfileName)
            if effMod.kind = "raw" && info.usagePage = effMod.rawPage && bytesNorm = effMod.rawBytesHex {
                if effMod.mode = "hold" && effMod.rawUpBytesHex != "" {
                    modifierActive := true
                } else {
                    modifierActive := !modifierActive
                    NotifyModifierToggled()
                }
                RefreshModifierLiveIndicator()
                LogRawSniffEvent(line, rowData)
                return
            } else if effMod.kind = "raw" && effMod.mode = "hold" && effMod.rawUpBytesHex != "" && info.usagePage = effMod.rawPage && bytesNorm = effMod.rawUpBytesHex {
                modifierActive := false
                RefreshModifierLiveIndicator()
                LogRawSniffEvent(line, rowData)
                return
            }
            rawButtonKey := MakeRawButtonKey(info.usagePage, bytesNorm)
            downUpBytes := FindRawMappingUpBytes(info.usagePage, bytesNorm)
            if downUpBytes != "" {
                if masterEnabled
                    OnButtonDown(rawButtonKey, "raw")
            } else {
                upDownBytes := FindRawMappingDownBytesForUp(info.usagePage, bytesNorm)
                if upDownBytes != "" {
                    if masterEnabled
                        OnButtonUp(MakeRawButtonKey(info.usagePage, upDownBytes), "raw")
                } else {
                    effProfile := EffectiveProfileForButton(rawButtonKey, "raw")
                    activeList := modifierActive ? "Mod" : "Main"
                    for key in mapOrder {
                        m := mappings[key]
                        if (MapKind(m)) != "raw"
                            continue
                        if (MapProfile(m)) != effProfile
                            continue
                        if (MapList(m)) != activeList
                            continue
                        if m.page = info.usagePage && m.bytesHex = bytesNorm {
                            if masterEnabled && m.enabled
                                FireMapping(m)
                        }
                    }
                }
            }
        }
    } else {
        return
    }
    LogRawSniffEvent(line, rowData)
}
OnMessage(0x00FF, OnRawInput)

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
    rawMapUpBytesHex := ""
    gm := Gui("+Owner" gRaw.Hwnd, "Map Raw HID Event")
    gm.SetFont("s10", "Segoe UI")
    gm.Add("Text", "w420", Format("Event: Page:0x{:X} Bytes:{}", page, bytesHex))
    gm.Add("Text", "xm y+15", "Description:")
    edDesc := gm.Add("Edit", "x+10 w180")
    gm.Add("Text", "x+15", "Action:")
    ddlRawAction := gm.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App", "Multimedia", "Mouse", "Macro"])

    lblRawSends := gm.Add("Text", "xm y+15", "Sends:")
    edTarget := gm.Add("Edit", "x+10 w120 ReadOnly Background0xFFFFFF")
    lblRawSends.GetPos(&fieldsX, &fieldsY)

    rawTargetCaptureHook := ""
    rawTargetHeldMods := Map()
    rawTargetComboFired := false

    StartRawMapTargetCapture(*) {
        global captureSuspended
        if IsObject(rawTargetCaptureHook) {
            try rawTargetCaptureHook.Stop()
        }
        ResumeButtonHotkeysIfNeeded()
        IncrementCaptureSuspend()
        captureSuspended := true
        rawTargetComboFired := false
        rawTargetHeldMods := Map()
        edTarget.Value := ""
        rawTargetCaptureHook := NewCaptureInputHook(OnRawMapTargetKeyDown, OnRawMapTargetKeyUp)
    }

    StopRawMapTargetCapture(*) {
        if IsObject(rawTargetCaptureHook) {
            try rawTargetCaptureHook.Stop()
            rawTargetCaptureHook := ""
        }
        ResumeButtonHotkeysIfNeeded()
        edTarget.Value := HumanizeSendKey(rawMapTargetString)
    }

    FinalizeRawTarget(modStr, keyName) {
        global rawMapTargetString
        rawMapTargetString := modStr FormatSendKey(keyName)
        edTarget.Value := HumanizeSendKey(rawMapTargetString)
    }

    OnRawMapTargetKeyDown(ihObj, VK, SC) {
        if IsModifierVK(VK) {
            rawTargetHeldMods[VK] := true
            return
        }
        keyName := KeyNameFor(VK, SC)
        FinalizeRawTarget(BuildModStrFromHeld(rawTargetHeldMods), keyName)
        rawTargetComboFired := true
    }

    OnRawMapTargetKeyUp(ihObj, VK, SC) {
        if !IsModifierVK(VK)
            return
        rawTargetHeldMods.Delete(VK)
        allModsUp := (rawTargetHeldMods.Count = 0)
        if rawTargetComboFired {
            if allModsUp
                rawTargetComboFired := false
            return
        }
        if !allModsUp
            return
        keyName := KeyNameFor(VK, SC)
        FinalizeRawTarget("", keyName)
    }

    edTarget.OnEvent("Focus", StartRawMapTargetCapture)
    edTarget.OnEvent("LoseFocus", StopRawMapTargetCapture)

    lblRawAppPath := gm.Add("Text", "xm y" fieldsY, "App/File path:")
    edRawAppPath := gm.Add("Edit", "x+10 w260")
    btnRawBrowse := gm.Add("Button", "x+8 w80", "Browse...")
    btnRawBrowse.OnEvent("Click", (*) => BrowseForAppInto(edRawAppPath))

    lblRawAppArgs := gm.Add("Text", "xm y+10", "Arguments (optional):")
    edRawAppArgs := gm.Add("Edit", "x+10 w300")
    edRawAppArgs.GetPos(&argsX, &argsY, &argsW, &argsH)
    dynRegionBottom := argsY + argsH

    lblRawMacroSelect := gm.Add("Text", "xm y" fieldsY, "Macro:")
    ddlRawMacroSelect := gm.Add("DropDownList", "x+10 w180 Choose1", ["(Custom / unsaved)"])
    ddlRawMacroSelect.OnEvent("Change", OnRawMacroSelectChange)
    btnRawEditMacro := gm.Add("Button", "x+5 w90", "Macros")
    btnRawEditMacro.OnEvent("Click", (*) => OpenMacroEditor(rawMacroSteps, SaveRawMacroStepsFromDialog))

    lblRawMultimedia := gm.Add("Text", "xm y" fieldsY, "Multimedia action:")
    ddlRawMultimedia := gm.Add("DropDownList", "x+10 w180 Choose1", MultimediaNames())

    lblRawMouse := gm.Add("Text", "xm y" fieldsY, "Mouse action:")
    ddlRawMouse := gm.Add("DropDownList", "x+10 w180 Choose1", MouseNames())

    txtRawHoldStatus := gm.Add("Text", "xm y" (dynRegionBottom + 15) " w420", "Single-shot only (no hold detected) - Trigger/Run mode below are ignored until hold is detected.")
    btnRawDetectHold := gm.Add("Button", "xm y+6 w230", "Detect Hold (press button again)")

    lblRawRunMode := gm.Add("Text", "xm y+12", "Run mode:")
    ddlRawRunMode := gm.Add("DropDownList", "x+10 w220 Choose1 +0x10", RunModeDdlItems)
    lblRawRepeatMs := gm.Add("Text", "x+15", "Interval (ms):")
    edRawRepeatMs := gm.Add("Edit", "x+8 w60", "100")
    lblRawTrigger := gm.Add("Text", "xm y+12", "Trigger:")
    ddlRawTrigger := gm.Add("DropDownList", "x+10 w230 Choose1 +0x10", PressTypeDdlItems)

    RegisterHoldDdl(ddlRawTrigger, PressTypeDdlItems, HoldOnlyTriggerIdx, () => rawMapUpBytesHex = "")
    RegisterHoldDdl(ddlRawRunMode, RunModeDdlItems, HoldOnlyRunModeIdx, () => rawMapUpBytesHex = "")
    ddlRawTrigger.OnEvent("Change", (*) => EnforceHoldDdlSelection(ddlRawTrigger, HoldOnlyTriggerIdx, () => rawMapUpBytesHex = "", DdlIndexFromPressType("short")))

    ToggleRawRunModeControls(*) {
        isSingle := ddlRawRunMode.Value = 1
        showRepeatMs := (ddlRawRunMode.Value = 2 || ddlRawRunMode.Value = 3)
        lblRawRepeatMs.Visible := showRepeatMs
        edRawRepeatMs.Visible := showRepeatMs
        ddlRawTrigger.Visible := isSingle
        if !isSingle
            ddlRawTrigger.Choose(DdlIndexFromPressType("short"))
    }
    ddlRawRunMode.OnEvent("Change", ToggleRawRunModeControls)
    ddlRawRunMode.OnEvent("Change", (*) => EnforceHoldDdlSelection(ddlRawRunMode, HoldOnlyRunModeIdx, () => rawMapUpBytesHex = "", 1, ToggleRawRunModeControls))
    ToggleRawRunModeControls()

    ReconcileRawMapHoldDdls() {
        if rawMapUpBytesHex = "" {
            if HasVal(HoldOnlyRunModeIdx, ddlRawRunMode.Value - 1) {
                ddlRawRunMode.Choose(1)
                ToggleRawRunModeControls()
            }
            if HasVal(HoldOnlyTriggerIdx, ddlRawTrigger.Value - 1)
                ddlRawTrigger.Choose(DdlIndexFromPressType("short"))
        }
        RefreshHoldDdl(ddlRawTrigger)
        RefreshHoldDdl(ddlRawRunMode)
    }

    RefreshRawMapHoldStatus() {
        txtRawHoldStatus.Value := rawMapUpBytesHex != ""
            ? Format("Hold-capable (release: Bytes:{}) - Trigger/Run mode below now apply.", rawMapUpBytesHex)
            : "Single-shot only (no hold detected) - Trigger/Run mode below are ignored until hold is detected."
        ReconcileRawMapHoldDdls()
    }

    StartRawMapCapture(*) {
        global rawMapCaptureExpectedPage, rawMapCaptureExpectedBytesHex, rawMapCaptureCallback, rawMapCaptureStatusCallback
        CancelPendingRawMapCapture()
        rawMapCaptureExpectedPage := page
        rawMapCaptureExpectedBytesHex := bytesHex
        rawMapCaptureCallback := (upBytesHex) => (
            rawMapUpBytesHex := upBytesHex,
            RefreshRawMapHoldStatus())
        rawMapCaptureStatusCallback := (text) => txtRawHoldStatus.Value := text
        txtRawHoldStatus.Value := "Get ready... (waiting for your click to finish)"
        SetTimer(ArmRawMapCapture, -300)
    }
    ArmRawMapCapture() {
        global rawMapCaptureArmed
        rawMapCaptureArmed := true
        txtRawHoldStatus.Value := Format("Waiting for you to press the SAME button again (Page:0x{:X} Bytes:{})...", page, bytesHex)
    }
    btnRawDetectHold.OnEvent("Click", StartRawMapCapture)

    ToggleRawActionControls(*) {
        v := ddlRawAction.Value
        isApp := v = 2
        isMultimedia := v = 3
        isMouse := v = 4
        isMacro := v = 5
        isKey := !isApp && !isMacro && !isMultimedia && !isMouse
        lblRawSends.Visible := isKey
        edTarget.Visible := isKey
        lblRawAppPath.Visible := isApp
        edRawAppPath.Visible := isApp
        btnRawBrowse.Visible := isApp
        lblRawAppArgs.Visible := isApp
        edRawAppArgs.Visible := isApp
        lblRawMacroSelect.Visible := isMacro
        ddlRawMacroSelect.Visible := isMacro
        btnRawEditMacro.Visible := isMacro
        lblRawMultimedia.Visible := isMultimedia
        ddlRawMultimedia.Visible := isMultimedia
        lblRawMouse.Visible := isMouse
        ddlRawMouse.Visible := isMouse
    }
    ddlRawAction.OnEvent("Change", ToggleRawActionControls)
    ToggleRawActionControls()

    btnSave := gm.Add("Button", "xm y+20 w100", "Save")
    btnSave.OnEvent("Click", (*) => SaveRawMapping(page, bytesHex, edDesc.Value, ddlRawAction.Value, edRawAppPath.Value, edRawAppArgs.Value, ddlRawMultimedia.Value, ddlRawMouse.Value, rawMapUpBytesHex, ddlRawTrigger.Value, ddlRawRunMode.Value, edRawRepeatMs.Value, gm))
    btnCancel := gm.Add("Button", "x+10 w100", "Cancel")
    btnCancel.OnEvent("Click", (*) => (CancelPendingRawMapCapture(), gm.Destroy()))
    gm.OnEvent("Close", (*) => (CancelPendingRawMapCapture(), gm.Destroy()))

    OnRawMacroSelectChange(*) {
        global rawMacroSteps, savedMacros, savedMacroOrder
        idx := ddlRawMacroSelect.Value
        if idx <= 1
            return
        name := savedMacroOrder[idx - 1]
        if !savedMacros.Has(name)
            return
        rawMacroSteps := CloneMacroSteps(savedMacros[name])
    }

    RefreshRawMacroSelectDdl() {
        global rawMacroSteps, savedMacroOrder
        items := ["(Custom / unsaved)"]
        for name in savedMacroOrder
            items.Push(name)
        ddlRawMacroSelect.Delete()
        ddlRawMacroSelect.Add(items)
        matchIdx := 1
        matchName := FindSavedMacroNameForSteps(rawMacroSteps)
        if matchName != "" {
            for i, name in savedMacroOrder {
                if name = matchName {
                    matchIdx := i + 1
                    break
                }
            }
        }
        ddlRawMacroSelect.Choose(matchIdx)
    }
    RefreshRawMacroSelectDdl()

    SaveRawMacroStepsFromDialog(steps) {
        global rawMacroSteps
        rawMacroSteps := steps
        RefreshRawMacroSelectDdl()
    }

    gm.Show()
}

SaveRawMapping(page, bytesHex, desc, actionVal, appPath, appArgs, multimediaIdx, mouseIdx, upBytesHex, triggerIdx, runModeIdx, repeatMsStr, gm) {
    global mappings, mapOrder, rawMapTargetString, editingProfileName, rawMacroSteps
    isApp := actionVal = 2
    isMultimedia := actionVal = 3
    isMouse := actionVal = 4
    isMacro := actionVal = 5
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
        if isMultimedia
            rawMapTargetString := MultimediaSendForIndex(multimediaIdx)
        else if isMouse
            rawMapTargetString := MouseSendForIndex(mouseIdx)
        if rawMapTargetString = "" {
            MsgBox(isMultimedia ? "Choose a multimedia action first." : (isMouse ? "Choose a mouse action first." : "Capture a key/combo to send first."), "Missing target", "Icon!")
            return
        }
    }
    buttonKey := MakeRawButtonKey(page, bytesHex)
    key := GenerateId(editingProfileName, buttonKey)
    mapOrder.Push(key)
    dispId := SubStr(key, StrLen(editingProfileName) + 3)
    finalDesc := desc != "" ? desc : Format("Raw 0x{:X} {} ({})", page, bytesHex, dispId)

    rawHoldCapable := upBytesHex != ""
    runMode := runModeIdx = 2 ? "repeat" : (runModeIdx = 3 ? "toggle" : (runModeIdx = 4 ? "hold" : (runModeIdx = 5 ? "toggleHold" : "single")))
    rawRunMode := rawHoldCapable ? runMode : "single"
    rawPressType := rawHoldCapable ? (rawRunMode = "single" ? PressTypeFromDdlIndex(triggerIdx) : "short") : "short"
    repeatMs := IsInteger(repeatMsStr) ? Integer(repeatMsStr) : 100
    if repeatMs < 2
        repeatMs := 2

    if isApp
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "app", page: page, bytesHex: bytesHex, upBytesHex: upBytesHex, desc: finalDesc, target: appPath, appArgs: appArgs, macroSteps: [], enabled: true, pressType: rawPressType, runMode: rawRunMode, repeatMs: repeatMs, list: "Main"}
    else if isMacro {
        stepsCopy := []
        for s in rawMacroSteps
            stepsCopy.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
        linkedMacroName := FindSavedMacroNameForSteps(stepsCopy)
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "macro", page: page, bytesHex: bytesHex, upBytesHex: upBytesHex, desc: finalDesc, target: "", appArgs: "", macroSteps: stepsCopy, macroName: linkedMacroName, enabled: true, pressType: rawPressType, runMode: rawRunMode, repeatMs: repeatMs, list: "Main"}
    } else
        mappings[key] := {profile: editingProfileName, kind: "raw", actionType: "key", page: page, bytesHex: bytesHex, upBytesHex: upBytesHex, desc: finalDesc, target: rawMapTargetString, appArgs: "", macroSteps: [], enabled: true, pressType: rawPressType, runMode: rawRunMode, repeatMs: repeatMs, list: "Main"}
    SaveMappings()
    RefreshList()
    CancelPendingRawMapCapture()
    gm.Destroy()
    txtStatus.Value := "Saved raw mapping for " dispId "."
}

macroEditSteps := []
gMacro := ""
lvMacroSteps := ""
macroStepCapturedTarget := ""

savedMacros := Map()
savedMacroOrder := []
lbSavedMacros := ""

macroRecording := false
recordHook := ""
recordLastEventTick := 0
recordHeldKeys := Map()
macroStepControls := []

OpenMacroEditor(initialSteps, onSave) {
    global gMacro, macroEditSteps, lvMacroSteps
    global macroRecording, recordHook, recordLastEventTick, recordHeldKeys
    global macroStepControls
    global macroLvColW1, macroLvColW2, macroLvColW3, macroLvColW4
    global savedMacros, savedMacroOrder, lbSavedMacros
    macroEditSteps := []
    macroRecording := false
    recordHook := ""
    recordLastEventTick := 0
    recordHeldKeys := Map()
    for s in initialSteps
        macroEditSteps.Push({type: s.type, target: s.HasOwnProp("target") ? s.target : "", args: s.HasOwnProp("args") ? s.args : "", delayAfterMs: s.HasOwnProp("delayAfterMs") ? s.delayAfterMs : 0})

    gMacro := Gui("+Owner" g.Hwnd, "Edit Macro")
    gMacro.SetFont("s10", "Segoe UI")

    lblSavedMacrosHeader := gMacro.Add("Text", "xm y10", "Saved Macros")
    lblSavedMacrosHeader.GetPos(&smhX, &smhY, &smhW, &smhH)
    savedMacroBoxW := 165
    savedMacroGap := 10
    lbSavedMacros := gMacro.Add("ListBox", "x" smhX " y+2 w" savedMacroBoxW " h600")
    lbSavedMacros.OnEvent("Change", (*) => OnSavedMacroSelectionChange())
    lbSavedMacros.GetPos(&smX, &smY, &smW, &smH)
    RefreshSavedMacrosList()

    savedMacroBtnGap := 3
    savedMacroBtnW := (smW - 2 * savedMacroBtnGap) // 3
    btnSaveMacro := gMacro.Add("Button", "x" smX " y" (smY + smH + 10) " w" savedMacroBtnW, "Save")
    btnSaveMacro.OnEvent("Click", (*) => OpenSaveMacroNameDialog())
    btnUpdateSavedMacro := gMacro.Add("Button", "x+" savedMacroBtnGap " yp w" savedMacroBtnW, "Update")
    btnUpdateSavedMacro.OnEvent("Click", (*) => UpdateSelectedSavedMacro())
    btnDeleteSavedMacro := gMacro.Add("Button", "x+" savedMacroBtnGap " yp w" savedMacroBtnW, "Delete")
    btnDeleteSavedMacro.OnEvent("Click", (*) => DeleteSelectedSavedMacro())

    btnDeleteSavedMacro.GetPos(&smBtnX, &smBtnY, &smBtnW, &smBtnH)
    radStepKey := gMacro.Add("Radio", "x" smX " y" (smBtnY + smBtnH + 15) " w" savedMacroBoxW " +0x8 Group Checked", "Send Key/Combo")
    radStepApp := gMacro.Add("Radio", "x" smX " y+8 w" savedMacroBoxW " +0x8", "Launch App")
    radStepMultimedia := gMacro.Add("Radio", "x" smX " y+8 w" savedMacroBoxW " +0x8", "Multimedia")

    stepsX := smX + smW + savedMacroGap
    gMacro.Add("Text", "x" stepsX " y" smhY " w560", "Steps run top to bottom, in order, each time this macro fires. Double-click a step's Delay after value to change it.")

    lvMacroSteps := gMacro.Add("ListView", "x" stepsX " y" smY " w560 h600", ["#", "Type", "Target", "Delay after (ms)"])
    lvMacroSteps.ModifyCol(1, macroLvColW1)
    lvMacroSteps.ModifyCol(2, macroLvColW2)
    lvMacroSteps.ModifyCol(3, macroLvColW3)
    lvMacroSteps.ModifyCol(4, macroLvColW4)
    lvMacroSteps.OnEvent("DoubleClick", OnMacroStepDoubleClick)
    RefreshMacroStepsList()

    btnRecordMacro := gMacro.Add("Button", "x" stepsX " y+12 w120", "Record Macro")
    btnInsertWait := gMacro.Add("Button", "x+10", "Insert Delay")
    edStepDelay := gMacro.Add("Edit", "x+10 w49", "0")
    lblStepMs := gMacro.Add("Text", "x+5", "ms")
    btnMoveUp := gMacro.Add("Button", "x+15 w30", "⌃")
    btnMoveDown := gMacro.Add("Button", "x+2 w30", "⌄")
    btnRemoveStep := gMacro.Add("Button", "x+2", "Remove")
    btnClearMacro := gMacro.Add("Button", "x+2", "Clear")
    btnInsertWait.OnEvent("Click", (*) => InsertWaitStep(edStepDelay))
    btnMoveUp.OnEvent("Click", (*) => MoveMacroStep(-1))
    btnMoveDown.OnEvent("Click", (*) => MoveMacroStep(1))
    btnClearMacro.OnEvent("Click", (*) => ClearMacroSteps())
    btnRemoveStep.OnEvent("Click", (*) => RemoveMacroStep())
    lblRecordStatus := gMacro.Add("Text", "x" stepsX " y+10 w400 cRed", "Recording... press keys now.")
    lblRecordStatus.Visible := false
    btnRecordMacro.OnEvent("Click", (*) => ToggleMacroRecording(btnRecordMacro, lblRecordStatus))

    GetStepTypeValue(*) {
        return radStepKey.Value ? 1 : (radStepApp.Value ? 2 : 3)
    }

    lblStepKey := gMacro.Add("Text", "x" stepsX " y+15", "Key/Combo:")
    edStepKey := gMacro.Add("Edit", "x+10 w214 ReadOnly Background0xFFFFFF")
    edStepKey.OnEvent("Focus", (*) => StartMacroStepKeyCapture(edStepKey))
    edStepKey.OnEvent("LoseFocus", (*) => StopMacroStepKeyCapture(edStepKey))
    stepRow1X := stepRow1Y := stepRow1H := 0
    lblStepKey.GetPos(&stepRow1X, &stepRow1Y, , &stepRow1H)

    lblStepApp := gMacro.Add("Text", "x" stepsX " y" stepRow1Y, "App/File path:")
    edStepApp := gMacro.Add("Edit", "x+10 w260")
    btnStepBrowse := gMacro.Add("Button", "x+8 w80", "Browse...")
    btnStepBrowse.OnEvent("Click", (*) => BrowseForAppInto(edStepApp))

    lblStepArgs := gMacro.Add("Text", "x" stepsX " y+10", "Arguments (optional):")
    editStepArgsRow2Y := editStepArgsRow2H := 0
    edStepArgs := gMacro.Add("Edit", "x+10 w300")
    lblStepArgs.GetPos(, &editStepArgsRow2Y)
    edStepArgs.GetPos(, , , &editStepArgsRow2H)

    lblStepMultimedia := gMacro.Add("Text", "x" stepsX " y" stepRow1Y, "Multimedia action:")
    edStepMultimedia := gMacro.Add("DropDownList", "x+10 w214 Choose1", MultimediaNames())

    btnAddStep := gMacro.Add("Button", "x" stepsX " y" (stepRow1Y + stepRow1H + 10), "Add Step")
    stepExtraRowShift := (editStepArgsRow2Y + editStepArgsRow2H) - (stepRow1Y + stepRow1H)
    stepAreaExpanded := false
    btnAddStep.OnEvent("Click", (*) => AddMacroStep(GetStepTypeValue(), edStepKey, edStepApp, edStepArgs, edStepDelay, edStepMultimedia))

    ToggleStepTypeControls(*) {
        v := GetStepTypeValue()
        isKey := v = 1
        isApp := v = 2
        isMultimedia := v = 3
        lblStepKey.Visible := isKey
        edStepKey.Visible := isKey
        lblStepApp.Visible := isApp
        edStepApp.Visible := isApp
        btnStepBrowse.Visible := isApp
        lblStepArgs.Visible := isApp
        edStepArgs.Visible := isApp
        lblStepMultimedia.Visible := isMultimedia
        edStepMultimedia.Visible := isMultimedia
        if isApp && !stepAreaExpanded {
            ReflowStepAreaForType(stepExtraRowShift)
            stepAreaExpanded := true
        } else if !isApp && stepAreaExpanded {
            ReflowStepAreaForType(-stepExtraRowShift)
            stepAreaExpanded := false
        }
    }
    ReflowStepAreaForType(deltaY) {
        if deltaY = 0
            return
        for ctrl in [btnAddStep, btnDone, btnCancelM] {
            ctrl.GetPos(&cx, &cy)
            ctrl.Move(, cy + deltaY)
        }
        gMacro.GetPos(&gx, &gy, &gw, &gh)
        gMacro.Move(gx, gy, gw, gh + deltaY)
        DllCall("RedrawWindow", "ptr", gMacro.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0004 | 0x0080 | 0x0100)
    }
    radStepKey.OnEvent("Click", ToggleStepTypeControls)
    radStepApp.OnEvent("Click", ToggleStepTypeControls)
    radStepMultimedia.OnEvent("Click", ToggleStepTypeControls)

    btnDone := gMacro.Add("Button", "x" stepsX " y+20 w100", "Done")
    btnDone.OnEvent("Click", (*) => FinishMacroEditor(onSave))
    btnCancelM := gMacro.Add("Button", "x+10 w100", "Cancel")
    btnCancelM.OnEvent("Click", (*) => (StopRecordingIfActive(), CloseMacroEditor()))
    gMacro.OnEvent("Close", (*) => (StopRecordingIfActive(), CloseMacroEditor()))
    macroStepControls := [btnAddStep, btnMoveUp, btnMoveDown, btnClearMacro, btnRemoveStep,
        radStepKey, radStepApp, radStepMultimedia, edStepKey, edStepApp, btnStepBrowse, edStepArgs, edStepMultimedia,
        btnInsertWait, edStepDelay, btnDone, btnCancelM,
        lbSavedMacros, btnSaveMacro, btnUpdateSavedMacro, btnDeleteSavedMacro]
    ToggleStepTypeControls()
    gMacro.Show()
}

RefreshMacroStepsList() {
    global macroEditSteps, lvMacroSteps
    topIndex := LV_GetTopIndex(lvMacroSteps)
    lvMacroSteps.Delete()
    for i, s in macroEditSteps {
        typeLabel := s.type = "key" ? "Key" : (s.type = "keydown" ? "Key Down" : (s.type = "keyup" ? "Key Up" : (s.type = "app" ? "App" : "Delay")))
        if s.type = "key" || s.type = "keydown" || s.type = "keyup"
            targetLabel := HumanizeSendKey(s.target)
        else if s.type = "app"
            targetLabel := s.target (s.args != "" ? " " s.args : "")
        else
            targetLabel := "-"
        lvMacroSteps.Add(, i, typeLabel, targetLabel, s.delayAfterMs)
    }
    LV_RestoreTopIndex(lvMacroSteps, topIndex)
}

OnMacroStepDoubleClick(ctrl, row) {
    global macroEditSteps, macroRecording
    if macroRecording
        return
    if !row || row > macroEditSteps.Length
        return
    OpenEditDelayDialog(row)
}

OpenEditDelayDialog(row) {
    global macroEditSteps, lvMacroSteps, gMacro
    step := macroEditSteps[row]
    gDelay := Gui("+Owner" gMacro.Hwnd, "Edit Delay")
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

ToggleMacroRecording(btn, statusText) {
    global macroRecording
    if macroRecording
        StopMacroRecording(btn, statusText)
    else
        StartMacroRecordingFlow(btn, statusText)
}

StartMacroRecordingFlow(btn, statusText) {
    global macroRecording, recordLastEventTick, recordHeldKeys, recordHook, macroStepControls
    macroRecording := true
    recordLastEventTick := 0
    recordHeldKeys := Map()
    for ctrl in macroStepControls
        ctrl.Enabled := false
    btn.Text := "Stop Recording"
    statusText.Visible := true
    recordHook := NewCaptureInputHook(RecordMacroKeyDown, RecordMacroKeyUp)
}

StopMacroRecording(btn, statusText) {
    StopRecordingIfActive()
    btn.Text := "Record Macro"
    statusText.Visible := false
}

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

CommitRecordedStep(stepType, target) {
    global macroEditSteps, recordLastEventTick, lvMacroSteps
    now := A_TickCount
    if recordLastEventTick != 0 && macroEditSteps.Length > 0
        macroEditSteps[macroEditSteps.Length].delayAfterMs := now - recordLastEventTick
    macroEditSteps.Push({type: stepType, target: target, args: "", delayAfterMs: 0})
    recordLastEventTick := now
    RefreshMacroStepsList()
    lvMacroSteps.Modify(macroEditSteps.Length, "Select Focus Vis")
}

RecordMacroKeyDown(ihObj, VK, SC) {
    global recordHeldKeys
    keyName := KeyNameFor(VK, SC)
    if recordHeldKeys.Has(keyName)
        return
    recordHeldKeys[keyName] := true
    CommitRecordedStep("keydown", FormatSendKey(keyName))
}

RecordMacroKeyUp(ihObj, VK, SC) {
    global recordHeldKeys
    keyName := KeyNameFor(VK, SC)
    if recordHeldKeys.Has(keyName)
        recordHeldKeys.Delete(keyName)
    CommitRecordedStep("keyup", FormatSendKey(keyName))
}

AddMacroStep(v, edStepKey, edStepApp, edStepArgs, edStepDelay, edStepMultimedia) {
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
    } else if v = 3 {
        newStep := {type: "key", target: MultimediaSendForIndex(edStepMultimedia.Value), args: "", delayAfterMs: delayVal}
    } else {
        if edStepApp.Value = "" {
            MsgBox("Enter an app/file path for this step first.", "Missing target", "Icon!")
            return
        }
        newStep := {type: "app", target: edStepApp.Value, args: edStepArgs.Value, delayAfterMs: delayVal}
    }
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

InsertWaitStep(edStepDelay) {
    global macroEditSteps, lvMacroSteps
    delayVal := IsInteger(edStepDelay.Value) ? Integer(edStepDelay.Value) : 0
    if delayVal <= 0 {
        MsgBox("Enter a delay greater than 0ms first.", "Missing delay", "Icon!")
        return
    }
    newStep := {type: "wait", target: "", args: "", delayAfterMs: delayVal}
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

ClearMacroSteps() {
    global macroEditSteps, lvMacroSteps
    if macroEditSteps.Length = 0
        return
    result := MsgBox("Clear all " macroEditSteps.Length " step(s) from this macro?", "Clear macro", "YesNo Icon!")
    if result != "Yes"
        return
    macroEditSteps := []
    RefreshMacroStepsList()
}

RemoveMacroStep() {
    global macroEditSteps, lvMacroSteps
    rows := []
    row := 0
    loop {
        row := lvMacroSteps.GetNext(row)
        if !row
            break
        rows.Push(row)
    }
    if rows.Length = 0 {
        MsgBox("Select a step first.", "Nothing selected", "Icon!")
        return
    }
    loop rows.Length
        macroEditSteps.RemoveAt(rows[rows.Length - A_Index + 1])
    RefreshMacroStepsList()
}

MoveMacroStep(dir) {
    global macroEditSteps, lvMacroSteps
    rows := []
    row := 0
    loop {
        row := lvMacroSteps.GetNext(row)
        if !row
            break
        rows.Push(row)
    }
    if rows.Length = 0 {
        MsgBox("Select a step first.", "Nothing selected", "Icon!")
        return
    }
    n := macroEditSteps.Length
    selArr := []
    loop n
        selArr.Push(false)
    for r in rows
        selArr[r] := true
    moved := false
    if dir < 0 {
        loop n - 1 {
            i := A_Index + 1
            if selArr[i] && !selArr[i - 1] {
                tmp := macroEditSteps[i]
                macroEditSteps[i] := macroEditSteps[i - 1]
                macroEditSteps[i - 1] := tmp
                tmpSel := selArr[i]
                selArr[i] := selArr[i - 1]
                selArr[i - 1] := tmpSel
                moved := true
            }
        }
    } else {
        loop n - 1 {
            i := n - A_Index
            if selArr[i] && !selArr[i + 1] {
                tmp := macroEditSteps[i]
                macroEditSteps[i] := macroEditSteps[i + 1]
                macroEditSteps[i + 1] := tmp
                tmpSel := selArr[i]
                selArr[i] := selArr[i + 1]
                selArr[i + 1] := tmpSel
                moved := true
            }
        }
    }
    if !moved
        return
    RefreshMacroStepsList()
    first := true
    for i, isSel in selArr {
        if isSel {
            lvMacroSteps.Modify(i, first ? "Select Focus" : "Select")
            first := false
        }
    }
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
    CloseMacroEditor()
}

CloseMacroEditor() {
    global gMacro, lvMacroSteps, lbSavedMacros
    global macroLvColW1, macroLvColW2, macroLvColW3, macroLvColW4
    macroLvColW1 := LV_GetColumnWidth(lvMacroSteps, 1)
    macroLvColW2 := LV_GetColumnWidth(lvMacroSteps, 2)
    macroLvColW3 := LV_GetColumnWidth(lvMacroSteps, 3)
    macroLvColW4 := LV_GetColumnWidth(lvMacroSteps, 4)
    gMacro.Destroy()
    gMacro := ""
    lvMacroSteps := ""
    lbSavedMacros := ""
    SaveMappings()
    UpdateMacroSelectDdl()
}

RefreshSavedMacrosList(selectName := "") {
    global savedMacroOrder, lbSavedMacros
    if !IsObject(lbSavedMacros)
        return
    lbSavedMacros.Delete()
    if savedMacroOrder.Length
        lbSavedMacros.Add(savedMacroOrder)
    if selectName != "" {
        for i, name in savedMacroOrder {
            if name = selectName {
                lbSavedMacros.Choose(i)
                break
            }
        }
    }
}

OnSavedMacroSelectionChange() {
    global lbSavedMacros, savedMacros, macroEditSteps
    name := lbSavedMacros.Text
    if name = "" || !savedMacros.Has(name)
        return
    macroEditSteps := CloneMacroSteps(savedMacros[name])
    RefreshMacroStepsList()
}

OpenSaveMacroNameDialog() {
    global macroEditSteps, gMacro
    if macroEditSteps.Length = 0 {
        MsgBox("Add at least one step before saving a macro.", "Nothing to save", "Icon!")
        return
    }
    gSaveMacroName := Gui("+Owner" gMacro.Hwnd, "Save Macro As")
    gSaveMacroName.SetFont("s10", "Segoe UI")
    gSaveMacroName.Add("Text", "xm y10", "Macro name:")
    edSaveMacroName := gSaveMacroName.Add("Edit", "x+10 yp-3 w200")
    btnOkSaveMacro := gSaveMacroName.Add("Button", "xm y+15 w90 Default", "OK")
    btnCancelSaveMacro := gSaveMacroName.Add("Button", "x+10 w90", "Cancel")
    btnOkSaveMacro.OnEvent("Click", (*) => CommitSaveMacroAs(edSaveMacroName, gSaveMacroName))
    btnCancelSaveMacro.OnEvent("Click", (*) => gSaveMacroName.Destroy())
    gSaveMacroName.OnEvent("Close", (*) => gSaveMacroName.Destroy())
    gSaveMacroName.Show("AutoSize")
    edSaveMacroName.Focus()
}

CommitSaveMacroAs(edSaveMacroName, gSaveMacroName) {
    global savedMacros, savedMacroOrder, macroEditSteps
    name := Trim(edSaveMacroName.Value)
    if name = "" {
        MsgBox("Enter a name for the macro.", "Name required", "Icon!")
        return
    }
    if savedMacros.Has(name) {
        if MsgBox("A saved macro named '" name "' already exists. Overwrite it?", "Overwrite?", "YesNo Icon!") != "Yes"
            return
    } else
        savedMacroOrder.Push(name)
    savedMacros[name] := CloneMacroSteps(macroEditSteps)
    RefreshSavedMacrosList(name)
    SaveMappings()
    gSaveMacroName.Destroy()
}

UpdateSelectedSavedMacro() {
    global lbSavedMacros, savedMacros, macroEditSteps
    name := lbSavedMacros.Text
    if name = "" {
        MsgBox("Select a saved macro to update first.", "Nothing selected", "Icon!")
        return
    }
    if macroEditSteps.Length = 0 {
        MsgBox("Add at least one step before updating a saved macro.", "Nothing to save", "Icon!")
        return
    }
    savedMacros[name] := CloneMacroSteps(macroEditSteps)
    RefreshSavedMacrosList(name)
    SaveMappings()
}

DeleteSelectedSavedMacro() {
    global lbSavedMacros, savedMacros, savedMacroOrder, mappings, mapOrder, currentMacroSteps, editingId
    name := lbSavedMacros.Text
    if name = "" {
        MsgBox("Select a saved macro to delete first.", "Nothing selected", "Icon!")
        return
    }
    linkedKeys := []
    for key in mapOrder {
        m := mappings[key]
        if MapActionType(m) = "macro" && (m.HasOwnProp("macroName") ? m.macroName : "") = name
            linkedKeys.Push(key)
    }
    prompt := "Delete the saved macro '" name "'? This cannot be undone."
    if linkedKeys.Length > 0
        prompt := "The saved macro '" name "' is currently used by " linkedKeys.Length " button mapping" (linkedKeys.Length = 1 ? "" : "s") ".`n`nDeleting it will unlink those mappings and freeze their CURRENT steps in place, so they keep working exactly as they do now - they just won't follow any future edits to this macro anymore.`n`nDelete anyway?"
    if MsgBox(prompt, "Delete saved macro", "YesNo Icon!") != "Yes"
        return
    for key in linkedKeys {
        m := mappings[key]
        m.macroSteps := CloneMacroSteps(ResolveMacroSteps(m))
        m.macroName := ""
    }
    savedMacros.Delete(name)
    for i, n in savedMacroOrder {
        if n = name {
            savedMacroOrder.RemoveAt(i)
            break
        }
    }
    RefreshSavedMacrosList()
    if editingId != "" && mappings.Has(editingId) && HasVal(linkedKeys, editingId)
        currentMacroSteps := CloneMacroSteps(mappings[editingId].macroSteps)
    SaveMappings()
}

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
    macroStepCaptureHook := NewCaptureInputHook(
        (ihObj, VK, SC) => MacroStepKeyDown(ihObj, VK, SC, edCtrl),
        (ihObj, VK, SC) => MacroStepKeyUp(ihObj, VK, SC, edCtrl))
}

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
        return
    }
    keyName := KeyNameFor(VK, SC)
    macroStepCapturedTarget := BuildModStrFromHeld(macroStepHeldMods) FormatSendKey(keyName)
    edCtrl.Value := HumanizeSendKey(macroStepCapturedTarget)
    macroStepComboFired := true
}

MacroStepKeyUp(ihObj, VK, SC, edCtrl) {
    global macroStepHeldMods, macroStepComboFired, macroStepCapturedTarget
    if !IsModifierVK(VK)
        return
    macroStepHeldMods.Delete(VK)
    allModsUp := (macroStepHeldMods.Count = 0)
    if macroStepComboFired {
        if allModsUp
            macroStepComboFired := false
        return
    }
    if !allModsUp
        return
    keyName := KeyNameFor(VK, SC)
    macroStepCapturedTarget := FormatSendKey(keyName)
    edCtrl.Value := HumanizeSendKey(macroStepCapturedTarget)
}

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

SaveMapping(isNew, targetList := "Main") {
    global lastCaptureKind, capturedSC, capturedRawPage, capturedRawBytesHex, capturedRawUpBytesHex, editingId, editingProfileName, currentMacroSteps
    actionVal := ddlActionType.Value
    isApp := actionVal = 2
    isMultimedia := actionVal = 3
    isMouse := actionVal = 4
    isMacro := actionVal = 5
    macroStepsToSave := []
    macroNameToSave := ""
    if isApp {
        target := editAppPath.Value
        if target = "" {
            MsgBox("Enter an app/file path first (or use Browse...).", "Missing target", "Icon!")
            return
        }
        appArgs := editAppArgs.Value
    } else if isMacro {
        if currentMacroSteps.Length = 0 {
            MsgBox("Choose a saved macro from the dropdown, or add steps via Macros, first.", "Empty macro", "Icon!")
            return
        }
        target := ""
        appArgs := ""
        for s in currentMacroSteps
            macroStepsToSave.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
        macroNameToSave := FindSavedMacroNameForSteps(macroStepsToSave)
    } else {
        target := isMultimedia ? MultimediaSendForIndex(ddlMultimedia.Value) : (isMouse ? MouseSendForIndex(ddlMouse.Value) : targetSendString)
        if target = "" {
            MsgBox(isMultimedia ? "Choose a multimedia action first." : (isMouse ? "Choose a mouse action first." : "Capture a key/combo to send first."), "Missing target", "Icon!")
            return
        }
        appArgs := ""
    }
    actionType := isApp ? "app" : (isMacro ? "macro" : "key")

    runModeVal := ddlRunMode.Value
    runMode := runModeVal = 2 ? "repeat" : (runModeVal = 3 ? "toggle" : (runModeVal = 4 ? "hold" : (runModeVal = 5 ? "toggleHold" : "single")))
    repeatMs := IsInteger(edRepeatMs.Value) ? Integer(edRepeatMs.Value) : 100
    if repeatMs < 2
        repeatMs := 2

    if !isNew && (editingId = "" || !mappings.Has(editingId)) {
        MsgBox("Select a mapping in the list first, then click Update Mapping.`n`nTo create a new mapping (even on the same button), use Add to Main or Add to Mod instead.", "Nothing selected", "Icon!")
        return
    }

    id := ""
    if lastCaptureKind = "raw" {
        if capturedRawBytesHex = "" {
            MsgBox("Capture a button first.", "Missing input", "Icon!")
            return
        }
        buttonKey := MakeRawButtonKey(capturedRawPage, capturedRawBytesHex)
        id := isNew ? GenerateId(editingProfileName, buttonKey) : editingId
        prevEnabled := mappings.Has(id) ? mappings[id].enabled : true
        mList := isNew ? targetList : (MapList(mappings[id]))
        dispId := SubStr(id, StrLen(editingProfileName) + 3)
        desc := editDesc.Value != "" ? editDesc.Value : Format("Raw 0x{:X} {} ({})", capturedRawPage, capturedRawBytesHex, dispId)
        if !mappings.Has(id)
            mapOrder.Push(id)
        rawHoldCapable := capturedRawUpBytesHex != ""
        rawRunMode := rawHoldCapable ? runMode : "single"
        rawPressType := rawHoldCapable ? (rawRunMode = "single" ? PressTypeFromDdlIndex(ddlPressType.Value) : "short") : "short"
        mappings[id] := {profile: editingProfileName, kind: "raw", actionType: actionType, page: capturedRawPage, bytesHex: capturedRawBytesHex, upBytesHex: capturedRawUpBytesHex, desc: desc, target: target, appArgs: appArgs, macroSteps: macroStepsToSave, macroName: macroNameToSave, enabled: prevEnabled, pressType: rawPressType, runMode: rawRunMode, repeatMs: repeatMs, list: mList}
        StopRepeat(id)
    } else {
        if !capturedSC {
            MsgBox("Capture a button first.", "Missing input", "Icon!")
            return
        }
        buttonKey := Format("SC{:03X}", capturedSC)
        id := isNew ? GenerateId(editingProfileName, buttonKey) : editingId

        oldButtonKey := ""
        if !isNew && (MapKind(mappings[editingId])) = "sc" {
            ob := Format("SC{:03X}", mappings[editingId].sc)
            if ob != buttonKey
                oldButtonKey := ob
        }

        prevEnabled := mappings.Has(id) ? mappings[id].enabled : true
        mList := isNew ? targetList : (MapList(mappings[id]))
        dispId := SubStr(id, StrLen(editingProfileName) + 3)
        desc := editDesc.Value != "" ? editDesc.Value : dispId
        if !mappings.Has(id)
            mapOrder.Push(id)
        mappings[id] := {profile: editingProfileName, kind: "sc", actionType: actionType, sc: capturedSC, desc: desc, target: target, appArgs: appArgs, macroSteps: macroStepsToSave, macroName: macroNameToSave, enabled: prevEnabled, pressType: (runMode = "single" ? PressTypeFromDdlIndex(ddlPressType.Value) : "short"), runMode: runMode, repeatMs: repeatMs, list: mList}
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

RegisterHotkeyForButton(buttonKey) {
    global activeProfileName, modifierKind, modifierSc, profiles
    effProfile := EffectiveProfileForButton(buttonKey, "sc")
    hasFiring := false
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != "sc"
            continue
        if (MapProfile(m)) != effProfile
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        hasFiring := true
        break
    }
    isModifierButton := modifierKind = "sc" && Format("SC{:03X}", modifierSc) = buttonKey
    if !isModifierButton {
        for pname, pdata in profiles {
            if (pdata.HasOwnProp("modKind") ? pdata.modKind : "none") = "sc" && Format("SC{:03X}", pdata.modSc) = buttonKey {
                isModifierButton := true
                break
            }
        }
    }
    state := (masterEnabled && (hasFiring || isModifierButton)) ? "On" : "Off"
    try {
        Hotkey("*" buttonKey, (*) => OnButtonDown(buttonKey), state)
        Hotkey("*" buttonKey " Up", (*) => OnButtonUp(buttonKey), state)
    } catch as e {
        MsgBox("Could not register hotkey for " buttonKey ":`n" e.Message, "Error", "Icon!")
    }
}

RegisterModifierHotkey() {
    global modifierKind, modifierSc, modifierHotkeyRegisteredSc, modifierActive
    modifierActive := false
    RefreshModifierLiveIndicator()
    oldSc := modifierHotkeyRegisteredSc
    newSc := (modifierKind = "sc") ? modifierSc : 0
    modifierHotkeyRegisteredSc := newSc
    if oldSc && oldSc != newSc
        RegisterHotkeyForButton(Format("SC{:03X}", oldSc))
    if newSc
        RegisterHotkeyForButton(Format("SC{:03X}", newSc))
}

EffectiveProfileForButton(buttonKey, kind := "sc") {
    global activeProfileName, mapOrder, mappings
    if activeProfileName = "Default"
        return "Default"
    for id in mapOrder {
        m := mappings[id]
        mKind := MapKind(m)
        if mKind != kind
            continue
        if (MapProfile(m)) != activeProfileName
            continue
        mButtonKey := mKind = "raw" ? (MakeRawButtonKey(m.page, m.bytesHex)) : Format("SC{:03X}", m.sc)
        if mButtonKey = buttonKey
            return activeProfileName
    }
    return "Default"
}

FindRawMappingUpBytes(page, downBytesHex) {
    global mapOrder, mappings
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != "raw"
            continue
        if m.page != page || m.bytesHex != downBytesHex
            continue
        up := m.HasOwnProp("upBytesHex") ? m.upBytesHex : ""
        if up != ""
            return up
    }
    return ""
}

FindRawMappingDownBytesForUp(page, upBytesHexCandidate) {
    global mapOrder, mappings
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != "raw"
            continue
        if m.page != page
            continue
        up := m.HasOwnProp("upBytesHex") ? m.upBytesHex : ""
        if up != "" && up = upBytesHexCandidate
            return m.bytesHex
    }
    return ""
}

MappingButtonKey(m) {
    mKind := MapKind(m)
    return mKind = "raw" ? (MakeRawButtonKey(m.page, m.bytesHex)) : Format("SC{:03X}", m.sc)
}

OnButtonDown(buttonKey, kind := "sc") {
    global buttonPressState, longPressMs, mapOrder, mappings, activeProfileName
    global modifierKind, modifierSc, modifierMode, modifierActive
    st := buttonPressState.Has(buttonKey) ? buttonPressState[buttonKey] : ""
    if st && st.pressed
        return
    effMod := EffectiveModifier(activeProfileName)
    if effMod.kind = "sc" && Format("SC{:03X}", effMod.sc) = buttonKey {
        if effMod.mode = "toggle" {
            modifierActive := !modifierActive
            NotifyModifierToggled()
        } else
            modifierActive := true
    }
    RefreshModifierLiveIndicator()
    effProfile := EffectiveProfileForButton(buttonKey, kind)
    activeList := modifierActive ? "Mod" : "Main"
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != kind
            continue
        if (MapProfile(m)) != effProfile
            continue
        if MappingButtonKey(m) != buttonKey || !m.enabled
            continue
        if (MapList(m)) != activeList
            continue
        if (m.HasOwnProp("runMode") ? m.runMode : "single") = "repeat"
            StartRepeat(id)
        else if (m.HasOwnProp("runMode") ? m.runMode : "single") = "hold"
            FireHoldDown(id, m)
    }
    token := (st ? st.token : 0) + 1
    buttonPressState[buttonKey] := {pressed: true, token: token, longFired: false}
    FireButtonMappings(buttonKey, "press", kind)
    SetTimer(() => CheckLongPress(buttonKey, token, kind), -Max(1, longPressMs))
}

CheckLongPress(buttonKey, token, kind := "sc") {
    global buttonPressState
    if !buttonPressState.Has(buttonKey)
        return
    st := buttonPressState[buttonKey]
    if st.token != token || !st.pressed || st.longFired
        return
    st.longFired := true
    FireButtonMappings(buttonKey, "long", kind)
}

OnButtonUp(buttonKey, kind := "sc") {
    global buttonPressState, mapOrder, mappings, activeProfileName
    global modifierKind, modifierSc, modifierMode, modifierActive
    if !buttonPressState.Has(buttonKey)
        return
    st := buttonPressState[buttonKey]
    if !st.pressed
        return
    st.pressed := false
    effMod := EffectiveModifier(activeProfileName)
    if effMod.kind = "sc" && Format("SC{:03X}", effMod.sc) = buttonKey && effMod.mode != "toggle"
        modifierActive := false
    RefreshModifierLiveIndicator()
    effProfile := EffectiveProfileForButton(buttonKey, kind)
    activeList := modifierActive ? "Mod" : "Main"
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != kind
            continue
        if (MapProfile(m)) != effProfile
            continue
        if MappingButtonKey(m) != buttonKey || !m.enabled
            continue
        if (MapList(m)) != activeList
            continue
        runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
        if runMode = "repeat"
            StopRepeat(id)
        else if runMode = "toggle"
            ToggleRepeat(id)
        else if runMode = "hold"
            FireHoldUp(id, m)
        else if runMode = "toggleHold"
            ToggleHold(id, m)
    }
    FireButtonMappings(buttonKey, "release", kind)
    if !st.longFired
        FireButtonMappings(buttonKey, "short", kind)
}

FireButtonMappings(buttonKey, pressType, kind := "sc") {
    global activeProfileName, modifierActive
    effProfile := EffectiveProfileForButton(buttonKey, kind)
    activeList := modifierActive ? "Mod" : "Main"
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != kind
            continue
        if (MapProfile(m)) != effProfile
            continue
        if MappingButtonKey(m) != buttonKey || !m.enabled
            continue
        if (MapList(m)) != activeList
            continue
        if (m.HasOwnProp("runMode") ? m.runMode : "single") != "single"
            continue
        mPressType := m.HasOwnProp("pressType") ? m.pressType : "short"
        if mPressType != pressType
            continue
        FireMapping(m)
    }
}

StartRepeat(id) {
    global repeatActive, repeatTimerFns, repeatStartQpc, repeatFireCount, mappings
    if repeatActive.Has(id) && repeatActive[id]
        return
    if !mappings.Has(id)
        return
    m := mappings[id]
    ms := m.HasOwnProp("repeatMs") ? m.repeatMs : 100
    if ms < 1
        ms := 1
    fn := () => RepeatTick(id)
    repeatTimerFns[id] := fn
    repeatActive[id] := true
    repeatStartQpc[id] := QpcNow()
    repeatFireCount[id] := 1
    FireMapping(m)
    SetTimer(fn, Max(1, Min(ms, 5)))
}

RepeatTick(id) {
    global mappings, repeatStartQpc, repeatFireCount
    if !mappings.Has(id) || !mappings[id].enabled {
        StopRepeat(id)
        return
    }
    m := mappings[id]
    ms := m.HasOwnProp("repeatMs") ? m.repeatMs : 100
    if ms < 1
        ms := 1
    elapsedMs := (QpcNow() - repeatStartQpc[id]) * 1000 / QpcFreq()
    expected := Floor(elapsedMs / ms) + 1
    loopCount := Min(expected - repeatFireCount[id], 50)
    loop loopCount {
        FireMapping(m)
        repeatFireCount[id] += 1
    }
}

StopRepeat(id) {
    global repeatActive, repeatTimerFns, repeatStartQpc, repeatFireCount
    if repeatTimerFns.Has(id) {
        SetTimer(repeatTimerFns[id], 0)
        repeatTimerFns.Delete(id)
    }
    if repeatStartQpc.Has(id)
        repeatStartQpc.Delete(id)
    if repeatFireCount.Has(id)
        repeatFireCount.Delete(id)
    repeatActive[id] := false
}

ToggleRepeat(id) {
    global repeatActive
    if repeatActive.Has(id) && repeatActive[id]
        StopRepeat(id)
    else
        StartRepeat(id)
}

ToggleHold(id, m) {
    global heldMappings
    if heldMappings.Has(id)
        FireHoldUp(id, m)
    else
        FireHoldDown(id, m)
}

StopAllRepeats() {
    global repeatActive, repeatTimerFns, repeatStartQpc, repeatFireCount
    ReleaseAllHolds()
    for id, fn in repeatTimerFns
        SetTimer(fn, 0)
    repeatTimerFns := Map()
    repeatActive := Map()
    repeatStartQpc := Map()
    repeatFireCount := Map()
}

ResolveMacroSteps(m) {
    global savedMacros
    macroName := m.HasOwnProp("macroName") ? m.macroName : ""
    if macroName != "" && savedMacros.Has(macroName)
        return savedMacros[macroName]
    return m.HasOwnProp("macroSteps") ? m.macroSteps : []
}

FireMapping(m) {
    actionType := MapActionType(m)
    if actionType = "app"
        LaunchApp(m.target, m.HasOwnProp("appArgs") ? m.appArgs : "")
    else if actionType = "macro"
        RunMacroOnce(ResolveMacroSteps(m))
    else
        Send(m.target)
}

heldMappings := Map()

FireHoldDown(id, m) {
    global heldMappings
    actionType := MapActionType(m)
    if actionType != "key" {
        FireMapping(m)
        return
    }
    strs := BuildHoldSendStrings(m.target)
    heldMappings[id] := strs.up
    Send(strs.down)
}

FireHoldUp(id, m) {
    global heldMappings
    actionType := MapActionType(m)
    if actionType != "key"
        return
    if heldMappings.Has(id) {
        Send(heldMappings[id])
        heldMappings.Delete(id)
    } else {
        Send(BuildHoldSendStrings(m.target).up)
    }
}

ReleaseAllHolds() {
    global heldMappings
    for id, upStr in heldMappings
        Send(upStr)
    heldMappings := Map()
}

BuildHoldSendStrings(sendStr) {
    mods := []
    i := 1
    len := StrLen(sendStr)
    while i <= len {
        c := SubStr(sendStr, i, 1)
        if c = "^"
            mods.Push("Ctrl")
        else if c = "!"
            mods.Push("Alt")
        else if c = "+"
            mods.Push("Shift")
        else if c = "#"
            mods.Push("Win")
        else
            break
        i++
    }
    rest := SubStr(sendStr, i)
    keyName := ""
    if rest != "" {
        if SubStr(rest, 1, 1) = "{" && SubStr(rest, -1) = "}"
            keyName := SubStr(rest, 2, StrLen(rest) - 2)
        else
            keyName := rest
    }
    downStr := ""
    for modName in mods
        downStr .= "{" modName " down}"
    if keyName != ""
        downStr .= "{" keyName " down}"
    upStr := ""
    if keyName != ""
        upStr .= "{" keyName " up}"
    loop mods.Length {
        upStr .= "{" mods[mods.Length - A_Index + 1] " up}"
    }
    return {down: downStr, up: upStr}
}

RunMacroOnce(steps) {
    for s in steps {
        if s.type = "key"
            Send(s.target)
        else if s.type = "keydown"
            Send(BuildHoldSendStrings(s.target).down)
        else if s.type = "keyup"
            Send(BuildHoldSendStrings(s.target).up)
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
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, capturedRawUpBytesHex, rawCaptureAwaitingRelease, rawCaptureReleaseWindowToken, lastCaptureKind, rawCaptureArmed, editingId, currentMacroSteps
    capturedSC := 0
    capturedRawPage := 0
    capturedRawBytesHex := ""
    capturedRawUpBytesHex := ""
    rawCaptureAwaitingRelease := false
    rawCaptureReleaseWindowToken++
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
    ddlMultimedia.Choose(1)
    ddlMouse.Choose(1)
    OnActionTypeChange()
    ddlRunMode.Choose(1)
    edRepeatMs.Value := "100"
    OnRunModeChange()
    ddlPressType.Choose(DdlIndexFromPressType("press"))
    UpdateMacroSelectDdl()
    txtCaptureStatus.Value := "Not captured yet."
    ReconcileMainHoldDdls()
}

LV_GetTopIndex(ctrl) {
    return SendMessage(0x1027, 0, 0, , "ahk_id " ctrl.Hwnd)
}

LV_RestoreTopIndex(ctrl, topIndex) {
    count := ctrl.GetCount()
    if count = 0 || topIndex <= 0
        return
    if topIndex > count - 1
        topIndex := count - 1
    SendMessage(0x1013, count - 1, 0, , "ahk_id " ctrl.Hwnd)
    SendMessage(0x1013, topIndex, 0, , "ahk_id " ctrl.Hwnd)
}

LV_GetColumnWidth(ctrl, col) {
    return SendMessage(0x101D, col - 1, 0, , "ahk_id " ctrl.Hwnd)
}

lvKeys := []

FindSavedMacroNameForSteps(steps) {
    global savedMacros, savedMacroOrder
    if !steps.Length
        return ""
    encoded := MacroStepsEncode(steps)
    for name in savedMacroOrder {
        if savedMacros.Has(name) && MacroStepsEncode(savedMacros[name]) = encoded
            return name
    }
    return ""
}

RefreshList() {
    global lvKeys, editingProfileName, editingListName
    topIndex := LV_GetTopIndex(lv)
    lv.Delete()
    lvKeys := []
    for key in mapOrder {
        m := mappings[key]
        if (MapProfile(m)) != editingProfileName
            continue
        if (MapList(m)) != editingListName
            continue
        actionType := MapActionType(m)
        if actionType = "app" {
            args := m.HasOwnProp("appArgs") ? m.appArgs : ""
            sendsDisplay := "Launch: " m.target (args != "" ? " " args : "")
        } else if actionType = "macro" {
            steps := ResolveMacroSteps(m)
            savedName := m.HasOwnProp("macroName") ? m.macroName : ""
            if savedName = ""
                savedName := FindSavedMacroNameForSteps(steps)
            if savedName != ""
                sendsDisplay := "Macro: " savedName
            else {
                n := steps.Length
                sendsDisplay := "Macro (" n " step" (n = 1 ? "" : "s") ")"
            }
        } else {
            sendsDisplay := HumanizeSendKey(m.target)
        }
        runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
        if runMode = "repeat"
            pressDisplay := "Repeat"
        else if runMode = "toggle"
            pressDisplay := "TRepeat"
        else if runMode = "hold"
            pressDisplay := "Hold"
        else if runMode = "toggleHold"
            pressDisplay := "THold"
        else {
            mPressType := m.HasOwnProp("pressType") ? m.pressType : "short"
            pressDisplay := mPressType = "press" ? "Press" : (mPressType = "long" ? "Long" : (mPressType = "release" ? "Release" : "Short"))
        }
        lv.Add(, m.enabled ? "Yes" : "No", m.desc, sendsDisplay, pressDisplay)
        lvKeys.Push(key)
    }
    LV_RestoreTopIndex(lv, topIndex)
}

LVSelect(lvObj, rowNum, selected) {
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, capturedRawUpBytesHex, lastCaptureKind, editingId, lvKeys, currentMacroSteps
    if !selected
        return
    if rowNum < 1 || rowNum > lvKeys.Length
        return
    key := lvKeys[rowNum]
    m := mappings[key]
    editingId := key
    currentMacroSteps := CloneMacroSteps(ResolveMacroSteps(m))
    ApplyActionFieldsFromMapping(m)
    ddlPressType.Choose(DdlIndexFromPressType(m.HasOwnProp("pressType") ? m.pressType : "short"))
    runMode := m.HasOwnProp("runMode") ? m.runMode : "single"
    ddlRunMode.Choose(runMode = "repeat" ? 2 : (runMode = "toggle" ? 3 : (runMode = "hold" ? 4 : (runMode = "toggleHold" ? 5 : 1))))
    edRepeatMs.Value := String(m.HasOwnProp("repeatMs") ? m.repeatMs : 100)
    OnRunModeChange()
    if (MapKind(m)) = "raw" {
        capturedSC := 0
        capturedRawPage := m.page
        capturedRawBytesHex := m.bytesHex
        capturedRawUpBytesHex := m.HasOwnProp("upBytesHex") ? m.upBytesHex : ""
        lastCaptureKind := "raw"
        editDesc.Value := m.desc
        if capturedRawUpBytesHex = "" {
            ddlRunMode.Choose(1)
            OnRunModeChange()
            txtCaptureStatus.Value := Format("Editing raw mapping (Page:0x{:X} Bytes:{}) - single-shot, no release signature learned - press Update Mapping to save changes, or Add to Main/Add to Mod for a new one on this same button", m.page, m.bytesHex)
        } else {
            txtCaptureStatus.Value := Format("Editing raw mapping (Page:0x{:X} Bytes:{}, release: Bytes:{}) - press Update Mapping to save changes, or Add to Main/Add to Mod for a new one on this same button", m.page, m.bytesHex, capturedRawUpBytesHex)
        }
        ReconcileMainHoldDdls()
        return
    }
    lastCaptureKind := "sc"
    capturedSC := m.sc
    editDesc.Value := m.desc
    txtCaptureStatus.Value := "Editing " key " (press Update Mapping to save changes, or Add to Main/Add to Mod for a new one on this same button)"
    ReconcileMainHoldDdls()
}

LVContextMenu(GuiCtrlObj, Item, IsRightClick, X, Y) {
    global lvKeys, editingProfileName, profiles, savedMacros, savedMacroOrder
    if !Item || Item > lvKeys.Length
        return

    isPartOfSelection := false
    row := 0
    loop {
        row := lv.GetNext(row)
        if !row
            break
        if row = Item {
            isPartOfSelection := true
            break
        }
    }
    if !isPartOfSelection
        lv.Modify(Item, "Select Focus")
    else
        lv.Modify(Item, "Focus")

    keys := []
    row := 0
    loop {
        row := lv.GetNext(row)
        if !row
            break
        if mappings.Has(lvKeys[row])
            keys.Push(lvKeys[row])
    }
    if !keys.Length
        return

    ctxMenu := Menu()

    copyMenu := Menu()
    otherCount := 0
    for pname in profiles {
        if pname = editingProfileName
            continue
        otherCount++
        copyMenu.Add(pname, CopyMappingsToProfile.Bind(keys, pname))
    }
    if !otherCount {
        copyMenu.Add("No other profiles", (*) => "")
        copyMenu.Disable("No other profiles")
    }
    ctxMenu.Add("Copy to", copyMenu)

    macroMenu := Menu()
    if savedMacroOrder.Length {
        for mname in savedMacroOrder
            macroMenu.Add(mname, AssignMacroToMappings.Bind(keys, mname))
    } else {
        macroMenu.Add("No saved macros", (*) => "")
        macroMenu.Disable("No saved macros")
    }
    ctxMenu.Add("Map macro", macroMenu)

    MouseGetPos(&mx, &my)
    ctxMenu.Show(mx, my)
}

AssignMacroToMappings(targetKeys, macroName, *) {
    global mappings, savedMacros, editingId, currentMacroSteps
    if !savedMacros.Has(macroName)
        return
    steps := savedMacros[macroName]
    appliedCount := 0
    lastDesc := ""
    for key in targetKeys {
        if !mappings.Has(key)
            continue
        m := mappings[key]
        m.actionType := "macro"
        m.macroSteps := CloneMacroSteps(steps)
        m.macroName := macroName
        m.target := ""
        m.appArgs := ""
        appliedCount++
        lastDesc := m.desc
    }
    if !appliedCount
        return
    SaveMappings()
    RefreshList()
    if editingId != "" && HasVal(targetKeys, editingId) && mappings.Has(editingId) {
        currentMacroSteps := CloneMacroSteps(ResolveMacroSteps(mappings[editingId]))
        ApplyActionFieldsFromMapping(mappings[editingId])
    }
    txtStatus.Value := appliedCount = 1
        ? "Mapped macro '" macroName "' to '" lastDesc "'."
        : "Mapped macro '" macroName "' to " appliedCount " mappings."
}

CopyMappingsToProfile(sourceKeys, targetProfile, *) {
    copiedCount := 0
    lastDesc := ""
    for sourceKey in sourceKeys {
        if !mappings.Has(sourceKey)
            continue
        src := mappings[sourceKey]
        kind := MapKind(src)
        buttonKey := kind = "raw" ? (MakeRawButtonKey(src.page, src.bytesHex)) : Format("SC{:03X}", src.sc)
        newId := GenerateId(targetProfile, buttonKey)

        newMap := {
            profile: targetProfile,
            kind: kind,
            actionType: MapActionType(src),
            desc: src.desc,
            target: src.target,
            appArgs: src.HasOwnProp("appArgs") ? src.appArgs : "",
            macroSteps: src.HasOwnProp("macroSteps") ? CloneMacroSteps(src.macroSteps) : [],
            macroName: src.HasOwnProp("macroName") ? src.macroName : "",
            enabled: src.enabled,
            pressType: src.HasOwnProp("pressType") ? src.pressType : "short",
            runMode: src.HasOwnProp("runMode") ? src.runMode : "single",
            repeatMs: src.HasOwnProp("repeatMs") ? src.repeatMs : 100,
            list: MapList(src)
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

        copiedCount++
        lastDesc := src.desc
    }

    if !copiedCount
        return

    SaveMappings()
    if targetProfile = editingProfileName
        RefreshList()
    txtStatus.Value := copiedCount = 1
        ? "Copied '" lastDesc "' to profile '" targetProfile "'."
        : "Copied " copiedCount " mappings to profile '" targetProfile "'."
}

CloneMacroSteps(steps) {
    out := []
    for s in steps
        out.Push({type: s.type, target: s.target, args: s.args, delayAfterMs: s.delayAfterMs})
    return out
}

ApplyActionFieldsFromMapping(m) {
    global targetSendString
    actionType := MapActionType(m)
    if actionType = "app" {
        ddlActionType.Choose(2)
        editAppPath.Value := m.target
        editAppArgs.Value := m.HasOwnProp("appArgs") ? m.appArgs : ""
        targetSendString := ""
        txtTarget.Value := ""
    } else if actionType = "macro" {
        ddlActionType.Choose(5)
        targetSendString := ""
        txtTarget.Value := ""
        editAppPath.Value := ""
        editAppArgs.Value := ""
    } else {
        mmIdx := MultimediaIndexForSend(m.target)
        mouseIdx := MouseIndexForSend(m.target)
        if mmIdx {
            ddlActionType.Choose(3)
            ddlMultimedia.Choose(mmIdx)
        } else if mouseIdx {
            ddlActionType.Choose(4)
            ddlMouse.Choose(mouseIdx)
        } else {
            ddlActionType.Choose(1)
        }
        targetSendString := m.target
        txtTarget.Value := HumanizeSendKey(m.target)
        editAppPath.Value := ""
        editAppArgs.Value := ""
    }
    OnActionTypeChange()
    UpdateMacroSelectDdl()
}

MoveKeymapRow(dir) {
    global mapOrder, lvKeys
    selKeys := GetSelectedKeys()
    if selKeys.Length = 0 {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    selectedSet := Map()
    for k in selKeys
        selectedSet[k] := true
    visible := lvKeys.Clone()
    n := visible.Length
    swaps := []
    if dir < 0 {
        loop n - 1 {
            i := A_Index + 1
            if selectedSet.Has(visible[i]) && !selectedSet.Has(visible[i - 1]) {
                swaps.Push([visible[i], visible[i - 1]])
                tmp := visible[i]
                visible[i] := visible[i - 1]
                visible[i - 1] := tmp
            }
        }
    } else {
        loop n - 1 {
            i := n - A_Index
            if selectedSet.Has(visible[i]) && !selectedSet.Has(visible[i + 1]) {
                swaps.Push([visible[i], visible[i + 1]])
                tmp := visible[i]
                visible[i] := visible[i + 1]
                visible[i + 1] := tmp
            }
        }
    }
    if swaps.Length = 0
        return
    for pair in swaps {
        idxA := 0
        idxB := 0
        for i, k in mapOrder {
            if k = pair[1]
                idxA := i
            else if k = pair[2]
                idxB := i
        }
        if idxA && idxB {
            tmp := mapOrder[idxA]
            mapOrder[idxA] := mapOrder[idxB]
            mapOrder[idxB] := tmp
        }
    }
    SaveMappings()
    RefreshList()
    ReselectKeys(selKeys)
}

GetSelectedKeys() {
    global lvKeys
    keys := []
    row := 0
    loop {
        row := lv.GetNext(row)
        if !row
            break
        if row <= lvKeys.Length
            keys.Push(lvKeys[row])
    }
    return keys
}

ReselectKeys(keys) {
    global lvKeys
    keySet := Map()
    for k in keys
        keySet[k] := true
    first := true
    for row, k in lvKeys {
        if keySet.Has(k) {
            lv.Modify(row, first ? "Select Focus" : "Select")
            first := false
        }
    }
}

ToggleMappingKeys(keys) {
    global mappings
    if keys.Length = 0
        return
    buttonKeysToRefresh := Map()
    for key in keys {
        m := mappings[key]
        m.enabled := !m.enabled
        if !m.enabled
            StopRepeat(key)
        if (MapKind(m)) = "sc"
            buttonKeysToRefresh[Format("SC{:03X}", m.sc)] := true
    }
    for bk in buttonKeysToRefresh
        RegisterHotkeyForButton(bk)
    SaveMappings()
    RefreshList()
    ReselectKeys(keys)
}

ToggleSelected(*) {
    keys := GetSelectedKeys()
    if keys.Length = 0 {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    ToggleMappingKeys(keys)
}

OnKeymapDoubleClick(GuiCtrlObj, RowNumber) {
    global lvKeys
    if RowNumber < 1 || RowNumber > lvKeys.Length
        return
    ToggleMappingKeys([lvKeys[RowNumber]])
}

RemoveSelected(*) {
    global mappings, mapOrder
    keys := GetSelectedKeys()
    if keys.Length = 0 {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    keySet := Map()
    buttonKeysToRefresh := Map()
    for key in keys {
        keySet[key] := true
        if mappings.Has(key) {
            m := mappings[key]
            if (MapKind(m)) = "sc"
                buttonKeysToRefresh[Format("SC{:03X}", m.sc)] := true
        }
    }
    for key in keys {
        StopRepeat(key)
        mappings.Delete(key)
    }
    newOrder := []
    for k in mapOrder {
        if !keySet.Has(k)
            newOrder.Push(k)
    }
    mapOrder := newOrder
    for bk in buttonKeysToRefresh
        RegisterHotkeyForButton(bk)
    SaveMappings()
    RefreshList()
    ResetCaptureUI()
}

RefreshAllScHotkeyStates() {
    global modifierKind, modifierSc, profiles
    seenButtons := Map()
    for id in mapOrder {
        m := mappings[id]
        if (MapKind(m)) != "sc"
            continue
        bk := Format("SC{:03X}", m.sc)
        if seenButtons.Has(bk)
            continue
        seenButtons[bk] := true
        RegisterHotkeyForButton(bk)
    }
    if modifierKind = "sc" {
        bk := Format("SC{:03X}", modifierSc)
        if !seenButtons.Has(bk) {
            seenButtons[bk] := true
            RegisterHotkeyForButton(bk)
        }
    }
    for pname, pdata in profiles {
        if (pdata.HasOwnProp("modKind") ? pdata.modKind : "none") != "sc"
            continue
        bk := Format("SC{:03X}", pdata.modSc)
        if !seenButtons.Has(bk) {
            seenButtons[bk] := true
            RegisterHotkeyForButton(bk)
        }
    }
}

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
        return
    }
    newProfile := ProfileForProcess(exeName)
    if newProfile != activeProfileName
        SwitchActiveProfile(newProfile)
}

SwitchActiveProfile(newName) {
    global activeProfileName, buttonPressState
    StopAllRepeats()
    activeProfileName := newName
    buttonPressState := Map()
    RefreshAllScHotkeyStates()
    UpdateActiveProfileStatus()
}

UpdateActiveProfileStatus() {
    global activeProfileName
    if IsObject(txtActiveProfile)
        txtActiveProfile.Value := "Active profile: " activeProfileName
    A_IconTip := "MF Button Mapper (" activeProfileName ")"
}

RefreshProfileList() {
    global profiles, editingProfileName
    topIndex := SendMessage(0x018E, 0, 0, , "ahk_id " lbProfiles.Hwnd)
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
    if names.Length > 0 && topIndex > 0 {
        if topIndex > names.Length - 1
            topIndex := names.Length - 1
        SendMessage(0x0197, topIndex, 0, , "ahk_id " lbProfiles.Hwnd)
    }
}

OnEditingProfileChange() {
    global editingProfileName
    editingProfileName := lbProfiles.Text
    RefreshList()
    ResetCaptureUI()
}

SetEditingList(name) {
    global editingListName
    editingListName := name
    radListMain.Value := (name = "Main") ? 1 : 0
    radListMod.Value := (name = "Mod") ? 1 : 0
    RefreshList()
    ResetCaptureUI()
}

OpenProfileDialog(mode) {
    global editingProfileName, profiles
    if mode = "rename" && editingProfileName = "Default" {
        MsgBox("The Default profile can't be edited.", "Not allowed", "Icon!")
        return
    }
    existingName := mode = "rename" ? editingProfileName : ""
    existingProcCsv := mode = "rename" ? JoinCsv(profiles[editingProfileName].processNames) : ""
    if mode = "rename" {
        pmSrc := profiles[editingProfileName]
        pmKind := pmSrc.HasOwnProp("modKind") ? pmSrc.modKind : "none"
        pmSc := pmSrc.HasOwnProp("modSc") ? pmSrc.modSc : 0
        pmRawPage := pmSrc.HasOwnProp("modRawPage") ? pmSrc.modRawPage : 0
        pmRawBytesHex := pmSrc.HasOwnProp("modRawBytesHex") ? pmSrc.modRawBytesHex : ""
        pmRawUpBytesHex := pmSrc.HasOwnProp("modRawUpBytesHex") ? pmSrc.modRawUpBytesHex : ""
        pmMode := pmSrc.HasOwnProp("modMode") ? pmSrc.modMode : "hold"
    } else {
        pmKind := "none"
        pmSc := 0
        pmRawPage := 0
        pmRawBytesHex := ""
        pmRawUpBytesHex := ""
        pmMode := "hold"
    }

    gp := Gui("+Owner" g.Hwnd, mode = "rename" ? "Edit Profile" : "New Profile")
    gp.SetFont("s10", "Segoe UI")
    gp.Add("Text", "xm y10", "Profile name:")
    edName := gp.Add("Edit", "x+10 yp-3 w200", existingName)
    gp.Add("Text", "xm y+12 w420", "Process names this profile activates for (comma-separated, e.g. kodi.exe, kodi64.exe):")
    edProc := gp.Add("Edit", "xm y+6 w330", existingProcCsv)
    btnBrowseProc := gp.Add("Button", "x+8 w80", "Browse...")
    btnBrowseProc.OnEvent("Click", (*) => BrowseForProcessNameInto(edProc))

    grpPm := gp.Add("GroupBox", "xm y+15 w420 h130", "Modifier Button (this profile only)")
    btnPmCapture := gp.Add("Button", "xp12 yp20 w110", "Capture")
    chkPmRaw := gp.Add("Checkbox", "x+12 yp+4", "Capture as raw HID")
    lblPmModeCaption := gp.Add("Text", "x+15 yp", "Mode:")
    ddlPmMode := gp.Add("DropDownList", "x+8 yp-4 w90 Choose1", ["Held", "Toggled"])
    btnPmCapture.GetPos(&pmCaptureX)
    btnPmClear := gp.Add("Button", "x" pmCaptureX " y+10 w110", "Clear (use main)")
    txtPmStatus := gp.Add("Text", "xm+12 y+10 w396", "Not set (using main modifier)")

    RefreshPmStatus() {
        if pmKind = "sc"
            txtPmStatus.Value := Format("Modifier: SC{:03X}", pmSc)
        else if pmKind = "raw" {
            holdNote := pmRawUpBytesHex != "" ? " - Hold capable" : " - Single shot"
            txtPmStatus.Value := Format("Modifier: Raw Page:0x{:X} Bytes:{}{}", pmRawPage, pmRawBytesHex, holdNote)
        } else
            txtPmStatus.Value := "Not set (using main modifier)"
    }
    UpdatePmModeUI() {
        if pmKind = "raw" && pmRawUpBytesHex = "" {
            pmMode := "toggle"
            ddlPmMode.Choose(2)
            ddlPmMode.Enabled := false
        } else {
            ddlPmMode.Enabled := true
            ddlPmMode.Choose(pmMode = "toggle" ? 2 : 1)
        }
    }
    RefreshPmStatus()
    UpdatePmModeUI()

    StartProfileModifierCapture(*) {
        global profileModCaptureSuspended, profileModRawCaptureArmed, profileModCaptureCallback, profileModCaptureStatusCallback, profileModCaptureHook
        CancelPendingProfileModifierCapture()
        if chkPmRaw.Value {
            profileModRawCaptureArmed := false
            txtPmStatus.Value := "Get ready... (waiting for your click to finish)"
            profileModCaptureCallback := (page, bytesHex, upBytesHex) => (
                pmKind := "raw",
                pmRawPage := page,
                pmRawBytesHex := bytesHex,
                pmRawUpBytesHex := upBytesHex,
                pmSc := 0,
                RefreshPmStatus(),
                UpdatePmModeUI())
            profileModCaptureStatusCallback := (text) => txtPmStatus.Value := text
            SetTimer(ArmProfileModifierRawCapture, -300)
            return
        }
        profileModCaptureSuspended := true
        IncrementCaptureSuspend()
        txtPmStatus.Value := "Waiting for button press..."
        profileModCaptureHook := NewCaptureInputHook((ihObj, VK, SC) => (
            ihObj.Stop(),
            pmKind := "sc",
            pmSc := SC,
            pmRawPage := 0,
            pmRawBytesHex := "",
            pmRawUpBytesHex := "",
            RefreshPmStatus(),
            UpdatePmModeUI(),
            ResumeProfileModifierHotkeysIfNeeded()))
    }
    ArmProfileModifierRawCapture() {
        global profileModRawCaptureArmed
        profileModRawCaptureArmed := true
        txtPmStatus.Value := "Waiting for button press (raw HID)..."
    }
    btnPmCapture.OnEvent("Click", StartProfileModifierCapture)
    ddlPmMode.OnEvent("Change", (*) => (pmMode := ddlPmMode.Value = 2 ? "toggle" : "hold"))
    btnPmClear.OnEvent("Click", (*) => (
        CancelPendingProfileModifierCapture(),
        pmKind := "none",
        pmSc := 0,
        pmRawPage := 0,
        pmRawBytesHex := "",
        pmRawUpBytesHex := "",
        pmMode := "hold",
        RefreshPmStatus(),
        UpdatePmModeUI()))

    btnSave := gp.Add("Button", "xm y+15 w100", "Save")
    btnSave.OnEvent("Click", (*) => SaveProfileDialog(mode, existingName, edName.Value, edProc.Value, pmKind, pmSc, pmRawPage, pmRawBytesHex, pmRawUpBytesHex, pmMode, gp))
    btnCancel := gp.Add("Button", "x+10 w100", "Cancel")
    btnCancel.OnEvent("Click", (*) => (CancelPendingProfileModifierCapture(), gp.Destroy()))
    gp.OnEvent("Close", (*) => (CancelPendingProfileModifierCapture(), gp.Destroy()))
    gp.Show()
}

BrowseForProcessNameInto(edProc) {
    file := FileSelect(, , "Select application", "Executables (*.exe)")
    if file = ""
        return
    SplitPath(file, &exeName)
    current := Trim(edProc.Value)
    edProc.Value := current = "" ? exeName : current ", " exeName
}

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

SaveProfileDialog(mode, oldName, newNameRaw, procCsv, pmKind, pmSc, pmRawPage, pmRawBytesHex, pmRawUpBytesHex, pmMode, gp) {
    global profiles, editingProfileName, activeProfileName, mappings, mapOrder, modifierActive
    CancelPendingProfileModifierCapture()
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
        profiles[newName] := {processNames: procList, modKind: pmKind, modSc: pmSc, modRawPage: pmRawPage, modRawBytesHex: pmRawBytesHex, modRawUpBytesHex: pmRawUpBytesHex, modMode: pmMode}
        editingProfileName := newName
        RefreshProfileList()
        RefreshList()
        ResetCaptureUI()
        if pmKind = "sc"
            RegisterHotkeyForButton(Format("SC{:03X}", pmSc))
        SaveMappings()
        txtStatus.Value := "Created profile '" newName "'."
    } else {
        if newName != oldName && profiles.Has(newName) {
            MsgBox("A profile named '" newName "' already exists.", "Name taken", "Icon!")
            return
        }
        priorModKind := profiles[oldName].HasOwnProp("modKind") ? profiles[oldName].modKind : "none"
        priorModSc := profiles[oldName].HasOwnProp("modSc") ? profiles[oldName].modSc : 0
        profiles[oldName].processNames := procList
        profiles[oldName].modKind := pmKind
        profiles[oldName].modSc := pmSc
        profiles[oldName].modRawPage := pmRawPage
        profiles[oldName].modRawBytesHex := pmRawBytesHex
        profiles[oldName].modRawUpBytesHex := pmRawUpBytesHex
        profiles[oldName].modMode := pmMode
        if newName != oldName {
            profiles[newName] := profiles[oldName]
            profiles.Delete(oldName)
            renamedIds := Map()
            for key in mapOrder {
                m := mappings[key]
                if (MapProfile(m)) != oldName
                    continue
                m.profile := newName
                suffix := SubStr(key, StrLen(oldName) + 3)
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
            ResetCaptureUI()
        }
        if (priorModKind = "sc" && priorModSc) || (pmKind = "sc" && pmSc) {
            modifierActive := false
            RefreshModifierLiveIndicator()
            if priorModKind = "sc" && priorModSc && priorModSc != pmSc
                RegisterHotkeyForButton(Format("SC{:03X}", priorModSc))
            if pmKind = "sc" && pmSc
                RegisterHotkeyForButton(Format("SC{:03X}", pmSc))
        }
        RefreshProfileList()
        RefreshList()
        UpdateActiveProfileStatus()
        SaveMappings()
        txtStatus.Value := "Updated profile '" newName "'."
    }
    gp.Destroy()
}

DeleteProfileFlow() {
    global editingProfileName, profiles, mappings, mapOrder, activeProfileName
    if editingProfileName = "Default" {
        MsgBox("The Default profile can't be deleted.", "Not allowed", "Icon!")
        return
    }
    target := editingProfileName
    count := 0
    for key in mapOrder {
        if (MapProfile(mappings[key])) = target
            count++
    }
    result := MsgBox(Format("Delete profile '{}'? This will permanently remove its {} mapping(s).", target, count), "Delete Profile", "YesNo Icon!")
    if result != "Yes"
        return
    removeSet := Map()
    for key in mapOrder {
        if (MapProfile(mappings[key])) = target
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
    deletedModKind := profiles[target].HasOwnProp("modKind") ? profiles[target].modKind : "none"
    deletedModSc := profiles[target].HasOwnProp("modSc") ? profiles[target].modSc : 0
    profiles.Delete(target)
    if activeProfileName = target
        SwitchActiveProfile("Default")
    else if deletedModKind = "sc" && deletedModSc
        RegisterHotkeyForButton(Format("SC{:03X}", deletedModSc))
    if editingProfileName = target
        editingProfileName := "Default"
    RefreshProfileList()
    RefreshList()
    ResetCaptureUI()
    SaveMappings()
    txtStatus.Value := "Deleted profile '" target "' and its mappings."
}

SetAppWatchEnabled(val) {
    global appWatchEnabled
    appWatchEnabled := !!val
    chkAppWatch.Value := appWatchEnabled
    if appWatchEnabled
        A_TrayMenu.Check("Enable App-Based Auto Profile Switching")
    else
        A_TrayMenu.Uncheck("Enable App-Based Auto Profile Switching")
    SaveMappings()
    CheckActiveProfile()
    txtStatus.Value := appWatchEnabled
        ? "App-based profile switching enabled - profiles will follow the foreground app."
        : "App-based profile switching disabled - Default profile is always active."
}

ToggleAppWatchFromTray(*) {
    SetAppWatchEnabled(!appWatchEnabled)
}

SetNotifyModifierToggle(val) {
    global notifyModifierToggle
    notifyModifierToggle := !!val
    chkNotifyModifierToggle.Value := notifyModifierToggle
    SaveMappings()
}

SetSendScrollLockOnModifierToggle(val) {
    global sendScrollLockOnModifierToggle
    sendScrollLockOnModifierToggle := !!val
    chkSendScrollLockOnModifierToggle.Value := sendScrollLockOnModifierToggle
    SaveMappings()
}

NotifyModifierToggled() {
    global notifyModifierToggle, sendScrollLockOnModifierToggle, modifierActive
    if sendScrollLockOnModifierToggle
        Send("{ScrollLock}")
    if !notifyModifierToggle
        return
    TrayTip("Modifier: " (modifierActive ? "ON" : "OFF"), "MF Button Mapper")
}

SetRunElevated(val) {
    global runElevated
    val := !!val
    if val && !A_IsAdmin {
        answer := MsgBox("Restart MF Button Mapper as Administrator now?`n`nThis fixes mappings getting stuck sending the button's factory function while Voice Access, Narrator, Magnifier, or the on-screen keyboard has focus.", "Restart elevated?", "YesNo Icon!")
        if answer != "Yes" {
            chkRunElevated.Value := false
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

StartupShortcutPath() {
    return A_Startup "\MF Button Mapper.lnk"
}

CreateStartupShortcut() {
    try {
        if A_IsCompiled
            FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir, "", "MF Button Mapper", A_ScriptFullPath)
        else
            FileCreateShortcut(A_AhkPath, StartupShortcutPath(), A_ScriptDir, '"' A_ScriptFullPath '"', "MF Button Mapper", A_ScriptFullPath)
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

PSQuote(str) {
    return StrReplace(str, "'", "''")
}

RunPowerShellScript(psContent, elevated := false) {
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

    psArgs := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' psFile '"'
    psCmd  := (elevated ? '*RunAs ' : '') '"powershell" ' psArgs
    try {
        exitCode := RunWait(psCmd, , "Hide")
    } catch as e {
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

SetStartupTask(enable) {
    global RunAtStartupTaskName
    if enable {
        execPath := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
        execArg  := A_IsCompiled ? "" : '"' A_ScriptFullPath '"'

        if execArg = ""
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "'`n"
        else
            psContent := "$action = New-ScheduledTaskAction -Execute '" PSQuote(execPath) "' -Argument '" PSQuote(execArg) "'`n"

        psContent .= "$trigger = New-ScheduledTaskTrigger -AtLogOn`n"
        psContent .= "$trigger.Delay = 'PT15S'`n"
        psContent .= "$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive`n"
        psContent .= "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)`n"
        psContent .= "Register-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null"

        result := RunPowerShellScript(psContent)
        if result.code != 0 && !A_IsAdmin {
            result := RunPowerShellScript(psContent, true)
        }
        return {ok: result.code = 0, error: result.error}
    } else {
        psContent := "Unregister-ScheduledTask -TaskName '" PSQuote(RunAtStartupTaskName) "' -Confirm:$false -ErrorAction SilentlyContinue"
        RunPowerShellScript(psContent)
        return {ok: true, error: ""}
    }
}

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
                chkRunStartup.Value := false
                return
            }
        } else {
            if !CreateStartupShortcut() {
                chkRunStartup.Value := false
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
                ddlRunStartupMode.Choose(1)
                return
            }
            RemoveStartupShortcut()
        } else {
            if !CreateStartupShortcut() {
                ddlRunStartupMode.Choose(2)
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
    if ddlActionType.Value = 5 {
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

JoinCsv(arr) {
    s := ""
    for i, v in arr {
        if i > 1
            s .= ","
        s .= v
    }
    return s
}

SaveKeymapColumnWidths() {
    global lvColW1, lvColW2, lvColW3, lvColW4
    lvColW1 := LV_GetColumnWidth(lv, 1)
    lvColW2 := LV_GetColumnWidth(lv, 2)
    lvColW3 := LV_GetColumnWidth(lv, 3)
    lvColW4 := LV_GetColumnWidth(lv, 4)
    IniWrite(lvColW1, SettingsFile(), "Settings", "LvColW1")
    IniWrite(lvColW2, SettingsFile(), "Settings", "LvColW2")
    IniWrite(lvColW3, SettingsFile(), "Settings", "LvColW3")
    IniWrite(lvColW4, SettingsFile(), "Settings", "LvColW4")
}

SaveMappings() {
    global profiles, appWatchEnabled, notifyModifierToggle, sendScrollLockOnModifierToggle, runElevated, runAtStartup
    global lvColW1, lvColW2, lvColW3, lvColW4
    global macroLvColW1, macroLvColW2, macroLvColW3, macroLvColW4
    global savedMacros, savedMacroOrder
    lvColW1 := LV_GetColumnWidth(lv, 1)
    lvColW2 := LV_GetColumnWidth(lv, 2)
    lvColW3 := LV_GetColumnWidth(lv, 3)
    lvColW4 := LV_GetColumnWidth(lv, 4)
    if IsObject(gMacro) {
        macroLvColW1 := LV_GetColumnWidth(lvMacroSteps, 1)
        macroLvColW2 := LV_GetColumnWidth(lvMacroSteps, 2)
        macroLvColW3 := LV_GetColumnWidth(lvMacroSteps, 3)
        macroLvColW4 := LV_GetColumnWidth(lvMacroSteps, 4)
    }
    EnsureDataDirs()
    try FileDelete(SettingsFile())
    try FileDelete(MacrosFile())
    try FileDelete(ProfilesDir() "\*.ini")

    sf := SettingsFile()
    IniWrite(masterEnabled ? "1" : "0", sf, "Settings", "MasterEnabled")
    IniWrite(startHidden ? "1" : "0", sf, "Settings", "StartHidden")
    IniWrite(longPressMs, sf, "Settings", "LongPressMs")
    IniWrite(MinHoldReleaseGapMs, sf, "Settings", "MinHoldReleaseGapMs")
    IniWrite(appWatchEnabled ? "1" : "0", sf, "Settings", "AppWatchEnabled")
    IniWrite(notifyModifierToggle ? "1" : "0", sf, "Settings", "NotifyModifierToggle")
    IniWrite(sendScrollLockOnModifierToggle ? "1" : "0", sf, "Settings", "SendScrollLockOnModifierToggle")
    IniWrite(runElevated ? "1" : "0", sf, "Settings", "RunElevated")
    IniWrite(runAtStartup ? "1" : "0", sf, "Settings", "RunAtStartup")
    IniWrite(runAtStartupMode, sf, "Settings", "RunAtStartupMode")
    IniWrite(modifierKind, sf, "Settings", "ModifierKind")
    IniWrite(Format("{:X}", modifierSc), sf, "Settings", "ModifierSc")
    IniWrite(Format("{:X}", modifierRawPage), sf, "Settings", "ModifierRawPage")
    IniWrite(modifierRawBytesHex, sf, "Settings", "ModifierRawBytesHex")
    IniWrite(modifierRawUpBytesHex, sf, "Settings", "ModifierRawUpBytesHex")
    IniWrite(modifierMode, sf, "Settings", "ModifierMode")
    IniWrite(lvColW1, sf, "Settings", "LvColW1")
    IniWrite(lvColW2, sf, "Settings", "LvColW2")
    IniWrite(lvColW3, sf, "Settings", "LvColW3")
    IniWrite(lvColW4, sf, "Settings", "LvColW4")
    IniWrite(macroLvColW1, sf, "Settings", "MacroLvColW1")
    IniWrite(macroLvColW2, sf, "Settings", "MacroLvColW2")
    IniWrite(macroLvColW3, sf, "Settings", "MacroLvColW3")
    IniWrite(macroLvColW4, sf, "Settings", "MacroLvColW4")

    seenProfiles := Map()
    allProfileNames := []
    for pname, pdata in profiles {
        if !seenProfiles.Has(pname) {
            seenProfiles[pname] := true
            allProfileNames.Push(pname)
        }
    }
    for key in mapOrder {
        mp := MapProfile(mappings[key])
        if !seenProfiles.Has(mp) {
            seenProfiles[mp] := true
            allProfileNames.Push(mp)
        }
    }
    IniWrite(JoinCsv(allProfileNames), sf, "Settings", "ProfileOrder")

    mf := MacrosFile()
    IniWrite(JoinCsv(savedMacroOrder), mf, "Macros", "Names")
    for name in savedMacroOrder
        IniWrite(MacroStepsEncode(savedMacros[name]), mf, "Macro::" name, "Steps")

    profileFiles := Map()
    usedBases := Map()
    for pname in allProfileNames {
        base := SanitizeProfileFileName(pname)
        cand := base
        suffix := 2
        while usedBases.Has(StrLower(cand)) {
            cand := base "_" suffix
            suffix += 1
        }
        usedBases[StrLower(cand)] := true
        profileFiles[pname] := ProfilesDir() "\" cand ".ini"
    }

    buckets := Map()
    for pname in allProfileNames
        buckets[pname] := []
    for key in mapOrder {
        mp := MapProfile(mappings[key])
        buckets[mp].Push(key)
    }

    for pname in allProfileNames {
        pf := profileFiles[pname]
        pdata := profiles.Has(pname) ? profiles[pname] : {processNames: []}
        IniWrite(pname, pf, "Profile", "Name")
        IniWrite(JoinCsv(pdata.HasOwnProp("processNames") ? pdata.processNames : []), pf, "Profile", "ProcessNames")
        IniWrite(pdata.HasOwnProp("modKind") ? pdata.modKind : "none", pf, "Profile", "ModKind")
        IniWrite(Format("{:X}", pdata.HasOwnProp("modSc") ? pdata.modSc : 0), pf, "Profile", "ModSc")
        IniWrite(Format("{:X}", pdata.HasOwnProp("modRawPage") ? pdata.modRawPage : 0), pf, "Profile", "ModRawPage")
        IniWrite(pdata.HasOwnProp("modRawBytesHex") ? pdata.modRawBytesHex : "", pf, "Profile", "ModRawBytesHex")
        IniWrite(pdata.HasOwnProp("modRawUpBytesHex") ? pdata.modRawUpBytesHex : "", pf, "Profile", "ModRawUpBytesHex")
        IniWrite(pdata.HasOwnProp("modMode") ? pdata.modMode : "hold", pf, "Profile", "ModMode")

        for key in buckets[pname] {
            m := mappings[key]
            kind := MapKind(m)
            actionType := MapActionType(m)
            dpos := InStr(key, "::")
            section := dpos ? SubStr(key, dpos + 2) : key
            IniWrite(kind, pf, section, "Kind")
            IniWrite(actionType, pf, section, "ActionType")
            IniWrite(m.desc, pf, section, "Desc")
            IniWrite(m.target, pf, section, "Target")
            IniWrite(m.HasOwnProp("appArgs") ? m.appArgs : "", pf, section, "AppArgs")
            IniWrite(m.enabled ? "1" : "0", pf, section, "Enabled")
            IniWrite(m.HasOwnProp("pressType") ? m.pressType : "short", pf, section, "PressType")
            IniWrite(MapList(m), pf, section, "List")
            IniWrite(m.HasOwnProp("runMode") ? m.runMode : "single", pf, section, "RunMode")
            IniWrite(m.HasOwnProp("repeatMs") ? m.repeatMs : 100, pf, section, "RepeatMs")
            if actionType = "macro" {
                IniWrite(m.HasOwnProp("macroName") ? m.macroName : "", pf, section, "MacroName")
                IniWrite(MacroStepsEncode(ResolveMacroSteps(m)), pf, section, "MacroSteps")
            }
            if kind = "raw" {
                IniWrite(m.page, pf, section, "Page")
                IniWrite(m.bytesHex, pf, section, "BytesHex")
                IniWrite(m.HasOwnProp("upBytesHex") ? m.upBytesHex : "", pf, section, "UpBytesHex")
            } else {
                IniWrite(Format("{:X}", m.sc), pf, section, "ScHex")
            }
        }
    }
}

ApplyLoadedStateToUI() {
    lv.ModifyCol(1, lvColW1)
    lv.ModifyCol(2, lvColW2)
    lv.ModifyCol(3, lvColW3)
    lv.ModifyCol(4, lvColW4)
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
    chkNotifyModifierToggle.Value := notifyModifierToggle
    chkSendScrollLockOnModifierToggle.Value := sendScrollLockOnModifierToggle
    chkRunStartup.Value := runAtStartup
    ddlRunStartupMode.Choose(runAtStartupMode = "admin" ? 2 : 1)
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
    UpdateMacroSelectDdl()
}

LoadMappings() {
    global masterEnabled, mappings, mapOrder, startHidden, longPressMs, MinHoldReleaseGapMs
    global profiles, appWatchEnabled, notifyModifierToggle, sendScrollLockOnModifierToggle, runElevated, runAtStartup, runAtStartupMode
    global modifierKind, modifierSc, modifierRawPage, modifierRawBytesHex, modifierRawUpBytesHex, modifierMode
    global lvColW1, lvColW2, lvColW3, lvColW4
    global macroLvColW1, macroLvColW2, macroLvColW3, macroLvColW4
    global savedMacros, savedMacroOrder
    try {
    EnsureDataDirs()

    if !FileExist(SettingsFile()) && FileExist(mapFile) {
        LoadLegacyMappings()
        SaveMappings()
        ApplyLoadedStateToUI()
        return
    }
    if !FileExist(SettingsFile())
        return

    sf := SettingsFile()
    masterEnabled := IniRead(sf, "Settings", "MasterEnabled", "1") = "1"
    startHidden := IniRead(sf, "Settings", "StartHidden", "0") = "1"
    longPressMsRaw := IniRead(sf, "Settings", "LongPressMs", "500")
    longPressMs := IsInteger(longPressMsRaw) ? Integer(longPressMsRaw) : 500
    minHoldGapRaw := IniRead(sf, "Settings", "MinHoldReleaseGapMs", "100")
    MinHoldReleaseGapMs := IsInteger(minHoldGapRaw) ? Integer(minHoldGapRaw) : 100
    appWatchEnabled := IniRead(sf, "Settings", "AppWatchEnabled", "0") = "1"
    notifyModifierToggle := IniRead(sf, "Settings", "NotifyModifierToggle", "0") = "1"
    sendScrollLockOnModifierToggle := IniRead(sf, "Settings", "SendScrollLockOnModifierToggle", "0") = "1"
    runElevated := IniRead(sf, "Settings", "RunElevated", "0") = "1"
    runAtStartup := IniRead(sf, "Settings", "RunAtStartup", "0") = "1"
    runAtStartupMode := IniRead(sf, "Settings", "RunAtStartupMode", "shortcut")
    modifierKind := IniRead(sf, "Settings", "ModifierKind", "none")
    modifierScRaw := IniRead(sf, "Settings", "ModifierSc", "0")
    modifierSc := IsXDigit(modifierScRaw) ? Integer("0x" modifierScRaw) : 0
    modifierRawPageRaw := IniRead(sf, "Settings", "ModifierRawPage", "0")
    modifierRawPage := IsXDigit(modifierRawPageRaw) ? Integer("0x" modifierRawPageRaw) : 0
    modifierRawBytesHex := IniRead(sf, "Settings", "ModifierRawBytesHex", "")
    modifierRawUpBytesHex := IniRead(sf, "Settings", "ModifierRawUpBytesHex", "")
    modifierMode := IniRead(sf, "Settings", "ModifierMode", "hold")
    lvColW1Raw := IniRead(sf, "Settings", "LvColW1", lvColW1)
    lvColW1 := IsInteger(lvColW1Raw) ? Integer(lvColW1Raw) : lvColW1
    lvColW2Raw := IniRead(sf, "Settings", "LvColW2", lvColW2)
    lvColW2 := IsInteger(lvColW2Raw) ? Integer(lvColW2Raw) : lvColW2
    lvColW3Raw := IniRead(sf, "Settings", "LvColW3", lvColW3)
    lvColW3 := IsInteger(lvColW3Raw) ? Integer(lvColW3Raw) : lvColW3
    lvColW4Raw := IniRead(sf, "Settings", "LvColW4", lvColW4)
    lvColW4 := IsInteger(lvColW4Raw) ? Integer(lvColW4Raw) : lvColW4
    macroLvColW1Raw := IniRead(sf, "Settings", "MacroLvColW1", macroLvColW1)
    macroLvColW1 := IsInteger(macroLvColW1Raw) ? Integer(macroLvColW1Raw) : macroLvColW1
    macroLvColW2Raw := IniRead(sf, "Settings", "MacroLvColW2", macroLvColW2)
    macroLvColW2 := IsInteger(macroLvColW2Raw) ? Integer(macroLvColW2Raw) : macroLvColW2
    macroLvColW3Raw := IniRead(sf, "Settings", "MacroLvColW3", macroLvColW3)
    macroLvColW3 := IsInteger(macroLvColW3Raw) ? Integer(macroLvColW3Raw) : macroLvColW3
    macroLvColW4Raw := IniRead(sf, "Settings", "MacroLvColW4", macroLvColW4)
    macroLvColW4 := IsInteger(macroLvColW4Raw) ? Integer(macroLvColW4Raw) : macroLvColW4

    savedMacros := Map()
    savedMacroOrder := []
    mf := MacrosFile()
    if FileExist(mf) {
        for mname in StrSplit(IniRead(mf, "Macros", "Names", ""), ",") {
            mname := Trim(mname)
            if mname = ""
                continue
            savedMacroOrder.Push(mname)
            savedMacros[mname] := MacroStepsDecode(IniRead(mf, "Macro::" mname, "Steps", ""))
        }
    }

    profiles := Map("Default", {processNames: []})

    fileByName := Map()
    foundOrder := []
    Loop Files, ProfilesDir() "\*.ini" {
        pname := Trim(IniRead(A_LoopFilePath, "Profile", "Name", ""))
        if pname = ""
            pname := RegExReplace(A_LoopFileName, "i)\.ini$", "")
        if pname = "" || InStr(pname, "::") || fileByName.Has(pname)
            continue
        fileByName[pname] := A_LoopFilePath
        foundOrder.Push(pname)
    }

    ordered := []
    taken := Map()
    for pname in StrSplit(IniRead(sf, "Settings", "ProfileOrder", ""), ",") {
        pname := Trim(pname)
        if pname = "" || taken.Has(pname) || !fileByName.Has(pname)
            continue
        taken[pname] := true
        ordered.Push(pname)
    }
    for pname in foundOrder {
        if taken.Has(pname)
            continue
        taken[pname] := true
        ordered.Push(pname)
    }

    for pname in ordered {
        pf := fileByName[pname]
        procList := []
        for p in StrSplit(IniRead(pf, "Profile", "ProcessNames", ""), ",") {
            p := Trim(p)
            if p != ""
                procList.Push(p)
        }
        modKind := IniRead(pf, "Profile", "ModKind", "none")
        modScRaw := IniRead(pf, "Profile", "ModSc", "0")
        modSc := IsXDigit(modScRaw) ? Integer("0x" modScRaw) : 0
        modRawPageRaw := IniRead(pf, "Profile", "ModRawPage", "0")
        modRawPage := IsXDigit(modRawPageRaw) ? Integer("0x" modRawPageRaw) : 0
        modRawBytesHex := IniRead(pf, "Profile", "ModRawBytesHex", "")
        modRawUpBytesHex := IniRead(pf, "Profile", "ModRawUpBytesHex", "")
        modMode := IniRead(pf, "Profile", "ModMode", "hold")
        profiles[pname] := {processNames: procList, modKind: modKind, modSc: modSc, modRawPage: modRawPage, modRawBytesHex: modRawBytesHex, modRawUpBytesHex: modRawUpBytesHex, modMode: modMode}

        for section in StrSplit(IniRead(pf), "`n", "`r") {
            if section = "" || section = "Profile"
                continue
            kind := IniRead(pf, section, "Kind", "sc")
            actionType := IniRead(pf, section, "ActionType", "key")
            desc := IniRead(pf, section, "Desc", section)
            target := IniRead(pf, section, "Target", "")
            appArgs := IniRead(pf, section, "AppArgs", "")
            enabled := IniRead(pf, section, "Enabled", "1") = "1"
            pressType := IniRead(pf, section, "PressType", "short")
            listVal := IniRead(pf, section, "List", "Main")
            runMode := IniRead(pf, section, "RunMode", "single")
            repeatMsRaw := IniRead(pf, section, "RepeatMs", "100")
            repeatMs := IsInteger(repeatMsRaw) ? Integer(repeatMsRaw) : 100
            macroSteps := actionType = "macro" ? MacroStepsDecode(IniRead(pf, section, "MacroSteps", "")) : []
            macroName := actionType = "macro" ? IniRead(pf, section, "MacroName", "") : ""
            if macroName = "" && actionType = "macro"
                macroName := FindSavedMacroNameForSteps(macroSteps)
            if target = "" && actionType != "macro"
                continue
            id := pname "::" section
            if kind = "raw" {
                pageRaw := IniRead(pf, section, "Page", "0")
                page := IsInteger(pageRaw) ? Integer(pageRaw) : 0
                bytesHex := IniRead(pf, section, "BytesHex", "")
                upBytesHex := IniRead(pf, section, "UpBytesHex", "")
                if upBytesHex = "" {
                    pressType := "short"
                    runMode := "single"
                }
                mappings[id] := {profile: pname, kind: "raw", actionType: actionType, page: page, bytesHex: bytesHex, upBytesHex: upBytesHex, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, macroName: macroName, enabled: enabled, pressType: pressType, runMode: runMode, repeatMs: repeatMs, list: listVal}
                mapOrder.Push(id)
            } else {
                scHexStr := IniRead(pf, section, "ScHex", "")
                if scHexStr = "" {
                    base := section
                    hashPos := InStr(base, "#")
                    if hashPos
                        base := SubStr(base, 1, hashPos - 1)
                    scHexStr := SubStr(base, 3)
                }
                sc := IsXDigit(scHexStr) ? Integer("0x" scHexStr) : 0
                mappings[id] := {profile: pname, kind: "sc", actionType: actionType, sc: sc, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, macroName: macroName, enabled: enabled, pressType: pressType, runMode: runMode, repeatMs: repeatMs, list: listVal}
                mapOrder.Push(id)
                RegisterHotkeyForButton(Format("SC{:03X}", sc))
            }
        }
    }

    ApplyLoadedStateToUI()
    } catch as e {
        MsgBox("Settings failed to load from '" SettingsFile() "' (" e.Message "). Using default settings instead.", "MF Button Mapper - Load Error", "Icon!")
    }
}

LoadLegacyMappings() {
    global masterEnabled, mappings, mapOrder, startHidden, longPressMs, MinHoldReleaseGapMs
    global profiles, appWatchEnabled, notifyModifierToggle, sendScrollLockOnModifierToggle, runElevated, runAtStartup, runAtStartupMode
    global modifierKind, modifierSc, modifierRawPage, modifierRawBytesHex, modifierRawUpBytesHex, modifierMode
    global lvColW1, lvColW2, lvColW3, lvColW4
    global macroLvColW1, macroLvColW2, macroLvColW3, macroLvColW4
    global savedMacros, savedMacroOrder
    try {
    if !FileExist(mapFile)
        return
    masterEnabled := IniRead(mapFile, "Settings", "MasterEnabled", "1") = "1"
    startHidden := IniRead(mapFile, "Settings", "StartHidden", "0") = "1"
    longPressMsRaw := IniRead(mapFile, "Settings", "LongPressMs", "500")
    longPressMs := IsInteger(longPressMsRaw) ? Integer(longPressMsRaw) : 500
    minHoldGapRaw := IniRead(mapFile, "Settings", "MinHoldReleaseGapMs", "100")
    MinHoldReleaseGapMs := IsInteger(minHoldGapRaw) ? Integer(minHoldGapRaw) : 100
    appWatchEnabled := IniRead(mapFile, "Settings", "AppWatchEnabled", "0") = "1"
    notifyModifierToggle := IniRead(mapFile, "Settings", "NotifyModifierToggle", "0") = "1"
    sendScrollLockOnModifierToggle := IniRead(mapFile, "Settings", "SendScrollLockOnModifierToggle", "0") = "1"
    runElevated := IniRead(mapFile, "Settings", "RunElevated", "0") = "1"
    runAtStartup := IniRead(mapFile, "Settings", "RunAtStartup", "0") = "1"
    runAtStartupMode := IniRead(mapFile, "Settings", "RunAtStartupMode", "shortcut")
    modifierKind := IniRead(mapFile, "Settings", "ModifierKind", "none")
    modifierScRaw := IniRead(mapFile, "Settings", "ModifierSc", "0")
    modifierSc := IsXDigit(modifierScRaw) ? Integer("0x" modifierScRaw) : 0
    modifierRawPageRaw := IniRead(mapFile, "Settings", "ModifierRawPage", "0")
    modifierRawPage := IsXDigit(modifierRawPageRaw) ? Integer("0x" modifierRawPageRaw) : 0
    modifierRawBytesHex := IniRead(mapFile, "Settings", "ModifierRawBytesHex", "")
    modifierRawUpBytesHex := IniRead(mapFile, "Settings", "ModifierRawUpBytesHex", "")
    modifierMode := IniRead(mapFile, "Settings", "ModifierMode", "hold")
    lvColW1Raw := IniRead(mapFile, "Settings", "LvColW1", lvColW1)
    lvColW1 := IsInteger(lvColW1Raw) ? Integer(lvColW1Raw) : lvColW1
    lvColW2Raw := IniRead(mapFile, "Settings", "LvColW2", lvColW2)
    lvColW2 := IsInteger(lvColW2Raw) ? Integer(lvColW2Raw) : lvColW2
    lvColW3Raw := IniRead(mapFile, "Settings", "LvColW3", lvColW3)
    lvColW3 := IsInteger(lvColW3Raw) ? Integer(lvColW3Raw) : lvColW3
    lvColW4Raw := IniRead(mapFile, "Settings", "LvColW4", lvColW4)
    lvColW4 := IsInteger(lvColW4Raw) ? Integer(lvColW4Raw) : lvColW4
    macroLvColW1Raw := IniRead(mapFile, "Settings", "MacroLvColW1", macroLvColW1)
    macroLvColW1 := IsInteger(macroLvColW1Raw) ? Integer(macroLvColW1Raw) : macroLvColW1
    macroLvColW2Raw := IniRead(mapFile, "Settings", "MacroLvColW2", macroLvColW2)
    macroLvColW2 := IsInteger(macroLvColW2Raw) ? Integer(macroLvColW2Raw) : macroLvColW2
    macroLvColW3Raw := IniRead(mapFile, "Settings", "MacroLvColW3", macroLvColW3)
    macroLvColW3 := IsInteger(macroLvColW3Raw) ? Integer(macroLvColW3Raw) : macroLvColW3
    macroLvColW4Raw := IniRead(mapFile, "Settings", "MacroLvColW4", macroLvColW4)
    macroLvColW4 := IsInteger(macroLvColW4Raw) ? Integer(macroLvColW4Raw) : macroLvColW4

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
        modKind := IniRead(mapFile, "Profile::" pname, "ModKind", "none")
        modScRaw := IniRead(mapFile, "Profile::" pname, "ModSc", "0")
        modSc := IsXDigit(modScRaw) ? Integer("0x" modScRaw) : 0
        modRawPageRaw := IniRead(mapFile, "Profile::" pname, "ModRawPage", "0")
        modRawPage := IsXDigit(modRawPageRaw) ? Integer("0x" modRawPageRaw) : 0
        modRawBytesHex := IniRead(mapFile, "Profile::" pname, "ModRawBytesHex", "")
        modMode := IniRead(mapFile, "Profile::" pname, "ModMode", "hold")
        modRawUpBytesHex := IniRead(mapFile, "Profile::" pname, "ModRawUpBytesHex", "")
        profiles[pname] := {processNames: procList, modKind: modKind, modSc: modSc, modRawPage: modRawPage, modRawBytesHex: modRawBytesHex, modRawUpBytesHex: modRawUpBytesHex, modMode: modMode}
    }

    savedMacros := Map()
    savedMacroOrder := []
    savedMacroNamesCsv := IniRead(mapFile, "Settings", "SavedMacroNames", "")
    for mname in StrSplit(savedMacroNamesCsv, ",") {
        mname := Trim(mname)
        if mname = ""
            continue
        savedMacroOrder.Push(mname)
        savedMacros[mname] := MacroStepsDecode(IniRead(mapFile, "SavedMacro::" mname, "Steps", ""))
    }

    sections := IniRead(mapFile)
    for section in StrSplit(sections, "`n", "`r") {
        if section = "" || section = "Settings" || SubStr(section, 1, 9) = "Profile::" || SubStr(section, 1, 12) = "SavedMacro::"
            continue
        kind := IniRead(mapFile, section, "Kind", "sc")
        actionType := IniRead(mapFile, section, "ActionType", "key")
        desc := IniRead(mapFile, section, "Desc", section)
        target := IniRead(mapFile, section, "Target", "")
        appArgs := IniRead(mapFile, section, "AppArgs", "")
        enabled := IniRead(mapFile, section, "Enabled", "1") = "1"
        pressType := IniRead(mapFile, section, "PressType", "short")
        listVal := IniRead(mapFile, section, "List", "Main")
        runMode := IniRead(mapFile, section, "RunMode", "single")
        repeatMsRaw := IniRead(mapFile, section, "RepeatMs", "100")
        repeatMs := IsInteger(repeatMsRaw) ? Integer(repeatMsRaw) : 100
        macroSteps := actionType = "macro" ? MacroStepsDecode(IniRead(mapFile, section, "MacroSteps", "")) : []
        macroName := (actionType = "macro") ? FindSavedMacroNameForSteps(macroSteps) : ""
        profileVal := IniRead(mapFile, section, "Profile", "")
        if target = "" && actionType != "macro"
            continue
        isLegacy := profileVal = ""
        mProfile := isLegacy ? "Default" : profileVal
        id := isLegacy ? ("Default::" section) : section
        if !profiles.Has(mProfile)
            profiles[mProfile] := {processNames: [], modKind: "none", modSc: 0, modRawPage: 0, modRawBytesHex: "", modRawUpBytesHex: "", modMode: "hold"}
        if kind = "raw" {
            pageRaw := IniRead(mapFile, section, "Page", "0")
            page := IsInteger(pageRaw) ? Integer(pageRaw) : 0
            bytesHex := IniRead(mapFile, section, "BytesHex", "")
            upBytesHex := IniRead(mapFile, section, "UpBytesHex", "")
            if upBytesHex = "" {
                pressType := "short"
                runMode := "single"
            }
            mappings[id] := {profile: mProfile, kind: "raw", actionType: actionType, page: page, bytesHex: bytesHex, upBytesHex: upBytesHex, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, macroName: macroName, enabled: enabled, pressType: pressType, runMode: runMode, repeatMs: repeatMs, list: listVal}
            mapOrder.Push(id)
        } else {
            scHexStr := IniRead(mapFile, section, "ScHex", "")
            if scHexStr = "" {
                base := section
                hashPos := InStr(base, "#")
                if hashPos
                    base := SubStr(base, 1, hashPos - 1)
                scHexStr := SubStr(base, 3)
            }
            sc := IsXDigit(scHexStr) ? Integer("0x" scHexStr) : 0
            mappings[id] := {profile: mProfile, kind: "sc", actionType: actionType, sc: sc, desc: desc, target: target, appArgs: appArgs, macroSteps: macroSteps, macroName: macroName, enabled: enabled, pressType: pressType, runMode: runMode, repeatMs: repeatMs, list: listVal}
            mapOrder.Push(id)
            RegisterHotkeyForButton(Format("SC{:03X}", sc))
        }
    }
    } catch as e {
        MsgBox("Legacy settings failed to load from '" mapFile "' (" e.Message "). Using default settings instead.", "MF Button Mapper - Load Error", "Icon!")
    }
}

chkMaster.Value := masterEnabled
chkStartHidden.Value := startHidden
chkAppWatch.Value := appWatchEnabled
chkRunElevated.Value := runElevated
chkNotifyModifierToggle.Value := notifyModifierToggle
chkSendScrollLockOnModifierToggle.Value := sendScrollLockOnModifierToggle
chkRunStartup.Value := runAtStartup
ddlRunStartupMode.Choose(runAtStartupMode = "admin" ? 2 : 1)
edLongPressMs.Value := longPressMs
LoadMappings()
RefreshModifierStatusText()
UpdateModifierModeUI()
RegisterModifierHotkey()
RefreshProfileList()
RegisterAllRawInputDevices()
RefreshList()
CheckActiveProfile()
UpdateActiveProfileStatus()
SetTimer(CheckActiveProfile, 500)
if !startHidden
    ShowGui()
