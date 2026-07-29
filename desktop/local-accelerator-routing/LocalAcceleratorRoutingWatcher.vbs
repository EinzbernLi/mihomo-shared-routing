Option Explicit

Dim shell, fileSystem, scriptDirectory, watcherScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
watcherScript = scriptDirectory & "\LocalAcceleratorRoutingWatcher.ps1"
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & watcherScript & """"

' Window style 0 keeps the task completely hidden; do not wait for the watcher.
shell.Run command, 0, False
