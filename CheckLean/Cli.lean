module

public import Cli
public import CheckLean.Scanner

public section

namespace CheckLean

private def writeStderr (message : String) : IO Unit := do
  let stderr ← IO.getStderr
  stderr.putStrLn message

def configFromParsed (parsed : Cli.Parsed) : Config :=
  let root := parsed.flag? "directory" |>.map (fun flag => flag.as! String) |>.getD "."
  let prefixes := parsed.variableArgsAs! String
  {
    root
    forbiddenPrefixes := if prefixes.isEmpty then defaultForbiddenPrefixes else prefixes
  }

private unsafe def runCheckLean (parsed : Cli.Parsed) : IO UInt32 := do
  let report ← checkProject (configFromParsed parsed)
  for finding in report.findings do
    writeStderr (formatFinding finding)
  for failure in report.failures do
    writeStderr (formatFailure failure)
  return report.exitCode

unsafe def checkLeanCmd : Cli.Cmd := `[Cli|
  "check-lean" VIA runCheckLean;
  "Scan Lean source files for forbidden tactics."

  FLAGS:
    d, directory : String; "Directory to scan. [Default: current directory]"

  ARGS:
    ...prefixes : String; "Forbidden tactic prefixes. [Default: simp, aesop, grind, omega, trivial]"
]

end CheckLean
