"""Write UTF-8 PAX profile archives, including names outside the ANSI code page."""
import pathlib
import sys
import tarfile

source, output, mode = sys.argv[1:]
transient = {"SingletonLock", "SingletonSocket", "SingletonCookie", "DevToolsActivePort", "LOCK", "lockfile"}
locked_cookies = {"User Data/Default/Network/Cookies", "User Data/Default/Cookies"}

def include(info):
    name = info.name.removeprefix("./")
    if pathlib.PurePosixPath(name).name in transient:
        return None
    if mode == "live" and any(name == value + suffix for value in locked_cookies for suffix in ("", "-journal", "-wal", "-shm")):
        return None
    return info

try:
    with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT, encoding="utf-8", compresslevel=1) as archive:
        archive.add(source, arcname=".", filter=include)
except Exception as error:
    print("Profile archive failed: " + type(error).__name__ + "; errno=" + str(getattr(error, "errno", None)), file=sys.stderr)
    sys.exit(1)
