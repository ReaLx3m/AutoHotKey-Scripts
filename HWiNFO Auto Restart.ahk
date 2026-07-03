#Requires AutoHotkey v2.0
;
; Script Function:
; Watchdog for HWiNFO64 - restarts it roughly every 11h58m to refresh
;
;------------------------------------------------------------------------------------------
#SingleInstance Force
SetWorkingDir(A_ScriptDir) ; Ensures a consistent starting directory.
;------------------------------------------------------------------------------------------
; Admin Check:
;-------------
If IsProcessElevated(DllCall("GetCurrentProcessId"))
{
	; Running elevated, nothing to do here.
}
Else
{
	; Permissions escalation:
	RequestAdminSelf()
	ExitApp() ; Stop this unelevated instance so it can't race the elevated relaunch.
}
;------------------------------------------------------------------------------------------
; First Run
HWiNFO64Start()
;------------------------------------------------------------------------------------------
Loop
{
	If HWiNFO64PID() != 0
	{
		If HWiNFO64Kill() != 0
		{
			Sleep(250) ; Brief pause so the process fully releases before relaunching.
			HWiNFO64Start()
		}
		Else
		{
			MsgBox("HWiNFO64 process refused to be terminated. Did you enable admin for this process?", "HWiNFO64 Termination Error", "T5")
			Sleep(60000) ; Retry soon instead of waiting ~12 hours for the next cycle.
			Continue
		}
	}
	Else
	{
		Result := MsgBox("HWiNFO64 is not running, user may have closed it manually. Would you like to restart HWiNFO64?", "SoFMeRight's HWiNFO64 Tool", "YesNo")
		If Result = "Yes"
			HWiNFO64Start()
		Else
			ExitApp()
	}
	Sleep(GetMillisecondsForHours(11) + GetMillisecondsForMins(58))
}

;------------------------------------------------------------------------------------------
; Functions Section:
;------------------------------------------------------------------------------------------
HWiNFO64PID()
{
	Return ProcessExist("HWiNFO64.EXE")
}

HWiNFO64Kill()
{
	Return ProcessClose("HWiNFO64.EXE")
}

HWiNFO64Start()
{
	Run("*RunAs C:\Program Files\HWiNFO64\HWiNFO64.EXE")
}

IsProcessElevated(ProcessID)
{
	hProcess := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", ProcessID, "ptr")
	If !hProcess
		throw Error("OpenProcess failed", -1)

	If !DllCall("advapi32\OpenProcessToken", "ptr", hProcess, "uint", 0x0008, "ptr*", &hToken := 0)
	{
		DllCall("CloseHandle", "ptr", hProcess)
		throw Error("OpenProcessToken failed", -1)
	}

	If !DllCall("advapi32\GetTokenInformation", "ptr", hToken, "int", 20, "uint*", &IsElevated := 0, "uint", 4, "uint*", &size := 0)
	{
		DllCall("CloseHandle", "ptr", hToken)
		DllCall("CloseHandle", "ptr", hProcess)
		throw Error("GetTokenInformation failed", -1)
	}

	DllCall("CloseHandle", "ptr", hToken)
	DllCall("CloseHandle", "ptr", hProcess)
	Return IsElevated
}

RequestAdminSelf()
{
	If A_IsCompiled
		Run('*RunAs "' A_ScriptFullPath '" /restart')
	Else
		Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
}

GetMillisecondsForMins(minutes)
{
	Return minutes * 60000
}

GetMillisecondsForHours(hours)
{
	Return hours * 60 * 60000
}
