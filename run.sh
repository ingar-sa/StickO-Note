# Capture the user's current directory
ORIGINAL_DIR=$(pwd)

# Get the directory of the current script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$DIR"
mkdir -p build
odin run src/ -out:build/son -o:none -debug -show-timings -keep-executable

cd "$ORIGINAL_DIR"
