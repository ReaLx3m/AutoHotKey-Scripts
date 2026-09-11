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

; Passthrough-when-Kodi-isn't-running feature: this is the master switch for
; the feature. When on, any INDIVIDUAL mapping that was flagged (via the
; "Passthrough THIS button when Kodi isn't running" checkbox at creation/edit
; time) stops firing while Kodi isn't running, letting that button's
; factory/OS-default behavior through untouched. Mappings NOT flagged keep
; remapping regardless of Kodi's running state. If every enabled mapping on
; a scancode button is flagged, the OS hotkey for that button is fully
; unregistered while Kodi is down (true passthrough); if the button has a
; mix of flagged and unflagged mappings, the hotkey stays registered (so the
; unflagged mapping can still fire) and only the flagged mapping(s) are
; skipped for that press.
kodiPassthroughEnabled := false
kodiProcessName := "kodi.exe"
kodiWasRunning := true

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
A_TrayMenu.Add("Passthrough Buttons When Kodi Isn't Running", ToggleKodiPassthroughFromTray)
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

g.Add("GroupBox", "x8 y10 w572 h286", "Learn a button")
g.Add("Text", "x20 y30", "1. Click Capture, then press the remote button:")
btnCapture := g.Add("Button", "x+10 yp-4 w100", "Capture")
btnCapture.OnEvent("Click", StartCapture)
chkCaptureRaw := g.Add("Checkbox", "x20 y+6", "Capture raw HID event (use if the button isn't detected above)")
chkCaptureRaw.OnEvent("Click", (*) => SetCaptureRawMode(chkCaptureRaw.Value))
txtCaptureStatus := g.Add("Text", "x20 y+8 w520", "Not captured yet.")

g.Add("Text", "x20 y+15", "Description:")
editDesc := g.Add("Edit", "x+10 w150")
g.Add("Text", "x+15", "Action:")
ddlActionType := g.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App"])
ddlActionType.OnEvent("Change", (*) => OnActionTypeChange())

lblSends := g.Add("Text", "x20 y+15", "Sends:")
txtTarget := g.Add("Edit", "x+10 w150 ReadOnly")
btnCaptureTarget := g.Add("Button", "x+8 w110", "Capture Key")
btnCaptureTarget.OnEvent("Click", StartTargetCapture)

lblAppPath := g.Add("Text", "x20 y+12", "App/File path:")
editAppPath := g.Add("Edit", "x+10 w280")
btnBrowseApp := g.Add("Button", "x+8 w80", "Browse...")
btnBrowseApp.OnEvent("Click", (*) => BrowseForAppInto(editAppPath))

lblAppArgs := g.Add("Text", "x20 y+10", "Arguments (optional):")
editAppArgs := g.Add("Edit", "x+10 w330")

chkMappingKodiPassthrough := g.Add("Checkbox", "x20 y+10", "Passthrough THIS button when Kodi isn't running")

btnAddNew := g.Add("Button", "x20 y+18 w110", "Add Mapping")
btnAddNew.OnEvent("Click", (*) => SaveMapping(true))
btnUpdate := g.Add("Button", "x+8 w110", "Update Mapping")
btnUpdate.OnEvent("Click", (*) => SaveMapping(false))
btnTest := g.Add("Button", "x+8 w90", "Test Send")
btnTest.OnEvent("Click", TestSend)
btnClearForm := g.Add("Button", "x+8 w70", "Clear")
btnClearForm.OnEvent("Click", (*) => ResetCaptureUI())

lv := g.Add("ListView", "x20 y+18 w560 h220", ["On", "Remote Button", "Sends", "KP"])
lv.OnEvent("ItemSelect", LVSelect)
lv.ModifyCol(1, 35)
lv.ModifyCol(2, 205)
lv.ModifyCol(3, 250)
lv.ModifyCol(4, 40)

