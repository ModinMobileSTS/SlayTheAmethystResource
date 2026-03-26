#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RES_DIR=${1:-"$SCRIPT_DIR/res"}
OUTPUT_FILE=${2:-"$SCRIPT_DIR/read-only-metadata.json"}

if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN=python
else
    echo "python3 or python is required to run $0" >&2
    exit 1
fi

"$PYTHON_BIN" - "$RES_DIR" "$OUTPUT_FILE" <<'PY'
import json
import os
import sys
import zipfile
from pathlib import Path


def normalized_string(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def first_value(obj, *names):
    if not isinstance(obj, dict):
        return None
    for name in names:
        if name in obj:
            return obj[name]
    return None


def author_string(mod):
    for key in ("author", "authors", "author_list"):
        value = first_value(mod, key)
        if value is None:
            continue
        if isinstance(value, list):
            items = [normalized_string(item) for item in value]
            items = [item for item in items if item]
            if items:
                return ", ".join(items)
            continue
        text = normalized_string(value)
        if text:
            return text
    return ""


def dependency_list(value):
    if value is None:
        return []

    items = value if isinstance(value, list) else [value]
    result = []

    for item in items:
        if isinstance(item, (str, int, float, bool)):
            modid = normalized_string(item)
            if modid:
                result.append({"modid": modid, "version": ""})
            continue

        if not isinstance(item, dict):
            continue

        modid = normalized_string(first_value(item, "modid", "id", "name"))
        if not modid:
            continue

        version = normalized_string(first_value(item, "version", "constraint", "range"))
        result.append({"modid": modid, "version": version})

    return result


def metadata_entries(payload, file_name, source_label):
    mods = payload if isinstance(payload, list) else [payload]
    result = []

    for mod in mods:
        if not isinstance(mod, dict):
            print(
                f"Warning: skip invalid mod entry in '{source_label}': expected object.",
                file=sys.stderr,
            )
            continue

        name = normalized_string(first_value(mod, "name", "modid"))
        if not name:
            print(
                f"Warning: skip invalid mod entry in '{source_label}': missing 'name' or 'modid'.",
                file=sys.stderr,
            )
            continue

        result.append(
            {
                "name": name,
                "file_name": file_name,
                "description": normalized_string(first_value(mod, "description")),
                "version": normalized_string(first_value(mod, "version")),
                "author": author_string(mod),
                "url": normalized_string(
                    first_value(mod, "url", "homepage", "repository", "update_json")
                ),
                "dependencies": dependency_list(first_value(mod, "dependencies")),
            }
        )

    return result


def load_json_text(text, file_name, source_label):
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        print(
            f"Warning: skip '{source_label}': unable to parse ModTheSpire.json. {exc}",
            file=sys.stderr,
        )
        return []
    return metadata_entries(payload, file_name, source_label)


def scan_resource_paths(res_dir):
    archive_paths = []
    json_paths = []

    for root, dirs, files in os.walk(res_dir):
        dirs.sort(key=str.lower)
        for file_name in sorted(files, key=str.lower):
            path = Path(root, file_name)
            lower_name = file_name.lower()

            if lower_name.endswith((".jar", ".zip")):
                archive_paths.append(path)

            if lower_name == "modthespire.json":
                json_paths.append(path)

    return archive_paths, json_paths


res_dir = Path(sys.argv[1]).resolve()
output_file = Path(sys.argv[2]).resolve()

if not res_dir.is_dir():
    print(f"Res directory not found: {res_dir}", file=sys.stderr)
    sys.exit(1)

entries = []
source_count = 0
archive_paths, json_paths = scan_resource_paths(res_dir)

for archive_path in archive_paths:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            entry_name = next(
                (
                    name
                    for name in archive.namelist()
                    if name.replace("\\", "/").lower().endswith("/modthespire.json")
                    or name.lower() == "modthespire.json"
                ),
                None,
            )

            if entry_name is None:
                continue

            source_count += 1
            relative_file_name = archive_path.relative_to(res_dir).as_posix()
            text = archive.read(entry_name).decode("utf-8-sig")
            entries.extend(load_json_text(text, relative_file_name, str(archive_path)))
    except Exception as exc:
        print(f"Warning: skip archive '{archive_path}': {exc}", file=sys.stderr)

for json_path in json_paths:
    try:
        source_count += 1
        container_path = json_path.parent
        relative_file_name = container_path.relative_to(res_dir).as_posix()
        if relative_file_name == ".":
            relative_file_name = json_path.name
        text = json_path.read_text(encoding="utf-8-sig")
        entries.extend(load_json_text(text, relative_file_name, str(json_path)))
    except Exception as exc:
        print(f"Warning: skip file '{json_path}': {exc}", file=sys.stderr)

entries.sort(key=lambda item: (item["file_name"], item["name"]))
output_file.parent.mkdir(parents=True, exist_ok=True)
output_file.write_text(
    json.dumps(entries, ensure_ascii=False, indent=4) + "\n",
    encoding="utf-8",
)

entry_word = "entry" if len(entries) == 1 else "entries"
source_word = "source" if source_count == 1 else "sources"
print(
    f"Generated '{output_file}' with {len(entries)} metadata {entry_word} from {source_count} {source_word}."
)
PY
