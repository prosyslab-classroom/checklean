import Lake

open Lake DSL

package checklean

lean_lib CheckLean

@[default_target]
lean_exe «check-lean» where
  root := `CheckLean.Main
  supportInterpreter := true

@[test_driver]
lean_exe checklean_tests where
  root := `CheckLean.Tests
  supportInterpreter := true
