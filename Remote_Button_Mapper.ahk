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
; ============================================================

mapFile := A_ScriptDir "\remote_mappings.ini"

mappings := Map()      ; key "SCxxx" -> {sc, desc, target, enabled}
mapOrder := []         ; keeps display/registration order
masterEnabled := true
capturedSC := 0
startHidden := false
targetSendString := ""

; ---------------- Tray setup ----------------
A_TrayMenu.Delete()
A_TrayMenu.Add("Show Mapper", (*) => ShowGui())
A_TrayMenu.Add()
A_TrayMenu.Add("Remapping Enabled", ToggleMasterFromTray)
A_TrayMenu.Check("Remapping Enabled")
A_TrayMenu.Add("Start Hidden", ToggleStartHiddenFromTray)
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
g.OnEvent("Close", (*) => g.Hide())
g.SetFont("s10", "Segoe UI")

g.Add("GroupBox", "w560 h115", "Learn a button")
g.Add("Text", "x35 y30", "1. Click Capture, then press the remote button:")
btnCapture := g.Add("Button", "x+10 yp-4 w100", "Capture")
btnCapture.OnEvent("Click", StartCapture)
txtCaptureStatus := g.Add("Text", "x35 y+12 w520", "Not captured yet.")

g.Add("Text", "x35 y+15", "Description:")
editDesc := g.Add("Edit", "x+10 w150")
g.Add("Text", "x+15", "Sends:")
txtTarget := g.Add("Edit", "x+10 w110 ReadOnly")
btnCaptureTarget := g.Add("Button", "x+8 w110", "Capture Key")
btnCaptureTarget.OnEvent("Click", StartTargetCapture)

btnAdd := g.Add("Button", "x35 y+18 w160", "Add / Update Mapping")
btnAdd.OnEvent("Click", AddMapping)
btnTest := g.Add("Button", "x+10 w110", "Test Send")
btnTest.OnEvent("Click", TestSend)
btnClearForm := g.Add("Button", "x+10 w90", "Clear")
btnClearForm.OnEvent("Click", (*) => ResetCaptureUI())

lv := g.Add("ListView", "x35 y+18 w560 h220", ["On", "Remote Button", "Sends"])
lv.OnEvent("ItemSelect", LVSelect)
lv.ModifyCol(1, 40)
lv.ModifyCol(2, 270)
lv.ModifyCol(3, 230)

btnToggle := g.Add("Button", "x35 y+10 w130", "Enable/Disable")
btnToggle.OnEvent("Click", ToggleSelected)
btnRemove := g.Add("Button", "x+10 w110", "Remove")
btnRemove.OnEvent("Click", RemoveSelected)
chkMaster := g.Add("Checkbox", "x+30 yp+4", "Remapping enabled")
chkMaster.OnEvent("Click", (*) => SetMasterEnabled(chkMaster.Value))

btnHide := g.Add("Button", "x+30 yp-4 w80", "Hide")
btnHide.OnEvent("Click", (*) => g.Hide())

chkStartHidden := g.Add("Checkbox", "x35 y+15", "Start hidden in systray (don't show this window on launch)")
chkStartHidden.OnEvent("Click", (*) => SetStartHidden(chkStartHidden.Value))

txtStatus := g.Add("Text", "x35 y+15 w560", "Ready.")

ShowGui() {
    g.Show()
}

; ---------------- Capture logic (source button) ----------------
OnCaptureKey(ihObj, VK, SC) {
    global capturedSC
    ihObj.Stop()
    capturedSC := SC
    scName := Format("SC{:03X}", SC)
    vkHex := Format("0x{:X}", VK)
    txtCaptureStatus.Value := "Captured " scName " (VK:" vkHex ")"
}

StartCapture(*) {
    txtCaptureStatus.Value := "Waiting for button press..."
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnCaptureKey
    ih.OnKeyUp := (*) => {}
    ih.Start()
}

; ---------------- Capture logic (target key/combo) ----------------
; Accepts ANY key, including ones the built-in Hotkey control refuses
; (Space, Enter, Tab, Win alone, etc.) by reading live modifier state
; instead of relying on the Gui Hotkey control.
IsModifierVK(vk) {
    return vk = 0x10 || vk = 0x11 || vk = 0x12 || vk = 0x5B || vk = 0x5C
        || (vk >= 0xA0 && vk <= 0xA5)
}

FormatSendKey(keyName) {
    if StrLen(keyName) = 1 {
        if InStr("^!+#{}", keyName)
            return "{" keyName "}"
        return keyName
    }
    return "{" keyName "}"
}

FinalizeTarget(modStr, keyName) {
    global targetSendString
    targetSendString := modStr FormatSendKey(keyName)
    txtTarget.Value := targetSendString
    txtCaptureStatus.Value := "Captured target key: " targetSendString
}

OnTargetKeyDown(ihObj, VK, SC) {
    if IsModifierVK(VK)
        return   ; keep waiting - this might just be a modifier being held
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
    FinalizeTarget(modStr, keyName)
}

OnTargetKeyUp(ihObj, VK, SC) {
    ; Lets a bare modifier (e.g. Win key alone) be used as the whole target:
    ; if the released key is a modifier and no other modifier is still down,
    ; treat it as the finished capture.
    if !IsModifierVK(VK)
        return
    if GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P") || GetKeyState("Shift", "P")
        || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        return
    ihObj.Stop()
    keyName := GetKeyName(Format("vk{:X}sc{:X}", VK, SC))
    FinalizeTarget("", keyName)
}

