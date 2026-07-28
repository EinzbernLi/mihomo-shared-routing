Option Explicit

' Starts the watcher without leaving a visible PowerShell window.
Dim shell, fs, folder, command
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
          folder & "\SteamRoutingWatcher.ps1"""
shell.Run command, 0, False
