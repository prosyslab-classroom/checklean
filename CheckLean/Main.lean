module

import CheckLean.Cli

open CheckLean

public unsafe def main (args : List String) : IO UInt32 :=
  checkLeanCmd.validate args
