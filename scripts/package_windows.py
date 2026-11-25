#!/usr/bin/env python3
"""Cross-compile and assemble portable Ni packages from macOS or Linux."""

import argparse
import hashlib
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
GIT_FOR_WINDOWS = "https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/"
TARGETS = {
    "x64": {
        "cpu": "amd64",
        "zig_target": "x86_64-windows-gnu",
        "machine": 0x8664,
        "archive": "MinGit-2.56.1-64-bit.zip",
        "sha256": "4a92850b6e917da4fd010669b614b55dccf5b0ec333a534cc4be4700dfefdafd",
        "prefix": "ucrt64",
        "ssl_suffix": "-x64",
    },
    "arm64": {
        "cpu": "arm64",
        "zig_target": "aarch64-windows-gnu",
        "machine": 0xAA64,
        "archive": "MinGit-2.56.1-arm64.zip",
        "sha256": "96571e442e90523a90e5fd8661b4c4e43bc192910f3c6db938816e6955b4cc8c",
        "prefix": "clangarm64",
        "ssl_suffix": "",
    },
}


def verify_machine(path, expected):
    with path.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise ValueError(f"Missing Windows executable signature in {path.name}")
        stream.seek(0x3C)
        pe_offset = struct.unpack("<I", stream.read(4))[0]
        stream.seek(pe_offset)
        signature, machine = struct.unpack("<4sH", stream.read(6))
    if signature != b"PE\0\0" or machine != expected:
        raise ValueError(f"Unexpected Windows binary architecture in {path.name}")


def package_target(arch, nim, zig, work, output):
    target = TARGETS[arch]
    stage = work / arch
    stage.mkdir()

    wrapper = work / f"zig-{arch}"
    wrapper.write_text(f'#!/bin/sh\nexec {shlex.quote(zig)} cc -target {target["zig_target"]} "$@"\n')
    wrapper.chmod(0o700)
    subprocess.run([
        nim, "c", "-d:release", "--os:windows", f'--cpu:{target["cpu"]}', "--cc:clang",
        f"--clang.exe:{wrapper}", f"--clang.linkerexe:{wrapper}", f"--nimcache:{work / ('cache-' + arch)}",
        f"-o:{stage / 'ni.exe'}", "src/ni.nim",
    ], cwd=ROOT, check=True)

    download = work / target["archive"]
    with urllib.request.urlopen(GIT_FOR_WINDOWS + target["archive"], timeout=60) as source:
        with download.open("wb") as destination:
            shutil.copyfileobj(source, destination)
    with download.open("rb") as archive:
        if hashlib.file_digest(archive, "sha256").hexdigest() != target["sha256"]:
            raise ValueError(f"Checksum mismatch for {download.name}")

    ssl = f'libssl-3{target["ssl_suffix"]}.dll'
    crypto = f'libcrypto-3{target["ssl_suffix"]}.dll'
    files = {
        f"bin/{ssl}": ssl,
        f"bin/{crypto}": crypto,
        "etc/ssl/certs/ca-bundle.crt": "cacert.pem",
        "share/licenses/openssl/LICENSE": "OpenSSL-LICENSE.txt",
    }
    with zipfile.ZipFile(download) as archive:
        for source_path, filename in files.items():
            (stage / filename).write_bytes(archive.read(f'{target["prefix"]}/{source_path}'))
    for filename in ("ni.exe", ssl, crypto):
        verify_machine(stage / filename, target["machine"])
    if b"-----BEGIN CERTIFICATE-----" not in (stage / "cacert.pem").read_bytes():
        raise ValueError("The CA bundle contains no PEM certificates")
    shutil.copyfile(ROOT / "LICENSE", stage / "LICENSE")
    shutil.copyfile(ROOT / "docs" / "windows.md", stage / "README.md")

    archive_path = output / f"ni-windows-{arch}.zip"
    staged_archive = work / archive_path.name
    members = ["ni.exe", *files.values(), "LICENSE", "README.md"]
    with zipfile.ZipFile(staged_archive, "w", zipfile.ZIP_DEFLATED) as archive:
        for filename in sorted(members):
            archive.write(stage / filename, filename)
    package_dir = output / arch
    package_dir.mkdir(exist_ok=True)
    for filename in members:
        (stage / filename).replace(package_dir / filename)
    staged_archive.replace(archive_path)
    print(f"{arch}: {output / arch} and {archive_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["all", *TARGETS], default="all")
    args = parser.parse_args()
    nim, zig = shutil.which("nim"), shutil.which("zig")
    if not nim or not zig:
        parser.error("Nim and Zig must be on PATH")

    output = ROOT / "dist" / "windows"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ni-package-", dir=output) as tmp:
        for arch in TARGETS if args.arch == "all" else (args.arch,):
            package_target(arch, nim, zig, Path(tmp), output)
    shutil.copyfile(ROOT / "docs" / "windows.md", output / "README.md")


if __name__ == "__main__":
    main()
