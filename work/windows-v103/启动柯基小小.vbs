Option Explicit

Dim shell, fso, baseDir, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "CorgiPet.ps1")
command = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

shell.Run command, 0, False
