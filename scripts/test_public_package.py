"""Validate the Mooncakes upload archive as a fresh dependency consumer."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = "HYF-ai2006/moondlt"
EXAMPLE = """///|
fn main {
  let result = try {
    let bytes = @dlt.hex_decode("004000000200002000000500626f6f74004500000001000000000000000000000001000000")
    let values = @dlt.decode_wire_parameters(bytes[:], 1, Little)
    guard values is [Structure(None, children)] &&
      children is [TraceInfo(Ascii, "boot"), Numeric(number)] else {
      abort("package must expose the typed nested payload")
    }
    let integer = number.elements[0].integer(width=128, signed=false)
    guard integer.to_string() == "79228162514264337593543950337" else {
      abort("wide integer lost precision")
    }
    children[0] = TraceInfo(Ascii, "ready")
    let result = @dlt.encode_wire_parameters(values, Little)
    guard result.length() == 38 else { abort("edited payload length mismatch") }
    result
  } catch {
    error => abort(error.describe())
  }
  println(@dlt.hex_encode(result[:]))
}
"""
EXPECTED = "0040000002000020000006007265616479004500000001000000000000000000000001000000"


def moon(directory: Path, *args: str) -> str:
    result = subprocess.run(
        ["moon", *args], cwd=directory, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=120,
    )
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def fresh_consumer(root: Path, version: str, registry: bool) -> None:
    app = root / "consumer"
    app.mkdir()
    config = 'name = "local/moondlt_acceptance"\nversion = "0.0.0"\n'
    if not registry:
        config += f'import {{ "{MODULE}@{version}" }}\n'
    (app / "moon.mod").write_text(config, encoding="utf8")
    if registry:
        moon(app, "add", "--no-update", f"{MODULE}@{version}")
    (app / "moon.pkg").write_text(
        f'import {{ "{MODULE}" @dlt }}\npkgtype(kind: "executable")\n', encoding="utf8",
    )
    (app / "main.mbt").write_text(EXAMPLE, encoding="utf8")
    if not registry:
        (root / "moon.work").write_text('members = ["package", "consumer"]\n', encoding="utf8")
    for target in ("wasm", "js"):
        assert moon(app, "run", ".", "--target", target, "--deny-warn").strip() == EXPECTED, target
        print(f"PASS: fresh {'registry' if registry else 'archive'} consumer on {target}", flush=True)


def check_install_document(readme: str, version: str) -> None:
    modules = re.findall(r"(?m)^[ \t]*moon[ \t]+add[ \t]+(\S+)", readme)
    examples = [m for m in modules if m == MODULE or m.startswith(f"{MODULE}@")]
    if not examples:
        raise ValueError(f"README is missing the install command: moon add {MODULE}")
    for example in examples:
        if example not in (MODULE, f"{MODULE}@{version}"):
            raise ValueError(f"README install example {example} does not match {MODULE}@{version}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", action="store_true", help="Require the current version from Mooncakes")
    args = parser.parse_args()
    config = (ROOT / "moon.mod").read_text(encoding="utf8")
    assert re.search(r'^name = "([^"]+)"', config, re.M)[1] == MODULE
    version = re.search(r'^version = "([0-9]+\.[0-9]+\.[0-9]+)"', config, re.M)[1]
    work = ROOT / "work"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="package-acceptance-", dir=work) as directory:
        fresh = Path(directory)
        if not args.registry:
            moon(ROOT, "package")
            archive = ROOT / "_build" / "publish" / f"HYF-ai2006-moondlt-{version}.zip"
            entries = set(subprocess.check_output(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
            ).decode("utf8").rstrip("\0").split("\0"))
            required = {"moon.mod", "moon.pkg", "LICENSE", "README.md", "wire_parameters.mbt", "arxml.mbt"}
            with zipfile.ZipFile(archive) as packed:
                names = [entry.filename for entry in packed.infolist() if not entry.is_dir()]
                assert len(set(names)) == len(names) and required <= set(names) <= entries
                for name in names:
                    path = PurePosixPath(name)
                    assert not path.is_absolute() and ".." not in path.parts
                    assert path.parts[0] not in {".git", "out", "work", "_build", ".mooncakes"}
                    assert packed.read(name) == (ROOT / path).read_bytes(), name
                check_install_document(packed.read("README.md").decode("utf8"), version)
                packed.extractall(fresh / "package")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            print(f"PASS: {archive.name}, {len(names)} files, SHA-256 {digest}", flush=True)
        fresh_consumer(fresh, version, args.registry)


if __name__ == "__main__":
    main()
