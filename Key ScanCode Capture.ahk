#Requires AutoHotkey v2.0

; Remote Control Scancode Scanner
; Press any button on your remote to see its scancode
; Press F12 to exit

; Create a log file in the script directory
logFile := A_ScriptDir "\remote_scancodes.txt"
separator := ""
Loop 50
    separator .= "-"
FileAppend("Remote Scancode Log - " A_Now "`n" separator "`n", logFile)

; GUI to display results
g := Gui("+AlwaysOnTop", "Remote Scancode Scanner")
g.SetFont("s12", "Consolas")
g.Add("Text", "w500", "Press buttons on your remote...")
g.Add("Text", "w500 vStatus", "Waiting for input...")
scList := g.Add("ListBox", "w500 h300 vScancodes")
g.Add("Text", "w500", "Press F12 to exit • Log saved to remote_scancodes.txt")
g.Show()

; Setup input hook to capture all keys
ih := InputHook("V")
ih.KeyOpt("{All}", "N")  ; Notify for all keys
ih.OnKeyDown := LogKey
ih.OnKeyUp := (*) => {}  ; Ignore key up events
ih.Start()

scMap := Map()  ; Track unique scancodes

LogKey(ih, VK, SC) {
    vkHex := Format("0x{:X}", VK)
    scHex := Format("0x{:X}", SC)
    scDec := Format("sc{:03X}", SC)
    
    ; Update GUI
    timestamp := FormatTime(A_Now, "HH:mm:ss")
    entry := timestamp " - VK:" vkHex " | SC:" scDec " (" scHex ")"
    
    ; Add to list if new scancode
    if !scMap.Has(SC) {
        scMap[SC] := true
        scList.Add([entry])
        
        ; Log to file
        FileAppend(entry "`n", logFile)
    }
    
    ; Update status
    g["Status"].Value := "Last pressed: " scDec " (Total unique: " scMap.Count ")"
    
    ; Also show tooltip briefly
    ToolTip("SC: " scDec "`nVK: " vkHex)
    SetTimer(() => ToolTip(), -1500)
}

; Exit on F12
F12:: {
    global ih, g
    ih.Stop()
    FileAppend("`nSession ended: " A_Now "`n`n", logFile)
    g.Destroy()
    ExitApp
}

; Exit when GUI closes
g.OnEvent("Close", (*) => ExitApp())