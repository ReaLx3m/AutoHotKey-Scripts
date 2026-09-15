<a href='https://ko-fi.com/Y0F226ZBQV' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

## **All scripts require installed AHK v2 to run. Or you can use the scripts converted to executable from the **[Releases](https://github.com/ReaLx3m/AutoHotKey-Scripts/releases)** page**

### **[MF Button Mapper](https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/MF%20Button%20Mapper.ahk)**

If you need a keyboard, remote, mouse button mapped/re-mapped, you want this.

   <img width="1000" height="720" alt="GUI" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/2.Main%20GUI.jpg" />

In short:

- Uses 5MB of RAM, mostly 0% CPU load with scary spikes of 0.1-0.2% about 5–6 times a minute.
   <img width="720" height="720" alt="Memory Footprint" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/1.Memory%20Footprint.jpg" />

- Ability to remap all standard keys that Windows recognizes.

- Ability to map keys that Windows doesn't recognize using the Raw HID Capture function, for example buttons from an Android remote, remapping the FN key on a standard keyboard etc.

- Ability to remap mouse buttons (via the Raw HID sniffer function). For mice with more than 5 buttons (the standard 3 plus 2 side buttons), it seems there's no standard way (not even with raw HID) to detect all of them, manufacturer software is required. But this limitation can be worked around if the mouse has onboard memory. In onboard memory, all the extra buttons can be mapped to F13–F24(G Hub offers this as an option, not sure about other brands), and after that they can be mapped in this app without any problem.

   <img width="460" height="720" alt="HID Sniffer" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/9.%20HID%20Sniffer.jpg" />
   <img width="460" height="720" alt="Map raw hid" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/10.%20Map%20raw%20HID.jpg" />
   
- Either a single profile (Default), or multiple custom profiles with automatic switching depending on which application is in focus.

- A ton of operating modes and ways to trigger a mapped command, even without macros a single press and release of a key can execute up to 3 actions: 1 on press, 2 on hold (with adjustable timing), 3 on release.

   <img width="460" height="720" alt="Run Modes" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/4.%20Run%20Modes.jpg" />
   <img width="460" height="720" alt="Triggers" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/5.%20Triggers.jpg" />
   <img width="460" height="720" alt="Actions" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/3.%20Actions.jpg" />
   
- Macros with options for manual entry as well as recording.
  
   <img width="720" height="720" alt="Macros" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/8.%20Macros.jpg" />
   
- A modifier key option(global and per profile), which when active (Hold and Toggle options) makes a second layer of mappings valid (those under the MOD section), allowing you to remap an entire keyboard and/or assign macros to every key if needed. 

   <img width="660" height="720" alt="Modifier" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/6.%20Modifier%20Options.jpg" />
   
- Easy copying of already-mapped keys and macros within/between profiles.

   <img width="800" height="720" alt="Copy map and assign Macro" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/MF%20Button%20Mapper/7.%20Right%20click%20copy%20map%20and%20assign%20macro.jpg" />



### **[HWiNFO Auto Restart](https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/HWiNFO%20Auto%20Restart.ahk)**

I like to restart my HWInfo app every 11 hours and 58 minutes, im just autistic like that, no other reason.

Some people say functionality like this helps them defeat the 12 hour "Shared Memory" limit for free users without needing to manually re-activate the feature. Just a lucky unintended coincidence i suppose.

### **[HWiNFO Manager](https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/HWiNFO%20Manager.ahk)**

The Script will generate .ini file for the settings, and a Profiles folder for the exported .reg files, so you may want to create a folder dedicated to it.

- Save Profile feature saves your current HWiNFO registry key saving your settings for: Sensor panel layout, Polling/update interval and units, OSD (on-screen display) settings, Gadget settings, Logging settings, Alarm/threshold settings, Custom sensor definitions, Window position/size and general UI preferences(main window layout, docking, etc.), Remote/shared memory settings.
- Load profile erases the whole HKCU\Software\HWiNFO64(HWiNFO32) registry key(where the settings are kept) and imports the key related to the profile entry you selected to load. Must be done this way, as if key related to profile is simply imported it will merge with the current registry entries and set options wont be removed from the previous key, just new options added. Theres a guard implemented for the registry key delete function to only accept HWiNFO32 or HWiNFO64 as arguments.
- Auto restart script is merged too, but with user exposed settings.
- HWiNfo watchdog added that will restart the app in case of a crash, you can select auto start or have it ask before it restarts it.


   <img width="360" height="720" alt="HWiNFO Manager" src="https://github.com/ReaLx3m/AutoHotKey-Scripts/blob/main/images/HWiNFO%20Manager.png" />


