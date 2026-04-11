nimble install -y --depsOnly
nim c -d:release --hints:off --verbosity:0 -o:dist/gor gor.nim
