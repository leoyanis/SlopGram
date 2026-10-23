"""Signs an unpacked .app (and everything inside it) with a development profile.

usage: sign.py <App.app> <profile.mobileprovision> <identity sha1> <team id>
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

app, profile, identity, team = sys.argv[1:5]

MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGIC
    except OSError:
        return False


def bundle_id(bundle):
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def codesign(path, entitlements=None):
    cmd = ["codesign", "-f", "-s", identity, "--generate-entitlement-der"]
    if entitlements is not None:
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
            plistlib.dump(entitlements, f)
            cmd += ["--entitlements", f.name]
    subprocess.run(cmd + [path], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


main_id = bundle_id(app)

# Leftover App Store DRM metadata makes the phone refuse updates over an existing install
for root, dirs, files in os.walk(app):
    for d in list(dirs):
        if d == "SC_Info":
            shutil.rmtree(os.path.join(root, d))
            dirs.remove(d)


def entitlements_for(bundle):
    return {
        "application-identifier": f"{team}.{bundle_id(bundle)}",
        "com.apple.developer.team-identifier": team,
        "get-task-allow": True,
        "keychain-access-groups": [f"{team}.{main_id}"],
    }


# Loose Mach-O files first (dylibs, framework binaries), deepest paths first,
# then frameworks, then extensions, then the app itself.
bundles, loose = [], []
for root, dirs, files in os.walk(app):
    for d in dirs:
        if d.endswith((".framework", ".appex", ".app")):
            bundles.append(os.path.join(root, d))
    for name in files:
        path = os.path.join(root, name)
        if not os.path.islink(path) and is_macho(path):
            loose.append(path)

bundle_exes = set()
for b in bundles + [app]:
    try:
        with open(os.path.join(b, "Info.plist"), "rb") as f:
            exe = plistlib.load(f).get("CFBundleExecutable")
        if exe:
            bundle_exes.add(os.path.join(b, exe))
    except (OSError, KeyError):
        pass

for path in sorted(loose, key=lambda p: -p.count(os.sep)):
    if path not in bundle_exes:
        codesign(path)

for b in sorted(bundles, key=lambda p: -p.count(os.sep)):
    if b.endswith(".framework"):
        codesign(b)
    else:
        shutil.copy(profile, os.path.join(b, "embedded.mobileprovision"))
        codesign(b, entitlements_for(b))

shutil.copy(profile, os.path.join(app, "embedded.mobileprovision"))
codesign(app, entitlements_for(app))
subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
print(f"signed {app} as {team}.{main_id}")
