#!/usr/bin/env python3
"""Check the documentation against the tree.

Five mechanical rules, none of which needs Xcode or the network:

  1. POLICY    — every decision rule in a policy-bearing file (`static func`,
                 and `static var`, which is the same decision with no argument)
                 is named in docs/CODEMAPS/policy.md, in backticks, or exempted
                 here with a reason.
  2. FMEA      — every `Where` cell in docs/FMEA.md resolves to a real file
                 containing the named symbol.
  3. CRUMBS    — every breadcrumb kind the app emits is named in
                 docs/CODEMAPS/diagnostics.md; a crumb whose text the scanner
                 cannot read is allowlisted here, with a reason.
  4. LINKS     — every relative Markdown link outside a fenced block resolves.
  5. TESTS     — every test class, test case and case count the *live* documents
                 cite exists in Tests/. `docs/analysis/` is history and is
                 exempt: those documents name what was true when they were
                 written.

Prose is what is left over, and every prose-only rule is a backlog item.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

POLICY_FILES = [
    "MagicCamera/SpatialScan/DepthSampleConfidence.swift",
    "MagicCamera/SpatialScan/CaptureGuidance.swift",
    "MagicCamera/SpatialScan/CaptureQuality.swift",
    "MagicCamera/SpatialScan/FrameToModelICP.swift",
    "MagicCamera/SpatialScan/KeyframeSharpness.swift",
    "MagicCamera/SpatialScan/ScanDensityMap.swift",
    "MagicCamera/SpatialScan/ScanMetrics.swift",
    "MagicCamera/SpatialScan/ScanRecipe.swift",
    "MagicCamera/SpatialScan/ScanRecorder.swift",
    "MagicCamera/SpatialScan/SurfaceMask.swift",
    "MagicCamera/SpatialScan/PhotoTextureBaker.swift",
    "MagicCamera/SpatialScan/GPUTextureBaker.swift",
    "MagicCamera/SpatialScan/SpatialScanViewModel.swift",
    "MagicCamera/SpatialScan/SpatialScanViewModel+Lattice.swift",
    "MagicCamera/SpatialScan/SpatialScanViewModel+Cleanup.swift",
    "MagicCamera/SpatialScan/MeshPlanarRegularizer.swift",
    "MagicCamera/SpatialScan/PointCloudSegmenter.swift",
    "MagicCamera/SpatialScan/MeshPrimitiveSnap.swift",
    "MagicCamera/SpatialScan/ScanIntelligence.swift",
    "MagicCamera/Core/MemoryPressureMonitor.swift",
]

# Mechanics, not decisions. Adding to this list means writing down why the
# thing is not a decision — which is harder than writing the policy row.
POLICY_EXEMPT = {
    "bake": "the bake entry point; every decision inside it is listed separately",
    "bakeMultiView": "the GPU blend entry point",
    "bakeSurfaceMultiViewGPU": "the surface variant of the same entry point",
    "computeViewCandidates": "geometry plumbing for the view assignment rules",
    "cornerFallback": "texel addressing fallback, no policy",
    "makeFallbackSampler": "sampler construction",
    "paintFallbackTriangles": "the painter the fallback path calls",
    "pageMap": "atlas page bookkeeping",
    "pageSummary": "atlas page bookkeeping, for the breadcrumb",
    "decodeFixed": "fixed-point decode helper",
    "signedDistance": "point-to-plane distance",
    "fitPlane": "least-squares plane fit; the tolerances that use it are the decisions",
    "subset": "index extraction from a cloud, no policy",
    "orthonormalBasis": "basis construction for the revolution fit",
    "isModelAvailable": "availability probe on the on-device model; the fallbacks are `describeScene` and `planAutoFix`",
}

# Crumbs whose text starts with an interpolation, so the scanner cannot read a
# kind off the literal. Each one needs a reason, because an unreadable crumb is
# a crumb `diagnostics.md` cannot be checked against.
CRUMB_DYNAMIC = {
    "MagicCamera/Core/OperationRunner.swift": "`\\(label) start` / `end` — the label is the operation's own name, and every operation is listed in diagnostics.md under `operation`",
}

DOC_ROOTS = ["README.md", "CLAUDE.md", "docs"]

# The documents that make live claims. `docs/analysis/` is deliberately absent:
# those are dated records, and a handoff naming a test that has since been
# renamed is history, not a broken document.
LIVE_DOCS = ["CLAUDE.md", "docs/FMEA.md", "docs/CODEMAPS"]

failures: list[str] = []


def fail(rule: str, message: str) -> None:
    failures.append(f"[{rule}] {message}")


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf8", errors="ignore")


def code_spans(text: str) -> list[str]:
    """Every `backticked` span, stripped. Symbols must be written this way."""
    return [span.strip() for span in re.findall(r"`([^`\n]+)`", text)]


def strip_fences(text: str) -> str:
    """Blank out fenced blocks, keeping line numbers stable."""
    out, fenced = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else line)
    return "\n".join(out)


# ---------------------------------------------------------------- 1. POLICY

# `static func` and `static var` both: a rule with no argument is still a rule,
# and `activeRoomLatticeFloorCell` is one.
DECISION = re.compile(
    r"^\s*(?!.*\bprivate\b)(?:nonisolated\s+)?static (?:func|var) ([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)


def named_symbols(text: str) -> set[str]:
    """Symbols a document names. Only backticked spans count — prose does not,
    and a span carrying a space (a breadcrumb kind, a phrase) is not a symbol.
    `Type.member` names both."""
    names: set[str] = set()
    for span in code_spans(text):
        if " " in span or "(" in span or "/" in span:
            continue
        for part in span.split("."):
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part):
                names.add(part)
    return names


def check_policy() -> None:
    try:
        policy = read("docs/CODEMAPS/policy.md")
    except FileNotFoundError:
        fail("POLICY", "docs/CODEMAPS/policy.md is missing")
        return

    listed = named_symbols(policy)
    declared = re.findall(r"```\n(MagicCamera/[^`]+?)```", policy, re.S)
    declared_files = set()
    for block in declared:
        declared_files.update(line.strip() for line in block.splitlines() if line.strip())
    if not declared_files:
        fail("POLICY", "policy.md no longer carries the fenced list of policy-bearing files")
    for rel in sorted(declared_files - set(POLICY_FILES)):
        fail("POLICY", f"policy.md lists {rel} as policy-bearing, but this script does not scan it")

    for rel in POLICY_FILES:
        path = ROOT / rel
        if not path.exists():
            fail("POLICY", f"policy-bearing file {rel} does not exist")
            continue
        if declared_files and rel not in declared_files:
            fail("POLICY", f"{rel} is scanned but policy.md does not list it as policy-bearing")
        source = path.read_text(encoding="utf8", errors="ignore")
        for match in DECISION.finditer(source):
            name = match.group(1)
            if name in POLICY_EXEMPT or name in listed:
                continue
            fail("POLICY", f"{rel}: `{name}` is a decision rule policy.md does not name")


# ------------------------------------------------------------------ 2. FMEA

def check_fmea() -> None:
    try:
        fmea = read("docs/FMEA.md")
    except FileNotFoundError:
        fail("FMEA", "docs/FMEA.md is missing")
        return

    cells = re.findall(r"`([^`]+)`\s*·\s*`([^`]+)`", fmea)
    if not cells:
        fail("FMEA", "no `path` · `symbol` Where cells found — has the format changed?")
    for rel, symbol in cells:
        path = ROOT / rel
        if not path.exists():
            fail("FMEA", f"Where cell points at {rel}, which does not exist")
            continue
        if symbol not in path.read_text(encoding="utf8", errors="ignore"):
            fail("FMEA", f"{rel} no longer contains `{symbol}`")


# ---------------------------------------------------------------- 3. CRUMBS

CRUMB_CALL = re.compile(r'Diagnostics\.shared\.(?:log|gpu|memory)\(')
CRUMB_LITERAL = re.compile(r'Diagnostics\.shared\.(?:log|gpu|memory)\(\s*"([^"]*)"')


def crumb_kind(literal: str) -> str:
    text = literal.split(" —")[0].split("\\(")[0].strip()
    words = text.split()
    return " ".join(words[:2]) if words else ""


def check_crumbs() -> None:
    try:
        doc = read("docs/CODEMAPS/diagnostics.md")
    except FileNotFoundError:
        fail("CRUMBS", "docs/CODEMAPS/diagnostics.md is missing")
        return

    for swift in sorted((ROOT / "MagicCamera").rglob("*.swift")):
        source = swift.read_text(encoding="utf8", errors="ignore")
        rel = str(swift.relative_to(ROOT))
        readable = 0
        for match in CRUMB_LITERAL.finditer(source):
            kind = crumb_kind(match.group(1))
            if not kind:
                continue           # starts with an interpolation; counted below
            readable += 1
            if f"`{kind}`" in doc:
                continue
            fail("CRUMBS", f"{rel} emits `{kind}`, which diagnostics.md does not name")
        # A crumb the scanner cannot read is a crumb nothing checks. Say so,
        # unless the file is allowlisted above with a reason.
        unreadable = len(CRUMB_CALL.findall(source)) - readable
        if unreadable > 0 and rel not in CRUMB_DYNAMIC:
            fail("CRUMBS", f"{rel} emits {unreadable} crumb(s) whose kind cannot be read from the "
                           f"literal — name the kind first, or allowlist the file with a reason")


# ----------------------------------------------------------------- 4. LINKS

LINK = re.compile(r"\[[^\]]*\]\(([^)#]+?)(?:#[^)]*)?\)")


def markdown_files() -> list[Path]:
    files: list[Path] = []
    for entry in DOC_ROOTS:
        path = ROOT / entry
        if path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
        elif path.exists():
            files.append(path)
    return files


def check_links() -> None:
    for doc in markdown_files():
        body = strip_fences(doc.read_text(encoding="utf8", errors="ignore"))
        for match in LINK.finditer(body):
            target = match.group(1).strip()
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            if not (doc.parent / target).exists():
                fail("LINKS", f"{doc.relative_to(ROOT)} links to {target}, which does not exist")


# ----------------------------------------------------------------- 5. TESTS

SUITE = re.compile(r"\b([A-Z][A-Za-z0-9_]*Tests)\b")
CASE = re.compile(r"\b(test[A-Z][A-Za-z0-9_]*)\b")
COUNT_CLAIM = re.compile(r"`([A-Z][A-Za-z0-9_]*Tests)`[^|\n.]*?\((\d+) cases?\)")


def live_documents() -> list[Path]:
    files: list[Path] = []
    for entry in LIVE_DOCS:
        path = ROOT / entry
        if path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
        elif path.exists():
            files.append(path)
    return files


def check_tests() -> None:
    sources = sorted((ROOT / "Tests").rglob("*.swift"))
    if not sources:
        fail("TESTS", "Tests/ holds no Swift files")
        return
    text = {path: path.read_text(encoding="utf8", errors="ignore") for path in sources}
    classes: dict[str, Path] = {}
    for path, body in text.items():
        for name in re.findall(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", body):
            classes[name] = path
    cases = {name for body in text.values() for name in re.findall(r"\bfunc\s+(test[A-Za-z0-9_]*)", body)}

    for doc in live_documents():
        body = doc.read_text(encoding="utf8", errors="ignore")
        rel = doc.relative_to(ROOT)
        for span in code_spans(body):
            if "/" in span or span.endswith(".swift"):
                continue           # a path, not a symbol — the FMEA rule owns those
            for suite in SUITE.findall(span):
                if suite not in classes:
                    fail("TESTS", f"{rel} cites `{suite}`, which is not a test class "
                                  f"(a file name is not a suite — name the class)")
            for case in CASE.findall(span):
                if case not in cases:
                    fail("TESTS", f"{rel} cites `{case}`, which no test declares")
        for suite, claimed in COUNT_CLAIM.findall(body):
            path = classes.get(suite)
            if path is None:
                continue           # already reported above
            actual = len(re.findall(r"\bfunc\s+test", text[path]))
            if int(claimed) != actual:
                fail("TESTS", f"{rel} says {suite} has {claimed} cases; {path.name} declares {actual}")


def main() -> int:
    check_policy()
    check_fmea()
    check_crumbs()
    check_links()
    check_tests()

    if failures:
        print(f"verify-docs: {len(failures)} problem(s)\n")
        for line in failures:
            print("  " + line)
        print("\nThe documents are part of the change. Fix them in the same commit.")
        return 1

    print("verify-docs: policy index, FMEA targets, breadcrumb kinds, links and test citations all resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
