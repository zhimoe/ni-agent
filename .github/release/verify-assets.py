from hashlib import sha256
from pathlib import Path
import shutil
import struct
import sys
import zipfile

artifacts, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
checksums = []
for arch, machine in (("x64", 0x8664), ("arm64", 0xaa64)):
    package = artifacts / f"ni-windows-{arch}.zip"
    suffix = "-x64" if arch == "x64" else ""
    dlls = {f"libssl-3{suffix}.dll", f"libcrypto-3{suffix}.dll"}
    with zipfile.ZipFile(package) as zipped:
        assert set(zipped.namelist()) == dlls | {"ni.exe", "cacert.pem", "LICENSE", "README.md", "OpenSSL-LICENSE.txt"}
        assert zipped.testzip() is None
        assert b"-----BEGIN CERTIFICATE-----" in zipped.read("cacert.pem")
        for name in dlls | {"ni.exe"}:
            data = zipped.read(name)
            assert data == (artifacts / arch / name).read_bytes()
            offset, = struct.unpack_from("<I", data, 0x3c)
            assert data[:2] == b"MZ" and data[offset:offset+4] == b"PE\x00\x00"
            assert struct.unpack_from("<H", data, offset + 4)[0] == machine
    asset = output / f"ni-v0.6.0-windows-{arch}.zip"
    shutil.copyfile(package, asset)
    checksums.append(f"{sha256(asset.read_bytes()).hexdigest()}  {asset.name}\n")
    print(f"{asset.name} {asset.stat().st_size} bytes, tested binary and dependency hashes match")
(output / "SHA256SUMS").write_text("".join(checksums), encoding="ascii")