btnToggle := g.Add("Button", "x20 y+10 w130", "Enable/Disable")
btnToggle.OnEvent("Click", ToggleSelected)
btnRemove := g.Add("Button", "x+10 w110", "Remove")
btnRemove.OnEvent("Click", RemoveSelected)
btnHide := g.Add("Button", "x+10 w80", "Hide")
btnHide.OnEvent("Click", (*) => g.Hide())
btnRawSniffer := g.Add("Button", "x+10 w130", "Raw HID Sniffer...")
btnRawSniffer.OnEvent("Click", OpenRawSniffer)

chkStartHidden := g.Add("Checkbox", "x20 y+15", "Start hidden in systray (don't show this window on launch)")
chkStartHidden.OnEvent("Click", (*) => SetStartHidden(chkStartHidden.Value))
chkMaster := g.Add("Checkbox", "x20 y+8", "Remapping enabled")
chkMaster.OnEvent("Click", (*) => SetMasterEnabled(chkMaster.Value))
chkKodiPassthrough := g.Add("Checkbox", "x20 y+8", "Passthrough buttons when Kodi isn't running")
chkKodiPassthrough.OnEvent("Click", (*) => SetKodiPassthroughEnabled(chkKodiPassthrough.Value))

txtStatus := g.Add("Text", "x20 y+15 w560", "Ready.")

OnActionTypeChange(*) {
    isApp := ddlActionType.Value = 2
    lblSends.Visible := !isApp
    txtTarget.Visible := !isApp
    btnCaptureTarget.Visible := !isApp
    lblAppPath.Visible := isApp
    editAppPath.Visible := isApp
    btnBrowseApp.Visible := isApp
    lblAppArgs.Visible := isApp
    editAppArgs.Visible := isApp
}
OnActionTypeChange()

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
}

StartCapture(*) {
    global captureRawMode, rawCaptureArmed
    if captureRawMode {
        rawCaptureArmed := false   ; make sure it's off while we wait out the click
        txtCaptureStatus.Value := "Get ready... (waiting for your click to finish)"
        SetTimer(ArmRawCapture, -600)   ; one-shot, 600ms delay - avoids capturing
        return                          ; the mouse click on this button itself
    }
    txtCaptureStatus.Value := "Waiting for button press..."
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnCaptureKey
    ih.OnKeyUp := (*) => {}
    ih.Start()
}

