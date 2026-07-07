## **All scripts require installed AHK v2 to run. Or you can use the scripts converted to executable from the **[Releases](https://github.com/ReaLx3m/AutoHotKey-Scripts/releases)** page**

### **[HWiNFO Auto Restart](https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/HWiNFO%20Auto%20Restart.ahk)**

I like to restart my HWInfo app every 11 hours and 58 minutes, im just autistic like that, no other reason.

Some people say functionality like this helps them defeat the 12 hour "Shared Memory" limit for free users without needing to manually re-activate the feature. Just a lucky unintended coincidence i suppose.

### **[HWiNFO Manager](https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/HWiNFO%20Manager.ahk)**

- Save Profile feature saves your current HWiNFO registry key saving your settings for: Sensor panel layout, Polling/update interval and units, OSD (on-screen display) settings, Gadget settings, Logging settings, Alarm/threshold settings, Custom sensor definitions, Window position/size and general UI preferences(main window layout, docking, etc.), Remote/shared memory settings.
- Load profile erases the whole HWiNFO64/32 registry key(where the settings are kept) and imports the key related to the profile entry you selected to load. Must be done this way, as if key related to profile is simply imported it will be additive to previous entries and setting from the previous key will remain. Theres a guard for the registry key delete function to only accept HWiNFO32 or HWiNFO64 as arguments.
- Auto restart script is merged too, but with user exposed settings.
- HWiNfo watchdog added that will restart the app in case of a crash, you can select auto start or have it ask before it restarts it.


   <img width="360" height="720" alt="HWiNFO Manager" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/HWiNFO%20Manager.png" />


