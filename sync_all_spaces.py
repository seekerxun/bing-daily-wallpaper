#!/usr/bin/python3
"""Make one image the wallpaper for every macOS Space/display.

macOS may keep per-Space overrides that beat the shared AllSpacesAndDisplays
entry, and WallpaperAgent can rewrite Index.plist after a restart. This helper
therefore:

1. Writes the official shared AllSpacesAndDisplays Desktop config
2. Updates every existing per-Space / per-Display Desktop entry to the same image
3. Clears Spaces/Displays so inactive Spaces cannot keep yesterday's picture
4. Supports --check to verify the on-disk Index matches the target image
"""

from __future__ import annotations

import copy
import datetime as dt
import os
import plistlib
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


def binary_plist(value: object) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=False)


def copy_xattrs(source: Path, destination: Path) -> None:
    if not all(hasattr(os, name) for name in ("listxattr", "getxattr", "setxattr")):
        return
    try:
        for name in os.listxattr(source):
            os.setxattr(destination, name, os.getxattr(source, name))
    except OSError:
        # Extended attributes are not required for the wallpaper store to work.
        pass


def image_uri(image_file: Path) -> str:
    return image_file.resolve().as_uri()


def desktop_config(image_file: Path, now: dt.datetime) -> dict[str, Any]:
    return {
        "LastSet": now,
        "LastUse": now,
        "Content": {
            "Choices": [
                {
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [],
                    "Configuration": binary_plist(
                        {
                            "type": "imageFile",
                            "url": {"relative": image_uri(image_file)},
                        }
                    ),
                }
            ],
            "Shuffle": "$null",
            "EncodedOptionValues": binary_plist({"values": {}}),
        },
    }


def configuration_image_uri(configuration: object) -> str | None:
    if not isinstance(configuration, (bytes, bytearray)):
        return None
    try:
        payload = plistlib.loads(configuration)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    url = payload.get("url")
    if isinstance(url, dict):
        relative = url.get("relative")
        if isinstance(relative, str):
            return relative
    if isinstance(url, str):
        return url
    return None


def desktop_image_uris(desktop: object) -> list[str]:
    if not isinstance(desktop, dict):
        return []
    content = desktop.get("Content")
    if not isinstance(content, dict):
        return []
    choices = content.get("Choices")
    if not isinstance(choices, list):
        return []

    uris: list[str] = []
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        uri = configuration_image_uri(choice.get("Configuration"))
        if uri:
            uris.append(uri)
    return uris


def iter_desktop_dicts(node: object):
    if isinstance(node, dict):
        desktop = node.get("Desktop")
        if isinstance(desktop, dict):
            yield desktop
        for value in node.values():
            yield from iter_desktop_dicts(value)
    elif isinstance(node, list):
        for value in node:
            yield from iter_desktop_dicts(value)


def replace_desktop_images(node: object, desktop: dict[str, Any]) -> int:
    """Overwrite every Desktop record under node with a copy of desktop."""
    updated = 0
    if isinstance(node, dict):
        if isinstance(node.get("Desktop"), dict):
            node["Desktop"] = copy.deepcopy(desktop)
            if "Type" in node:
                node["Type"] = "individual"
            updated += 1
        for key, value in list(node.items()):
            if key == "Desktop":
                continue
            updated += replace_desktop_images(value, desktop)
    elif isinstance(node, list):
        for value in node:
            updated += replace_desktop_images(value, desktop)
    return updated


def store_matches_image(store: dict[str, Any], image_file: Path) -> bool:
    expected = image_uri(image_file)
    all_spaces = store.get("AllSpacesAndDisplays")
    shared_uris = []
    if isinstance(all_spaces, dict):
        shared_uris = desktop_image_uris(all_spaces.get("Desktop"))

    space_uris: list[str] = []
    for desktop in iter_desktop_dicts(store.get("Spaces") or {}):
        space_uris.extend(desktop_image_uris(desktop))
    for desktop in iter_desktop_dicts(store.get("Displays") or {}):
        space_uris.extend(desktop_image_uris(desktop))

    if shared_uris:
        if any(uri != expected for uri in shared_uris):
            return False
        if space_uris and any(uri != expected for uri in space_uris):
            return False
        return True

    # Shared mode is off: every per-Space/display Desktop must already be current.
    if not space_uris:
        return False
    return all(uri == expected for uri in space_uris)


