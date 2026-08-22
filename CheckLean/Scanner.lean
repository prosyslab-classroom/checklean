module

meta import all Lake.DSL
import Lake.Util.Lift

public import Lean.Elab.Frontend
public import Lean.Parser.Extension

public section

open Lean

namespace CheckLean

/-- Prefixes used when the command line does not provide an override. -/
def defaultForbiddenPrefixes : Array String := #["simp", "aesop", "grind", "omega"]

/-- Configuration for a project scan. -/
structure Config where
  root : System.FilePath := "."
  forbiddenPrefixes : Array String := defaultForbiddenPrefixes
  deriving Inhabited, Repr

/-- A directly written tactic whose first token has a forbidden prefix. -/
structure Finding where
  file : System.FilePath
  line : Nat
  column : Nat
  tactic : String
  matchedPrefix : String
  deriving Inhabited, Repr, BEq

/-- A file-system or Lean frontend failure that made a scan incomplete. -/
structure Failure where
  file : System.FilePath
  message : String
  deriving Inhabited, Repr, BEq

/-- Complete result of scanning a project. -/
structure Report where
  findings : Array Finding := #[]
  failures : Array Failure := #[]
  deriving Inhabited, Repr

namespace Report

def exitCode (report : Report) : UInt32 :=
  if !report.failures.isEmpty then 2
  else if !report.findings.isEmpty then 1
  else 0

end Report

private structure ScanContext where
  file : System.FilePath
  prefixes : Array String

private initialize scanContextRef : IO.Ref (Option ScanContext) ← IO.mkRef none
private initialize findingsRef : IO.Ref (Array Finding) ← IO.mkRef #[]
private initialize linterRegisteredRef : IO.Ref Bool ← IO.mkRef false

private theorem sizeOf_list_append_le [SizeOf α] (xs ys : List α) :
    sizeOf (xs ++ ys) ≤ sizeOf xs + sizeOf ys := by
  induction xs with
  | nil => simp
  | cons x xs ih => simp_all +arith

private theorem sizeOf_array_toList_le [SizeOf α] (xs : Array α) :
    sizeOf xs.toList ≤ sizeOf xs := by
  change sizeOf xs.toList ≤ 1 + sizeOf xs.toList
  simp

private def firstLeafAux? : List Syntax → Option (String × String.Pos.Raw)
  | [] => none
  | stx :: rest =>
    match stx with
    | .atom info value => return (value, ← info.getPos?)
    | .ident info raw _ _ => return (raw.toString, ← info.getPos?)
    | .node _ _ args => firstLeafAux? (args.toList ++ rest)
    | .missing => firstLeafAux? rest
termination_by work => sizeOf work
decreasing_by
  · simp_wf
    have h := sizeOf_list_append_le args.toList rest
    have ha := sizeOf_array_toList_le args
    omega
  · simp_wf

private def firstLeaf? (stx : Syntax) : Option (String × String.Pos.Raw) :=
  firstLeafAux? [stx]

private def matchingPrefix? (prefixes : Array String) (token : String) : Option String :=
  prefixes.find? fun candidate => token.startsWith candidate

private def collectTactics (isTacticKind : SyntaxNodeKind → Bool) (fileMap : FileMap)
    (ctx : ScanContext) : Syntax → IO Unit
  | stx@(.node _ kind args) => do
      if isTacticKind kind then
        let some (token, rawPos) := firstLeaf? stx | pure ()
        let some matched := matchingPrefix? ctx.prefixes token | pure ()
        let pos := fileMap.toPosition rawPos
        findingsRef.modify fun findings => findings.push {
          file := ctx.file
          line := pos.line
          column := pos.column + 1
          tactic := token
          matchedPrefix := matched
        }
      for arg in args do
        collectTactics isTacticKind fileMap ctx arg
  | _ => pure ()

private def forbiddenTacticLinter : Lean.Elab.Command.ModuleLinter where
  name := `CheckLean.forbiddenTacticLinter
  run := fun commands => do
    let some ctx ← scanContextRef.get | return
    let env ← getEnv
    let some tacticCategory := Lean.Parser.getParserCategory? env `tactic | return
    let fileMap ← getFileMap
    for command in commands do
      collectTactics (fun kind => tacticCategory.kinds.contains kind) fileMap ctx command

private def ensureLinterRegistered : IO Unit := do
  unless ← linterRegisteredRef.get do
    Lean.Elab.Command.addModuleLinter forbiddenTacticLinter
    linterRegisteredRef.set true

