version = "0.1.0"
author = "Brian Dombroski"
description = "Single-file Go runner with v2 path/size/mtime cache (group dir + leaf) and temp go.mod build"
license = "MIT"

bin = @["gor"]

requires "nim >= 2.0.0"
requires "argsbarg >= 1.4.0"
