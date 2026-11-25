# NimScript compiler configuration for ni
switch("mm", "orc")
switch("threads", "on")
switch("define", "ssl")
switch("path", "src")

when defined(windows) and not defined(sslVersion):
  when defined(amd64):
    switch("define", "sslVersion=3-x64")
  else:
    switch("define", "sslVersion=3")
