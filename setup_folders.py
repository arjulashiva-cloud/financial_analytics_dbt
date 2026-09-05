"""
setup_folders.py
================
Run this ONCE from inside your Financial_Analytics_dbt folder.
Creates every subfolder and placeholder file dbt expects.

Usage:
    python setup_folders.py
"""

import os
from pathlib import Path

ROOT = Path(__file__).parent

DIRS = [
    # dbt model layers
    "models/staging",
    "models/intermediate",
    "models/marts/core",
    "models/marts/risk",
    "models/marts/finance",
    "models/marts/executive",
    # Other dbt dirs
    "snapshots",
    "tests/generic",
    "macros",
    "seeds",
    "analysis",
    # Python data generation scripts
    "data_generation",
    # CI/CD
    ".github/workflows",
    # Docs & assets
    "docs/images",
]

# Placeholder files so git tracks empty dirs + gives VS Code IntelliSense hints
PLACEHOLDER_FILES = {
    "models/staging/.gitkeep":      "",
    "models/intermediate/.gitkeep": "",
    "models/marts/core/.gitkeep":   "",
    "models/marts/risk/.gitkeep":   "",
    "models/marts/finance/.gitkeep":"",
    "models/marts/executive/.gitkeep": "",
    "snapshots/.gitkeep":           "",
    "tests/generic/.gitkeep":       "",
    "macros/.gitkeep":              "",
    "seeds/.gitkeep":               "",
    "analysis/.gitkeep":            "",
    "data_generation/.gitkeep":     "",
    "docs/images/.gitkeep":         "",
}

def create_structure():
    print("Creating folder structure...")
    for d in DIRS:
        path = ROOT / d
        path.mkdir(parents=True, exist_ok=True)
        print(f"  ✓  {d}/")

    print("\nCreating placeholder files...")
    for filepath, content in PLACEHOLDER_FILES.items():
        full = ROOT / filepath
        if not full.exists():
            full.write_text(content)
            print(f"  ✓  {filepath}")

    print("\n✅  Folder structure ready.")
    print("Next steps:")
    print("  1. Copy dbt_project.yml, packages.yml, .gitignore into this folder")
    print("  2. Copy profiles.yml → C:\\Users\\<you>\\.dbt\\profiles.yml")
    print("  3. Run:  dbt deps          (installs dbt_utils + dbt_expectations)")
    print("  4. Run:  dbt debug         (confirms Snowflake connection)")
    print("  5. Run Python data-gen scripts in data_generation/ to load RAW tables")
    print("  6. Run:  dbt run           (once models are in place)")

if __name__ == "__main__":
    create_structure()
