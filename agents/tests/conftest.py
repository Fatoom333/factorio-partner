import sys
from pathlib import Path

AGENTS = Path(__file__).resolve().parent.parent
if str(AGENTS) not in sys.path:
    sys.path.insert(0, str(AGENTS))
