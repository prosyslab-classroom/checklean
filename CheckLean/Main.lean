module

import CheckLean

open CheckLean

private def writeStderr (message : String) : IO Unit := do
  let stderr ← IO.getStderr
  stderr.putStrLn message

public unsafe def main (args : List String) : IO UInt32 := do
  let prefixes := if args.isEmpty then defaultForbiddenPrefixes else args.toArray
  let report ← checkProject { forbiddenPrefixes := prefixes }
  for finding in report.findings do
    writeStderr (formatFinding finding)
  for failure in report.failures do
    writeStderr (formatFailure failure)
  return report.exitCode
