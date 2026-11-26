"""Extract a profile using Unicode paths, independent of the Windows ANSI locale."""
import json
import pathlib
import sys
import tarfile

archive, output, mode = sys.argv[1:]
destination = pathlib.Path(output).resolve()
destination.mkdir(parents=True, exist_ok=True)
handle = None
for encoding in ("utf-8", "cp936"):
    try:
        handle = tarfile.open(archive, "r:gz", encoding=encoding, errors="strict")
        members = handle.getmembers()
        break
    except UnicodeDecodeError:
        if handle is not None:
            handle.close()
        handle = None
if handle is None:
    raise RuntimeError("Profile archive filename encoding is unsupported")
with handle:
    for member in members:
        normalized = member.name.replace("\\", "/")
        name = pathlib.PurePosixPath(normalized)
        if name.is_absolute() or ".." in name.parts or pathlib.PureWindowsPath(normalized).drive:
            raise RuntimeError("Unsafe profile archive path")
        if mode == "seed" and (not name.parts or name.parts[0] != "User Data"):
            raise RuntimeError("Unexpected local profile archive member")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise RuntimeError("Unsupported profile archive member")
        target = (destination / pathlib.Path(*name.parts)).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError("Profile archive target escaped its directory")
        if (member.issym() or member.islnk()) and not hasattr(tarfile, "data_filter"):
            raise RuntimeError("Python with safe link extraction is required")
    if hasattr(tarfile, "data_filter"):
        handle.extractall(destination, members=members, filter="data")
    else:
        handle.extractall(destination, members=members)
print(json.dumps({"files": len(members), "encoding": encoding}))