StartTargetCapture(*) {
    txtTarget.Value := ""
    txtTarget.Focus()
    txtCaptureStatus.Value := "Waiting for target key/combo... (press it now, e.g. Space, Win, Ctrl+Alt+S)"
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnTargetKeyDown
    ih.OnKeyUp := OnTargetKeyUp
    ih.Start()
}

; ---------------- Mapping management ----------------
AddMapping(*) {
    if !capturedSC {
        MsgBox("Capture a button first.", "Missing input", "Icon!")
        return
    }
    target := targetSendString
    if target = "" {
        MsgBox("Capture a key/combo to send first.", "Missing target", "Icon!")
        return
    }
    key := Format("SC{:03X}", capturedSC)
    desc := editDesc.Value != "" ? editDesc.Value : key

    if !mappings.Has(key)
        mapOrder.Push(key)

    mappings[key] := {sc: capturedSC, desc: desc, target: target, enabled: true}
    RegisterHotkey(key)
    SaveMappings()
    RefreshList()
    ResetCaptureUI()
    txtStatus.Value := "Saved mapping for " key "."
}

RegisterHotkey(key) {
    m := mappings[key]
    state := (masterEnabled && m.enabled) ? "On" : "Off"
    try {
        Hotkey(key, (*) => SendTarget(key), state)
    } catch as e {
        MsgBox("Could not register hotkey for " key ":`n" e.Message, "Error", "Icon!")
    }
}

SendTarget(key) {
    if mappings.Has(key)
        Send(mappings[key].target)
}

ResetCaptureUI() {
    global capturedSC, targetSendString
    capturedSC := 0
    targetSendString := ""
    editDesc.Value := ""
    txtTarget.Value := ""
    txtCaptureStatus.Value := "Not captured yet."
}

; ---------------- ListView handling ----------------
RefreshList() {
    lv.Delete()
    for key in mapOrder {
        m := mappings[key]
        lv.Add(, m.enabled ? "Yes" : "No", m.desc, m.target)
    }
}

LVSelect(lvObj, rowNum, selected) {
    global capturedSC, targetSendString
    if !selected
        return
    if rowNum < 1 || rowNum > mapOrder.Length
        return
    key := mapOrder[rowNum]
    m := mappings[key]
    capturedSC := m.sc
    editDesc.Value := m.desc
    targetSendString := m.target
    txtTarget.Value := m.target
    txtCaptureStatus.Value := "Editing " key " (press Add/Update to save changes)"
}

GetSelectedKey() {
    row := lv.GetNext()
    if !row || row > mapOrder.Length
        return ""
    return mapOrder[row]
}

ToggleSelected(*) {
    key := GetSelectedKey()
    if key = "" {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    mappings[key].enabled := !mappings[key].enabled
    RegisterHotkey(key)
    SaveMappings()
    RefreshList()
}

RemoveSelected(*) {
    key := GetSelectedKey()
    if key = "" {
        MsgBox("Select a mapping first.", "Nothing selected", "Icon!")
        return
    }
    try Hotkey(key, "Off")
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
    SaveMappings()
    RefreshList()
    ResetCaptureUI()
}

; ---------------- Master enable/disable ----------------
SetMasterEnabled(val) {
    global masterEnabled
    masterEnabled := !!val
    chkMaster.Value := masterEnabled
    if masterEnabled
        A_TrayMenu.Check("Remapping Enabled")
    else
        A_TrayMenu.Uncheck("Remapping Enabled")
    for key in mapOrder
        RegisterHotkey(key)
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

; ---------------- Test ----------------
TestSend(*) {
    t := targetSendString
    if t = "" {
        MsgBox("Capture a target key/combo first.", "Nothing to send", "Icon!")
        return
    }
    ToolTip("Switch to a text field now`nSending in 2 seconds...")
    SetTimer(() => (ToolTip(), Send(t)), -2000)
}

; ---------------- Persistence ----------------
SaveMappings() {
    try FileDelete(mapFile)
    IniWrite(masterEnabled ? "1" : "0", mapFile, "Settings", "MasterEnabled")
    IniWrite(startHidden ? "1" : "0", mapFile, "Settings", "StartHidden")
    for key in mapOrder {
        m := mappings[key]
        IniWrite(m.desc, mapFile, key, "Desc")
        IniWrite(m.target, mapFile, key, "Target")
        IniWrite(m.enabled ? "1" : "0", mapFile, key, "Enabled")
    }
}

LoadMappings() {
    global masterEnabled, mappings, mapOrder, startHidden
    if !FileExist(mapFile)
        return
    masterEnabled := IniRead(mapFile, "Settings", "MasterEnabled", "1") = "1"
    startHidden := IniRead(mapFile, "Settings", "StartHidden", "0") = "1"
    sections := IniRead(mapFile)
    for section in StrSplit(sections, "`n", "`r") {
        if section = "" || section = "Settings"
            continue
        scHexStr := SubStr(section, 3)
        sc := Integer("0x" scHexStr)
        desc := IniRead(mapFile, section, "Desc", section)
        target := IniRead(mapFile, section, "Target", "")
        enabled := IniRead(mapFile, section, "Enabled", "1") = "1"
        if target = ""
            continue
        mappings[section] := {sc: sc, desc: desc, target: target, enabled: enabled}
        mapOrder.Push(section)
        RegisterHotkey(section)
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
}

; ---------------- Startup ----------------
chkMaster.Value := masterEnabled
chkStartHidden.Value := startHidden
LoadMappings()
RefreshList()
if !startHidden
    ShowGui()
