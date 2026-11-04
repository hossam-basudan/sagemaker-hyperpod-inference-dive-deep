#!/usr/bin/env bash
# Installs the Bash kernel for Jupyter, so the notebooks/ run in the Code Editor. One shell runs all
# the cells of a notebook, so variables and functions carry over from cell to cell. Safe to rerun.
# Usage: scripts/install-kernel.sh
set -euo pipefail

# --user keeps it in the home directory, which persists; plain install covers environments that refuse --user
python3 -m pip install --user --quiet bash_kernel 2>/dev/null || python3 -m pip install --quiet bash_kernel
python3 -m bash_kernel.install --user >/dev/null
echo "Bash kernel installed. Open a notebook and select the Bash kernel at the top right"
echo "(if it isn't listed, reload the window: Command Palette > Developer: Reload Window)."