private def isSkippedDirectory (name : String) : Bool :=
  name == ".git" || name == ".lake"

private def appendRelative (base : System.FilePath) (name : String) : System.FilePath :=
  if base.toString.isEmpty then name else base / name

private def discoverLeanFiles (current relative : System.FilePath) : IO (Array System.FilePath) := do
  let mut pending : Array (System.FilePath × System.FilePath) := #[(current, relative)]
  let mut files := #[]
  while !pending.isEmpty do
    let (directory, directoryRelative) := pending.back!
    pending := pending.pop
    for entry in ← directory.readDir do
      let metadata ← entry.path.symlinkMetadata
      if metadata.type == .dir then
        unless isSkippedDirectory entry.fileName do
          let childRelative := appendRelative directoryRelative entry.fileName
          pending := pending.push (entry.path, childRelative)
      else if metadata.type == .file && entry.path.extension == some "lean" then
        files := files.push (appendRelative directoryRelative entry.fileName)
  pure files

private def moduleNameFor (relative : System.FilePath) : Name :=
  let withoutExtension := relative.withExtension "" |>.toString
  let normalized := withoutExtension.replace "\\" "/"
  Name.mkSimple <| normalized.replace "/" "."

private unsafe def analyzeFile (config : Config) (relative : System.FilePath) : IO (Option Failure) := do
  let absolute := config.root / relative
  let input ← IO.FS.readFile absolute
  findingsRef.set #[]
  scanContextRef.set <| some { file := relative, prefixes := config.forbiddenPrefixes }
  let options := Lean.Elab.async.set {} false
  let (frontendOutput, env?) ← IO.FS.withIsolatedStreams do
    Lean.enableInitializersExecution
    Lean.Elab.runFrontend input options absolute.toString (moduleNameFor relative)
  scanContextRef.set none
  if env?.isSome then
    pure none
  else
    let trimmed := frontendOutput.trimAscii.copy
    let message := if trimmed.isEmpty then
      "Lean frontend failed without a diagnostic"
    else
      trimmed
    pure <| some { file := relative, message }

private def findingLt (left right : Finding) : Bool :=
  if left.file.toString != right.file.toString then
    left.file.toString < right.file.toString
  else if left.line != right.line then
    left.line < right.line
  else if left.column != right.column then
    left.column < right.column
  else
    left.tactic < right.tactic

private def failureLt (left right : Failure) : Bool :=
  left.file.toString < right.file.toString

private def deduplicateFindings (findings : Array Finding) : Array Finding := Id.run do
  let sorted := findings.qsort findingLt
  let mut result := #[]
  for finding in sorted do
    if let some previous := result.back? then
      if previous.file == finding.file && previous.line == finding.line &&
          previous.column == finding.column && previous.tactic == finding.tactic then
        continue
    result := result.push finding
  return result

/-- Recursively scans all `.lean` files below `config.root`. -/
private unsafe def checkProjectCore (config : Config) : IO Report := do
  ensureLinterRegistered
  Lean.initSearchPath (← Lean.findSysroot) [config.root / ".lake" / "build" / "lib" / "lean"]
  let files ← discoverLeanFiles config.root ""
  let files := files.qsort fun left right => left.toString < right.toString
  let mut allFindings := #[]
  let mut failures := #[]
  for file in files do
    try
      let failure? ← analyzeFile config file
      allFindings := allFindings ++ (← findingsRef.get)
      if let some failure := failure? then
        failures := failures.push failure
    catch error =>
      failures := failures.push { file, message := error.toString }
  scanContextRef.set none
  findingsRef.set #[]
  pure {
    findings := deduplicateFindings allFindings
    failures := failures.qsort failureLt
  }

/-- Recursively scans all `.lean` files below `config.root`, returning fatal discovery errors in the report. -/
public unsafe def checkProject (config : Config) : IO Report := do
  try
    checkProjectCore config
  catch error =>
    pure { failures := #[{ file := config.root, message := error.toString }] }

def formatFinding (finding : Finding) : String :=
  s!"{finding.file}:{finding.line}:{finding.column}: error: forbidden tactic '{finding.tactic}' (matched prefix '{finding.matchedPrefix}')"

def formatFailure (failure : Failure) : String :=
  s!"{failure.file}: error: failed to analyze source\n{failure.message}"

end CheckLean
