module

import CheckLean

open CheckLean

private theorem cliOverrideFixture : True := by
  exact True.intro

private def expect (condition : Bool) (message : String) : IO Unit := do
  unless condition do
    throw <| IO.userError message

private def writeSource (root : System.FilePath) (name source : String) : IO Unit :=
  IO.FS.writeFile (root / name) source

private unsafe def testClean : IO Unit :=
  IO.FS.withTempDir fun root => do
    writeSource root "Clean.lean" <| String.intercalate "\n" [
      "import Lean",
      "-- simp aesop grind",
      "def simpValue := \"simp in a string\"",
      "example : True := by",
      "  exact True.intro",
      ""
    ]
    let report ← checkProject { root }
    expect report.failures.isEmpty s!"clean source produced an analysis failure: {repr report.failures}"
    expect report.findings.isEmpty "comments, strings, or identifiers were reported as tactics"
    expect (report.exitCode == 0) "clean report should map to exit code 0"

private unsafe def testDefaultPrefixesAndQuotation : IO Unit :=
  IO.FS.withTempDir fun root => do
    writeSource root "Forbidden.lean" <| String.intercalate "\n" [
      "import Lean",
      "syntax \"aesop_custom\" : tactic",
      "macro_rules | `(tactic| aesop_custom) => `(tactic| exact True.intro)",
      "example (n : Nat) : n = n := by simp",
      "example (n : Nat) : n = n := by simpa",
      "example (n : Nat) : n = n := by grind",
      "example (n : Nat) : n = n := by omega",
      "example : True := by trivial",
      "example : True := by decide",
      "example : True := by native_decide",
      "example : True := by aesop_custom",
      "macro \"quoted_tac\" : tactic => `(tactic| simp)",
      ""
    ]
    let report ← checkProject { root }
    expect report.failures.isEmpty s!"valid forbidden-tactic fixture failed to elaborate: {repr report.failures}"
    for token in #["simp", "simpa", "grind", "omega", "trivial", "aesop_custom"] do
      expect (report.findings.any fun finding => finding.tactic == token)
        s!"expected tactic '{token}' was not reported"
    expect (report.findings.all fun finding => finding.tactic != "decide" && finding.tactic != "native_decide")
      "excluded decision tactics should not be reported by the defaults"
    expect ((report.findings.countP fun finding => finding.tactic == "simp") == 2)
      "direct and quoted simp uses should each be reported once"
    expect (report.findings.all fun finding => finding.file == "Forbidden.lean")
      "findings should use root-relative paths"
    expect (report.exitCode == 1) "forbidden tactics should map to exit code 1"

private unsafe def testArgumentReplacement : IO Unit :=
  IO.FS.withTempDir fun root => do
    writeSource root "Override.lean" <| String.intercalate "\n" [
      "import Lean",
      "example : True := by exact True.intro",
      "example (n : Nat) : n = n := by simp",
      ""
    ]
    let report ← checkProject { root, forbiddenPrefixes := #["exact"] }
    expect report.failures.isEmpty "override fixture failed to elaborate"
    expect (report.findings.size == 1) "override should replace, not extend, the defaults"
    expect (report.findings[0]!.tactic == "exact") "override prefix did not report exact"

private unsafe def testExcludedDirectories : IO Unit :=
  IO.FS.withTempDir fun root => do
    IO.FS.createDirAll (root / ".lake")
    IO.FS.createDirAll (root / ".git")
    writeSource root "Clean.lean" "import Lean\nexample : True := by exact True.intro\n"
    IO.FS.writeFile (root / ".lake" / "Generated.lean")
      "import Lean\nexample (n : Nat) : n = n := by simp\n"
    IO.FS.writeFile (root / ".git" / "Hidden.lean")
      "import Lean\nexample (n : Nat) : n = n := by grind\n"
    let report ← checkProject { root }
    expect report.failures.isEmpty "excluded-directory fixture failed"
    expect report.findings.isEmpty ".lake or .git files were scanned"

private unsafe def testFrontendFailure : IO Unit :=
  IO.FS.withTempDir fun root => do
    writeSource root "Broken.lean" "import Lean\nexample : True := by\n  exact\n"
    let report ← checkProject { root }
    expect (report.failures.size == 1) "broken Lean source should produce one analysis failure"
    expect (report.failures[0]!.file == "Broken.lean") "failure path should be root-relative"
    expect (report.exitCode == 2) "analysis failures should map to exit code 2"

private unsafe def testMissingRoot : IO Unit :=
  IO.FS.withTempDir fun root => do
    let missing := root / "missing"
    let report ← checkProject { root := missing }
    expect (report.failures.size == 1) "missing root should produce one file-system failure"
    expect (report.exitCode == 2) "missing root should map to exit code 2"

public unsafe def main : IO UInt32 := do
  testClean
  testDefaultPrefixesAndQuotation
  testArgumentReplacement
  testExcludedDirectories
  testFrontendFailure
  testMissingRoot
  return 0