def load_store(index_file: Path) -> dict[str, Any]:
    with index_file.open("rb") as source:
        store = plistlib.load(source)
    if not isinstance(store, dict):
        raise ValueError("wallpaper Index.plist root must be a dictionary")
    return store


def write_store(index_file: Path, store: dict[str, Any], backup_file: Path | None) -> None:
    if backup_file is not None:
        backup_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(index_file, backup_file)

    original_stat = index_file.stat()
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=index_file.parent, prefix=".Index.", suffix=".tmp", delete=False
        ) as temporary:
            temporary_name = temporary.name
            plistlib.dump(store, temporary, fmt=plistlib.FMT_BINARY, sort_keys=False)

        temporary_path = Path(temporary_name)
        os.chmod(temporary_path, stat.S_IMODE(original_stat.st_mode))
        copy_xattrs(index_file, temporary_path)
        os.replace(temporary_path, index_file)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def apply_image(image_file: Path, index_file: Path, backup_file: Path) -> None:
    store = load_store(index_file)
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    desktop = desktop_config(image_file, now)

    all_spaces = store.setdefault("AllSpacesAndDisplays", {})
    if not isinstance(all_spaces, dict):
        all_spaces = {}
        store["AllSpacesAndDisplays"] = all_spaces
    all_spaces["Type"] = "individual"
    all_spaces["Desktop"] = copy.deepcopy(desktop)

    system_default = store.setdefault("SystemDefault", {})
    if not isinstance(system_default, dict):
        system_default = {}
        store["SystemDefault"] = system_default
    system_default["Type"] = "individual"
    system_default["Desktop"] = copy.deepcopy(desktop)

    # Keep inactive Spaces from retaining yesterday's picture if WallpaperAgent
    # later disables shared mode and recreates per-Space records from these.
    spaces = store.get("Spaces")
    displays = store.get("Displays")
    if isinstance(spaces, dict):
        replace_desktop_images(spaces, desktop)
    if isinstance(displays, dict):
        replace_desktop_images(displays, desktop)

    # Official "Show on all Spaces" layout: shared Desktop, no per-Space overrides.
    store["Spaces"] = {}
    store["Displays"] = {}

    write_store(index_file, store, backup_file)
    print(f"all Spaces now share: {image_file}", flush=True)


def check_image(image_file: Path, index_file: Path, verbose: bool = False) -> int:
    store = load_store(index_file)
    if store_matches_image(store, image_file):
        if verbose:
            print(f"Index matches: {image_file}", flush=True)
        return 0
    if verbose:
        print(f"Index does not fully match: {image_file}", flush=True)
    return 1


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)

    if args and args[0] == "--check":
        verbose = False
        check_args = args[1:]
        if check_args and check_args[0] == "--verbose":
            verbose = True
            check_args = check_args[1:]
        if len(check_args) != 2:
            print(
                "usage: sync_all_spaces.py --check [--verbose] IMAGE_FILE INDEX_PLIST",
                file=sys.stderr,
            )
            return 2
        image_file = Path(check_args[0]).expanduser().resolve()
        index_file = Path(check_args[1]).expanduser().resolve()
        if not image_file.is_file():
            print(f"wallpaper image does not exist: {image_file}", file=sys.stderr)
            return 1
        if not index_file.is_file():
            print(f"wallpaper index does not exist: {index_file}", file=sys.stderr)
            return 1
        return check_image(image_file, index_file, verbose=verbose)

    if len(args) != 3:
        print(
            "usage: sync_all_spaces.py IMAGE_FILE INDEX_PLIST BACKUP_PLIST\n"
            "       sync_all_spaces.py --check IMAGE_FILE INDEX_PLIST",
            file=sys.stderr,
        )
        return 2

    image_file = Path(args[0]).expanduser().resolve()
    index_file = Path(args[1]).expanduser().resolve()
    backup_file = Path(args[2]).expanduser().resolve()

    if not image_file.is_file():
        print(f"wallpaper image does not exist: {image_file}", file=sys.stderr)
        return 1
    if not index_file.is_file():
        print(f"wallpaper index does not exist: {index_file}", file=sys.stderr)
        return 1

    apply_image(image_file, index_file, backup_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
