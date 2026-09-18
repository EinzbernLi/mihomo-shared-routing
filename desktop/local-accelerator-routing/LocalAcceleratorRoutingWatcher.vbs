Option Explicit

' The task waits for this process, so a watcher crash becomes a task failure
' that Task Scheduler can restart. The PowerShell script also owns a named
' mutex to prevent duplicate instances.
Dim shell, fileSystem, scriptDirectory, watcherScript, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
watcherScript = scriptDirectory & "\LocalAcceleratorRoutingWatcher.ps1"
' This machine uses RemoteSigned. Explicitly selecting it lets a local
' trusted deployment run while avoiding the old ExecutionPolicy Bypass.
command = "powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File """ & watcherScript & """"

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
