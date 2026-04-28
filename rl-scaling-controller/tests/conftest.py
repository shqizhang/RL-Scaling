"""Shared pytest fixtures."""
import sys
from pathlib import Path

# Make ``src`` importable when running pytest from the project root without
# installing the package (handy in development).
SRC = Path(__file__).resolve().parent.parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