ArmRawCapture() {
    global rawCaptureArmed
    rawCaptureArmed := true
    txtCaptureStatus.Value := "Waiting for button press (raw HID)..."
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
    global kodiPassthroughEnabled
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
            kodiBlocks := kodiPassthroughEnabled && !IsKodiRunning()
            for key in mapOrder {
                m := mappings[key]
                if (m.HasOwnProp("kind") ? m.kind : "sc") != "raw"
                    continue
                if m.page = info.usagePage && m.bytesHex = bytesNorm {
                    mappingBlocked := kodiBlocks && (m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false)
                    if masterEnabled && m.enabled && !mappingBlocked
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
    global rawMapTargetString
    rawMapTargetString := ""
    gm := Gui("+AlwaysOnTop +Owner" gRaw.Hwnd, "Map Raw HID Event")
    gm.SetFont("s10", "Segoe UI")
    gm.Add("Text", "w420", Format("Event: Page:0x{:X} Bytes:{}", page, bytesHex))
    gm.Add("Text", "xm y+15", "Description:")
    edDesc := gm.Add("Edit", "x+10 w180")
    gm.Add("Text", "x+15", "Action:")
    ddlRawAction := gm.Add("DropDownList", "x+10 w150 Choose1", ["Send Key/Combo", "Launch App"])

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

    chkRawKodi := gm.Add("Checkbox", "xm y+10", "Passthrough THIS button when Kodi isn't running")

    ToggleRawActionControls(*) {
        isApp := ddlRawAction.Value = 2
        lblRawSends.Visible := !isApp
        edTarget.Visible := !isApp
        btnCap.Visible := !isApp
        lblRawAppPath.Visible := isApp
        edRawAppPath.Visible := isApp
        btnRawBrowse.Visible := isApp
        lblRawAppArgs.Visible := isApp
        edRawAppArgs.Visible := isApp
    }
    ddlRawAction.OnEvent("Change", ToggleRawActionControls)
    ToggleRawActionControls()

    btnSave := gm.Add("Button", "xm y+20 w100", "Save")
    btnSave.OnEvent("Click", (*) => SaveRawMapping(page, bytesHex, edDesc.Value, ddlRawAction.Value = 2, edRawAppPath.Value, edRawAppArgs.Value, !!chkRawKodi.Value, gm))
    btnCancel := gm.Add("Button", "x+10 w100", "Cancel")
    btnCancel.OnEvent("Click", (*) => gm.Destroy())
    gm.OnEvent("Close", (*) => gm.Destroy())
    gm.Show()
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

SaveRawMapping(page, bytesHex, desc, isApp, appPath, appArgs, kodiPassthrough, gm) {
    global mappings, mapOrder, rawMapTargetString
    if isApp {
        if appPath = "" {
            MsgBox("Enter an app/file path first (or use Browse...).", "Missing target", "Icon!")
            return
        }
    } else {
        if rawMapTargetString = "" {
            MsgBox("Capture a key/combo to send first.", "Missing target", "Icon!")
            return
        }
    }
    buttonKey := "RAW_" Format("{:X}", page) "_" bytesHex
    key := GenerateId(buttonKey)   ; adds a new mapping rather than overwriting one already on this event
    mapOrder.Push(key)
    finalDesc := desc != "" ? desc : Format("Raw 0x{:X} {} ({})", page, bytesHex, key)
    if isApp
        mappings[key] := {kind: "raw", actionType: "app", page: page, bytesHex: bytesHex, desc: finalDesc, target: appPath, appArgs: appArgs, enabled: true, kodiPassthrough: kodiPassthrough}
    else
        mappings[key] := {kind: "raw", actionType: "key", page: page, bytesHex: bytesHex, desc: finalDesc, target: rawMapTargetString, appArgs: "", enabled: true, kodiPassthrough: kodiPassthrough}
    SaveMappings()
    RefreshList()
    gm.Destroy()
    txtStatus.Value := "Saved raw mapping for " key "."
}

; ---------------- Mapping management ----------------
; A single physical button (scancode, or raw HID event) can now have MULTIPLE
; mappings attached to it - each stored under its own id in `mappings`/`mapOrder`.
; The first mapping for a button keeps the plain button id (e.g. "SC01E" or
; "RAW_6_02"); additional ones get a "#2", "#3", ... suffix. All enabled
; mappings sharing a button fire together when that button is pressed.

; Finds an unused mapping id for a given button, so a new mapping never
; clobbers an existing one on the same button.
GenerateId(buttonKey) {
    if !mappings.Has(buttonKey)
        return buttonKey
    n := 2
    loop {
        cand := buttonKey "#" n
        if !mappings.Has(cand)
            return cand
        n++
    }
}

; isNew=true  -> always creates a brand-new mapping (Add Mapping button)
; isNew=false -> overwrites the mapping currently selected in the list (Update Mapping button)
SaveMapping(isNew) {
    global lastCaptureKind, capturedSC, capturedRawPage, capturedRawBytesHex, editingId
    isApp := ddlActionType.Value = 2
    if isApp {
        target := editAppPath.Value
        if target = "" {
            MsgBox("Enter an app/file path first (or use Browse...).", "Missing target", "Icon!")
            return
        }
        appArgs := editAppArgs.Value
    } else {
        target := targetSendString
        if target = "" {
            MsgBox("Capture a key/combo to send first.", "Missing target", "Icon!")
            return
        }
        appArgs := ""
    }
    actionType := isApp ? "app" : "key"

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
        id := isNew ? GenerateId(buttonKey) : editingId
        prevEnabled := mappings.Has(id) ? mappings[id].enabled : true
        desc := editDesc.Value != "" ? editDesc.Value : Format("Raw 0x{:X} {} ({})", capturedRawPage, capturedRawBytesHex, id)
        if !mappings.Has(id)
            mapOrder.Push(id)
        mappings[id] := {kind: "raw", actionType: actionType, page: capturedRawPage, bytesHex: capturedRawBytesHex, desc: desc, target: target, appArgs: appArgs, enabled: prevEnabled, kodiPassthrough: !!chkMappingKodiPassthrough.Value}
    } else {
        if !capturedSC {
            MsgBox("Capture a button first.", "Missing input", "Icon!")
            return
        }
        buttonKey := Format("SC{:03X}", capturedSC)
        id := isNew ? GenerateId(buttonKey) : editingId

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
        desc := editDesc.Value != "" ? editDesc.Value : id
        if !mappings.Has(id)
            mapOrder.Push(id)
        mappings[id] := {kind: "sc", actionType: actionType, sc: capturedSC, desc: desc, target: target, appArgs: appArgs, enabled: prevEnabled, kodiPassthrough: !!chkMappingKodiPassthrough.Value}
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
    global kodiPassthroughEnabled
    ; When the Kodi-passthrough feature is on and Kodi isn't currently
    ; running, mappings that were individually flagged for passthrough are
    ; skipped. The hotkey itself can only be fully unregistered (true
    ; factory passthrough) when EVERY enabled mapping on this button would
    ; currently be skipped - if even one unflagged mapping is still meant
    ; to fire, the hotkey has to stay registered so that one can fire, and
    ; the flagged mapping(s) are simply not sent for this press instead.
    kodiBlocks := kodiPassthroughEnabled && !IsKodiRunning()
    hasFiring := false
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        mappingBlocked := kodiBlocks && (m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false)
        if !mappingBlocked {
            hasFiring := true
            break
        }
    }
    state := (masterEnabled && hasFiring) ? "On" : "Off"
    try {
        Hotkey(buttonKey, (*) => SendTarget(buttonKey), state)
    } catch as e {
        MsgBox("Could not register hotkey for " buttonKey ":`n" e.Message, "Error", "Icon!")
    }
}

; Fires every enabled scancode mapping attached to this button, except ones
; individually flagged for Kodi passthrough while Kodi isn't running (those
; are left unsent for this press rather than remapped).
SendTarget(buttonKey) {
    global kodiPassthroughEnabled
    kodiBlocks := kodiPassthroughEnabled && !IsKodiRunning()
    for id in mapOrder {
        m := mappings[id]
        if (m.HasOwnProp("kind") ? m.kind : "sc") != "sc"
            continue
        if Format("SC{:03X}", m.sc) != buttonKey || !m.enabled
            continue
        mappingBlocked := kodiBlocks && (m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false)
        if !mappingBlocked
            FireMapping(m)
    }
}

; Fires a mapping's configured action: sends a key/combo, or launches an app.
FireMapping(m) {
    actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
    if actionType = "app"
        LaunchApp(m.target, m.HasOwnProp("appArgs") ? m.appArgs : "")
    else
        Send(m.target)
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
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, lastCaptureKind, rawCaptureArmed, editingId
    capturedSC := 0
    capturedRawPage := 0
    capturedRawBytesHex := ""
    lastCaptureKind := "sc"
    rawCaptureArmed := false
    editingId := ""
    targetSendString := ""
    editDesc.Value := ""
    txtTarget.Value := ""
    editAppPath.Value := ""
    editAppArgs.Value := ""
    ddlActionType.Choose(1)
    OnActionTypeChange()
    chkMappingKodiPassthrough.Value := false
    txtCaptureStatus.Value := "Not captured yet."
}

; ---------------- ListView handling ----------------
RefreshList() {
    lv.Delete()
    for key in mapOrder {
        m := mappings[key]
        actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
        if actionType = "app" {
            args := m.HasOwnProp("appArgs") ? m.appArgs : ""
            sendsDisplay := "Launch: " m.target (args != "" ? " " args : "")
        } else {
            sendsDisplay := m.target
        }
        kp := (m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false) ? "Yes" : "No"
        lv.Add(, m.enabled ? "Yes" : "No", m.desc, sendsDisplay, kp)
    }
}

LVSelect(lvObj, rowNum, selected) {
    global capturedSC, targetSendString, capturedRawPage, capturedRawBytesHex, lastCaptureKind, editingId
    if !selected
        return
    if rowNum < 1 || rowNum > mapOrder.Length
        return
    key := mapOrder[rowNum]
    m := mappings[key]
    editingId := key
    ApplyActionFieldsFromMapping(m)
    chkMappingKodiPassthrough.Value := m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false
    if (m.HasOwnProp("kind") ? m.kind : "sc") = "raw" {
        capturedSC := 0
        capturedRawPage := m.page
        capturedRawBytesHex := m.bytesHex
        lastCaptureKind := "raw"
        editDesc.Value := m.desc
        txtCaptureStatus.Value := Format("Editing raw mapping (Page:0x{:X} Bytes:{}) - press Update Mapping to save changes, or Add Mapping for a new one on this same button", m.page, m.bytesHex)
        return
    }
    lastCaptureKind := "sc"
    capturedSC := m.sc
    editDesc.Value := m.desc
    txtCaptureStatus.Value := "Editing " key " (press Update Mapping to save changes, or Add Mapping for a new one on this same button)"
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
    } else {
        ddlActionType.Choose(1)
        targetSendString := m.target
        txtTarget.Value := m.target
        editAppPath.Value := ""
        editAppArgs.Value := ""
    }
    OnActionTypeChange()
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
    m := mappings[key]
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
; has at least one mapping attached, reflecting current master/enabled/Kodi
; passthrough state. Raw-report mappings don't need this - they're matched
; directly in OnRawInput and were never gated by an OS hotkey.
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

SetMasterEnabled(val) {
    global masterEnabled
    masterEnabled := !!val
    chkMaster.Value := masterEnabled
    if masterEnabled
        A_TrayMenu.Check("Remapping Enabled")
    else
        A_TrayMenu.Uncheck("Remapping Enabled")
    RefreshAllScHotkeyStates()
    SaveMappings()
    txtStatus.Value := masterEnabled ? "Remapping enabled." : "Remapping paused."
}

ToggleMasterFromTray(*) {
    SetMasterEnabled(!masterEnabled)
}

; ---------------- Kodi passthrough setting ----------------
SetKodiPassthroughEnabled(val) {
    global kodiPassthroughEnabled
    kodiPassthroughEnabled := !!val
    chkKodiPassthrough.Value := kodiPassthroughEnabled
    if kodiPassthroughEnabled
        A_TrayMenu.Check("Passthrough Buttons When Kodi Isn't Running")
    else
        A_TrayMenu.Uncheck("Passthrough Buttons When Kodi Isn't Running")
    RefreshAllScHotkeyStates()
    SaveMappings()
    txtStatus.Value := kodiPassthroughEnabled
        ? "Flagged mappings will passthrough (factory behavior) whenever Kodi isn't running."
        : "All mappings remap regardless of whether Kodi is running."
}

ToggleKodiPassthroughFromTray(*) {
    SetKodiPassthroughEnabled(!kodiPassthroughEnabled)
}

; Returns true if the Kodi process is currently running.
IsKodiRunning() {
    global kodiProcessName
    return ProcessExist(kodiProcessName) ? true : false
}

; Polled periodically (see SetTimer below). Only touches the hotkeys when the
; running-state actually changed, so this is cheap the vast majority of ticks.
CheckKodiRunningState() {
    global kodiPassthroughEnabled, kodiWasRunning
    if !kodiPassthroughEnabled
        return
    running := IsKodiRunning()
    if running = kodiWasRunning
        return
    kodiWasRunning := running
    RefreshAllScHotkeyStates()
    txtStatus.Value := running
        ? "Kodi detected running - flagged mappings resumed."
        : "Kodi not running - flagged mappings passed through with factory behavior."
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
    IniWrite(kodiPassthroughEnabled ? "1" : "0", mapFile, "Settings", "KodiPassthroughEnabled")
    for key in mapOrder {
        m := mappings[key]
        kind := m.HasOwnProp("kind") ? m.kind : "sc"
        actionType := m.HasOwnProp("actionType") ? m.actionType : "key"
        IniWrite(kind, mapFile, key, "Kind")
        IniWrite(actionType, mapFile, key, "ActionType")
        IniWrite(m.desc, mapFile, key, "Desc")
        IniWrite(m.target, mapFile, key, "Target")
        IniWrite(m.HasOwnProp("appArgs") ? m.appArgs : "", mapFile, key, "AppArgs")
        IniWrite(m.enabled ? "1" : "0", mapFile, key, "Enabled")
        IniWrite((m.HasOwnProp("kodiPassthrough") ? m.kodiPassthrough : false) ? "1" : "0", mapFile, key, "KodiPassthrough")
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
    global masterEnabled, mappings, mapOrder, startHidden, kodiPassthroughEnabled
    if !FileExist(mapFile)
        return
    masterEnabled := IniRead(mapFile, "Settings", "MasterEnabled", "1") = "1"
    kodiPassthroughEnabled := IniRead(mapFile, "Settings", "KodiPassthroughEnabled", "0") = "1"
    startHidden := IniRead(mapFile, "Settings", "StartHidden", "0") = "1"
    sections := IniRead(mapFile)
    for section in StrSplit(sections, "`n", "`r") {
        if section = "" || section = "Settings"
            continue
        kind := IniRead(mapFile, section, "Kind", "sc")
        actionType := IniRead(mapFile, section, "ActionType", "key")
        desc := IniRead(mapFile, section, "Desc", section)
        target := IniRead(mapFile, section, "Target", "")
        appArgs := IniRead(mapFile, section, "AppArgs", "")
        enabled := IniRead(mapFile, section, "Enabled", "1") = "1"
        kodiPassthrough := IniRead(mapFile, section, "KodiPassthrough", "0") = "1"
        if target = ""
            continue
        if kind = "raw" {
            page := Integer(IniRead(mapFile, section, "Page", "0"))
            bytesHex := IniRead(mapFile, section, "BytesHex", "")
            mappings[section] := {kind: "raw", actionType: actionType, page: page, bytesHex: bytesHex, desc: desc, target: target, appArgs: appArgs, enabled: enabled, kodiPassthrough: kodiPassthrough}
            mapOrder.Push(section)
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
            mappings[section] := {kind: "sc", actionType: actionType, sc: sc, desc: desc, target: target, appArgs: appArgs, enabled: enabled, kodiPassthrough: kodiPassthrough}
            mapOrder.Push(section)
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
    chkKodiPassthrough.Value := kodiPassthroughEnabled
    if kodiPassthroughEnabled
        A_TrayMenu.Check("Passthrough Buttons When Kodi Isn't Running")
    else
        A_TrayMenu.Uncheck("Passthrough Buttons When Kodi Isn't Running")
}

; ---------------- Startup ----------------
chkMaster.Value := masterEnabled
chkStartHidden.Value := startHidden
chkKodiPassthrough.Value := kodiPassthroughEnabled
LoadMappings()
kodiWasRunning := IsKodiRunning()   ; establish baseline so the first poll doesn't false-trigger a refresh
RegisterAllRawInputDevices()   ; enables raw-report mappings to fire even with no ini yet
RefreshList()
SetTimer(CheckKodiRunningState, 2000)   ; poll every 2s for Kodi starting/closing
if !startHidden
    ShowGui()
