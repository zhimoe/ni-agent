import std/os
from ./src/ni/release_info import NiVersion

version       = NiVersion
author        = "ni contributors"
description   = "Minimal, extensible coding agent in Nim compatible with Pi configurations"
license       = "MIT"
srcDir        = "src"
bin           = @["ni"]

requires "nim >= 2.0.0"

task test, "Run the full ni unit and integration test suite":
  exec "nim c -d:release -o:" & addFileExt("ni", ExeExt) & " src/ni.nim"
  exec "nim c -r tests/test_all.nim"
