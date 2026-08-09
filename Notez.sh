#!/bin/bash

set -e

# ─── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_STEPS=7

# ─── Small helpers: consistent status lines used throughout the script ────────
_ok()    { echo -e "  ${GREEN}✔${NC} $1"; }
_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
_err()   { echo -e "  ${RED}✘${NC} $1"; }
_note()  { echo -e "  ${DIM}$1${NC}"; }
_phase() {
    # $1 = step number, $2 = short description
    echo -e "\n${BLUE}${BOLD}▶ Step $1/${TOTAL_STEPS} — $2${NC}"
}

# ─── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}     LectureMerge — Slide + Transcript Merger${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ─── Small helper: y/n prompt used throughout the rest of the script ───────────
_ask_yn() {
    # $1 = prompt text, $2 = default ("Y" or "N"). Returns 0 (true) for yes.
    local prompt="$1" default="${2:-Y}" ans
    if [[ "$default" == "Y" ]]; then
        read -p "$prompt [Y/n]: " ans
        ans="${ans:-Y}"
    else
        read -p "$prompt [y/N]: " ans
        ans="${ans:-N}"
    fi
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ─── Small helper: preview a slides file and ask for confirmation ──────────────
_confirm_slides_file() {
    local fpath="$1"
    local ftype="${fpath##*.}"
    local fsize
    fsize=$(du -sh "$fpath" 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "  ${CYAN}┌─ Slides file details ──────────────────────────────────┐${NC}"
    printf  "  ${CYAN}│${NC}  Name : %s\n" "$(basename "$fpath")"
    printf  "  ${CYAN}│${NC}  Path : %s\n" "$fpath"
    ftype_upper=$(printf '%s' "$ftype" | tr '[:lower:]' '[:upper:]')
    printf  "  ${CYAN}│${NC}  Type : %s\n" "$ftype_upper"
    printf  "  ${CYAN}│${NC}  Size : %s\n" "${fsize:-unknown}"
    echo -e "  ${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -p "  Use this file? [Y/n]: " _cf_ans
    _cf_ans="${_cf_ans:-Y}"
    [[ "$_cf_ans" =~ ^[Yy]$ ]]
}

# ─── First-time toolchain bootstrap (Xcode CLT → Homebrew → python3 → pip) ─────
# Written for a complete beginner running this on a brand-new Mac: each layer
# is checked in the order it's actually needed (Homebrew needs Xcode CLT;
# most of what this script installs later needs Homebrew), and nothing gets
# installed without an explicit y/n first, since these are systemwide changes
# rather than something local to this project.
_JUST_INSTALLED_BREW=false

# 1) Xcode Command Line Tools — required for Homebrew itself, and for
#    compiling several Python wheels used later.
if ! xcode-select -p &>/dev/null; then
    echo -e "\n${YELLOW}Xcode Command Line Tools are not installed.${NC}"
    echo -e "${YELLOW}  (Required by Homebrew and by several Python packages this script uses.)${NC}"
    if _ask_yn "Install Xcode Command Line Tools now?" "Y"; then
        xcode-select --install
        echo -e "${YELLOW}  A separate installer window has opened — this runs outside of this script.${NC}"
        echo -e "${YELLOW}  Finish that installation, then re-run this script to continue.${NC}"
        exit 0
    else
        echo -e "${RED}  ✘ Xcode Command Line Tools are required to continue. Exiting.${NC}"
        exit 1
    fi
fi

# 2) Homebrew — used to install ffmpeg, tesseract, poppler, LibreOffice, etc.
if ! command -v brew &>/dev/null; then
    echo -e "\n${YELLOW}Homebrew is not installed.${NC}"
    echo -e "${YELLOW}  (Used to install ffmpeg, tesseract, poppler, and LibreOffice.)${NC}"
    if _ask_yn "Install Homebrew now?" "Y"; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Homebrew installs to a different prefix on Apple Silicon vs Intel —
        # pick up whichever one just appeared so `brew` works for the rest of
        # *this* run without requiring a new terminal session.
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        if command -v brew &>/dev/null; then
            _JUST_INSTALLED_BREW=true
            echo -e "${GREEN}  ✔ Homebrew installed.${NC}"
        else
            echo -e "${RED}  ✘ Homebrew install did not complete successfully — some features will be unavailable.${NC}"
        fi
    else
        echo -e "${YELLOW}  Skipping Homebrew — auto-install of ffmpeg/tesseract/LibreOffice will be unavailable.${NC}"
    fi
fi

# 3) python3
if ! command -v python3 &>/dev/null; then
    echo -e "\n${YELLOW}python3 is not installed.${NC}"
    if command -v brew &>/dev/null && _ask_yn "Install python3 via Homebrew now?" "Y"; then
        brew install python3
    else
        echo -e "${RED}  ✘ python3 is required to continue. Install it (e.g. 'brew install python3') and re-run.${NC}"
        exit 1
    fi
fi

# 4) pip
if ! python3 -m pip --version &>/dev/null; then
    echo -e "\n${YELLOW}pip is not available for python3.${NC}"
    if _ask_yn "Bootstrap pip now (python3 -m ensurepip)?" "Y"; then
        python3 -m ensurepip --upgrade || {
            echo -e "${RED}  ✘ Could not bootstrap pip automatically.${NC}"
            if command -v brew &>/dev/null; then
                echo -e "${YELLOW}  Trying 'brew reinstall python3' instead...${NC}"
                brew reinstall python3
            fi
        }
    else
        echo -e "${RED}  ✘ pip is required to continue. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✔ Core toolchain present (Xcode CLT, Homebrew, python3, pip)${NC}"

# ─── Shared tunables ────────────────────────────────────────────────────────────
# Centralized here (instead of hardcoded separately inside each of the several
# independent `python - << PYEOF` heredocs below) so there's exactly one place
# to change them, and every heredoc that needs them reads the same value via
# $WEBCAM_MASK_FRAC / $SCENE_DETECT_THRESHOLD rather than a hardcoded literal
# that can silently drift out of sync between heredocs.
#
# Fraction of width/height blacked out in a corner to ignore a lecturer's
# webcam/face PIP overlay. Typical PIP overlays occupy roughly the bottom-right
# 20-30% of the frame; 0.25 covers the common case. (The alignment step tries
# several corners/edges regardless — see _compare_with_masks — this value only
# affects the *detection* and *screengrab* passes, which mask just the one
# most-likely corner for speed.) Override with WEBCAM_MASK_FRAC=0.3 ./Tollama.sh
WEBCAM_MASK_FRAC="${WEBCAM_MASK_FRAC:-0.25}"
# PySceneDetect's AdaptiveDetector threshold. 3.0 is tuned for film-style hard
# cuts; slide transitions are frequently soft (fades/dissolves) and text-only
# changes are subtle, so 1.0 is far more sensitive and catches more real
# transitions (including near-identical build/reveal slides) at the cost of
# more false positives — which the transient filter and the content-diff/
# merge step downstream are already built to absorb. Override with
# SCENE_DETECT_THRESHOLD=3.0 ./Tollama.sh to go back to the conservative
# film-tuned default, or anywhere in between (e.g. 2.0) if 1.0 over-triggers.
SCENE_DETECT_THRESHOLD="${SCENE_DETECT_THRESHOLD:-1.0}"

# ─── First-time university folder setup ────────────────────────────────────────
# Builds the full Year/Semester/Class/Week tree once, the first time this
# script ever runs on this machine — signalled either by Homebrew having just
# been installed above, or simply by no university being configured yet (a
# user who already had Homebrew installed before trying this script would
# never see the "just installed" case, so this is checked independently
# rather than exclusively gated on it). The chosen root is remembered in
# UNIVERSITY_CONFIG so this wizard never runs again unless that file is
# removed.
UNIVERSITY_CONFIG="$HOME/.lecturemerge_university.conf"

if [ -f "$UNIVERSITY_CONFIG" ]; then
    source "$UNIVERSITY_CONFIG"
fi

if [ -z "${UNIVERSITY_ROOT:-}" ] || [ ! -d "$UNIVERSITY_ROOT" ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  First-time setup: university folder structure${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if $_JUST_INSTALLED_BREW; then
        echo -e "${YELLOW}Homebrew was just installed, so this looks like your first run.${NC}"
    else
        echo -e "${YELLOW}No university folder is configured yet.${NC}"
    fi
    echo -e "${YELLOW}This creates a Year/Semester/Class/Week folder tree on your Desktop so future${NC}"
    echo -e "${YELLOW}runs can browse straight to a lecture's video/slides.${NC}"
    echo ""

    while true; do
        read -p "Enter the name of your university: " UNIVERSITY_NAME
        if [ -z "$UNIVERSITY_NAME" ]; then
            echo -e "${RED}  Please enter a name.${NC}"
            continue
        fi
        UNIVERSITY_ROOT="$HOME/Desktop/$UNIVERSITY_NAME"
        echo ""
        echo -e "  University : ${CYAN}${UNIVERSITY_NAME}${NC}"
        echo -e "  Folder     : ${CYAN}${UNIVERSITY_ROOT}${NC}"
        if _ask_yn "Confirm?" "Y"; then
            break
        fi
        echo ""
    done

    echo -e "\n${YELLOW}Creating university folder structure...${NC}"

    YEARS=("Year1" "Year2" "Year3" "Year4")
    SEMESTERS=("Semester1" "Semester2")
    CLASSES=("Class1" "Class2" "Class3" "Class4")
    WEEKS=({1..13})
    WEEK_FOLDERS=(
        "Lecture_Video" "Lecture_Slides" "Tutorial_Video" "Tutorial_Slides"
        "Readings_PDFs" "Notes" "Tutorial_Questions" "Workshop"
    )
    CLASS_LEVEL_FOLDERS=("Assessments" "Resources")

    for year in "${YEARS[@]}"; do
        for semester in "${SEMESTERS[@]}"; do
            for class in "${CLASSES[@]}"; do
                CLASS_PATH="$UNIVERSITY_ROOT/$year/$semester/$class"
                mkdir -p "$CLASS_PATH"
                for folder in "${CLASS_LEVEL_FOLDERS[@]}"; do
                    mkdir -p "$CLASS_PATH/$folder"
                done
                for week in "${WEEKS[@]}"; do
                    WEEK_PATH="$CLASS_PATH/Week_$week"
                    for folder in "${WEEK_FOLDERS[@]}"; do
                        mkdir -p "$WEEK_PATH/$folder"
                    done
                done
            done
        done
    done

    echo -e "${GREEN}✔ University folder structure created: $UNIVERSITY_ROOT${NC}"

    cat > "$UNIVERSITY_CONFIG" <<CFG_EOF
UNIVERSITY_NAME="$UNIVERSITY_NAME"
UNIVERSITY_ROOT="$UNIVERSITY_ROOT"
CFG_EOF

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  NOTE: the Class1, Class2, Class3, Class4 folders under each${NC}"
    echo -e "${YELLOW}  Year/Semester are placeholders — rename them to your actual${NC}"
    echo -e "${YELLOW}  course names, e.g.:${NC}"
    echo -e "${YELLOW}    mv \"$UNIVERSITY_ROOT/Year1/Semester1/Class1\" \\${NC}"
    echo -e "${YELLOW}       \"$UNIVERSITY_ROOT/Year1/Semester1/Introduction to Biology\"${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# ─── Folder Paths ──────────────────────────────────────────────────────────────
FOLDER_A="$HOME/Desktop/A"
FOLDER_B="$HOME/Desktop/B"
FOLDER_C="$HOME/Desktop/C"
FOLDER_X="$HOME/Desktop/X"

# ─── Check & Create Folders ────────────────────────────────────────────────────
echo -e "\n${YELLOW}Checking folders...${NC}"

for FOLDER in "$FOLDER_A" "$FOLDER_B" "$FOLDER_C" "$FOLDER_X"; do
    LABEL=$(basename "$FOLDER")
    if [ -d "$FOLDER" ]; then
        echo -e "  ${GREEN}✔ Folder $LABEL exists${NC}  ($FOLDER)"
    else
        echo -e "  ${YELLOW}Folder $LABEL does not exist${NC}  ($FOLDER)"
        if _ask_yn "  Create it now?" "Y"; then
            mkdir -p "$FOLDER"
            echo -e "  ${CYAN}✚ Folder $LABEL created${NC}  ($FOLDER)"
        else
            echo -e "  ${RED}✘ Folder $LABEL is required to continue. Exiting.${NC}"
            exit 1
        fi
    fi
done

# ─── Activate venv ─────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Activating virtual environment...${NC}"
export OMP_MAX_ACTIVE_LEVELS=1
export KMP_WARNINGS=0

if [ ! -d "$HOME/.venv" ]; then
    echo -e "${YELLOW}  Virtual environment not found — creating at ~/.venv ...${NC}"
    python3 -m venv "$HOME/.venv"
fi

source "$HOME/.venv/bin/activate"

# ─── Dependencies ──────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Checking dependencies...${NC}"

# 1) Require an active virtual environment
if [ -z "${VIRTUAL_ENV:-}" ]; then
    echo -e "${RED}  ✘ No virtual environment is active.${NC}"
    echo -e "${RED}    Please activate your venv first:  source ~/.venv/bin/activate${NC}"
    exit 1
fi

# 2) Guard against NumPy ≥ 2 (breaks scikit-image / cv2 / stable-ts wheels)
_NUMPY_MAJOR=$(python -c "import numpy; print(numpy.__version__.split('.')[0])" 2>/dev/null || echo "0")
if [ "$_NUMPY_MAJOR" -ge 2 ] 2>/dev/null; then
    echo -e "${RED}  ✘ NumPy ${_NUMPY_MAJOR}.x is installed, which is incompatible with the required stack.${NC}"
    echo -e "${RED}    Remediation:${NC}"
    echo -e "${RED}      pip install 'numpy==1.26.4'${NC}"
    echo -e "${RED}    or recreate a clean venv:${NC}"
    echo -e "${RED}      deactivate && rm -rf ~/.venv && python3 -m venv ~/.venv && source ~/.venv/bin/activate${NC}"
    exit 1
fi

# 3) Auto-uninstall opencv-python-headless if present (conflicts with opencv-python pin)
if python -m pip show opencv-python-headless &>/dev/null; then
    echo -e "${YELLOW}  ⚠ 'opencv-python-headless' is installed and conflicts with our opencv-python pin.${NC}"
    echo -e "${YELLOW}    Auto-uninstalling it now...${NC}"
    python -m pip uninstall -y opencv-python-headless
fi

# 4) Write a temporary constraints file to pin numpy and opencv
_CONSTRAINTS_FILE=$(mktemp /tmp/lm_constraints_XXXXXX.txt)
cat > "$_CONSTRAINTS_FILE" <<CONSTRAINTS_EOF
numpy==1.26.4
opencv-python==4.9.0.80
CONSTRAINTS_EOF

# 5) Helper: pip-install a package only when its import is missing
_pip_install_if_missing() {
    local pkg="$1"
    local import_name="${2:-$1}"
    if ! python -c "import ${import_name}" 2>/dev/null; then
        echo -e "${YELLOW}  Installing ${pkg}...${NC}"
        python -m pip install -q --no-cache-dir -c "$_CONSTRAINTS_FILE" "${pkg}" \
            || echo -e "${YELLOW}  ⚠ Failed to install ${pkg} — some features may be unavailable.${NC}"
    fi
}

# 6) System tools via Homebrew
if ! command -v brew &>/dev/null; then
    echo -e "${YELLOW}  ⚠ Homebrew not found — system tool auto-install will be skipped.${NC}"
    echo -e "${YELLOW}    Install Homebrew from https://brew.sh and re-run for auto-install.${NC}"
else
    for _tool in ffmpeg tesseract ghostscript; do
        if ! command -v "$_tool" &>/dev/null; then
            echo -e "${YELLOW}  Installing ${_tool} via Homebrew...${NC}"
            brew install "$_tool" 2>/dev/null \
                || echo -e "${YELLOW}  ⚠ brew install ${_tool} failed — some features may be unavailable.${NC}"
        fi
    done

    # poppler — provides pdftoppm
    if ! command -v pdftoppm &>/dev/null; then
        echo -e "${YELLOW}  Installing poppler via Homebrew (provides pdftoppm)...${NC}"
        brew install poppler 2>/dev/null \
            || echo -e "${YELLOW}  ⚠ brew install poppler failed.${NC}"
    fi

    # LibreOffice — needed for PPTX → PDF rendering
    if ! command -v libreoffice &>/dev/null && ! command -v soffice &>/dev/null; then
        echo -e "${YELLOW}  Installing LibreOffice via Homebrew...${NC}"
        brew install --cask libreoffice 2>/dev/null \
            || echo -e "${YELLOW}  ⚠ brew install --cask libreoffice failed.${NC}"
    fi
fi

# 7) Ensure LibreOffice is reachable on PATH (symlink .app bundle if needed)
if ! command -v libreoffice &>/dev/null; then
    LO_BIN="/Applications/LibreOffice.app/Contents/MacOS/soffice"
    LINK_DIR="/usr/local/bin"
    if [ -x "$LO_BIN" ]; then
        echo -e "${YELLOW}  LibreOffice found at $LO_BIN — creating symlink in $LINK_DIR...${NC}"
        ln -sf "$LO_BIN" "$LINK_DIR/libreoffice" 2>/dev/null \
            || sudo ln -sf "$LO_BIN" "$LINK_DIR/libreoffice"
        echo -e "${GREEN}  ✔ LibreOffice symlinked to $LINK_DIR/libreoffice.${NC}"
    else
        echo -e "${YELLOW}  ⚠ LibreOffice not found — PPTX→PDF rendering will be unavailable.${NC}"
    fi
fi

# 7b) Ollama setup for local AI enhancements (slide summaries + lecture overview)
echo -e "\n${YELLOW}Checking Ollama (local AI engine)...${NC}"

# Model can be overridden via OLLAMA_MODEL env var. llama3.2:3b is a good default
# for Apple Silicon M1 (8GB+ RAM) — small, fast under Metal, no GPU offload needed.
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
OLLAMA_AVAILABLE=false

if ! command -v ollama &>/dev/null; then
    echo -e "${YELLOW}  ⚠ Ollama not found on PATH — AI enhancements will be unavailable.${NC}"
    echo -e "${YELLOW}    Install from https://ollama.com or 'brew install ollama' and re-run.${NC}"
else
    # Make sure the Ollama server is running; start it in the background if not.
    if ! curl -s -m 2 http://localhost:11434/api/tags &>/dev/null; then
        echo -e "${YELLOW}  Ollama server not running — starting 'ollama serve' in the background...${NC}"
        (nohup ollama serve >/tmp/ollama_serve.log 2>&1 &)
        for _i in {1..15}; do
            sleep 1
            curl -s -m 2 http://localhost:11434/api/tags &>/dev/null && break
        done
    fi

    if curl -s -m 2 http://localhost:11434/api/tags &>/dev/null; then
        echo -e "${GREEN}  ✔ Ollama server is running.${NC}"
        if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$OLLAMA_MODEL"; then
            echo -e "${GREEN}  ✔ Model '${OLLAMA_MODEL}' already available.${NC}"
            OLLAMA_AVAILABLE=true
        else
            echo -e "${YELLOW}  Pulling model '${OLLAMA_MODEL}' (one-time download)...${NC}"
            if ollama pull "$OLLAMA_MODEL"; then
                echo -e "${GREEN}  ✔ Model '${OLLAMA_MODEL}' pulled.${NC}"
                OLLAMA_AVAILABLE=true
            else
                echo -e "${YELLOW}  ⚠ Failed to pull '${OLLAMA_MODEL}' — AI enhancements will be unavailable.${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}  ⚠ Could not reach the Ollama server — AI enhancements will be unavailable.${NC}"
    fi
fi

# 8) Python packages (pinned core stack first)
_pip_install_if_missing "numpy==1.26.4"           "numpy"
_pip_install_if_missing "opencv-python==4.9.0.80" "cv2"

# Audio / transcription
_pip_install_if_missing "openai-whisper" "whisper"
_pip_install_if_missing "stable-ts"      "stable_whisper"

# PDF / slide handling
_pip_install_if_missing "pymupdf"      "fitz"
_pip_install_if_missing "python-pptx"  "pptx"
_pip_install_if_missing "reportlab"    "reportlab"
_pip_install_if_missing "Pillow"       "PIL"
_pip_install_if_missing "pdfplumber"   "pdfplumber"

# Scene detection & image comparison
_pip_install_if_missing "scenedetect[opencv]" "scenedetect"
_pip_install_if_missing "scikit-image"        "skimage"

# Exact, anti-aliasing-aware pixel-diff comparison — a *different* kind of
# signal from SSIM/NCC (see _compare_with_masks for why both are used together).
_pip_install_if_missing "pixelmatch" "pixelmatch"

# OCR — lets alignment fall back to *text on screen* to break ties between
# visually near-identical slides (e.g. build/reveal animations, template
# slides that differ by only a number or a highlighted bullet).
_pip_install_if_missing "pytesseract" "pytesseract"

# 9) Verify cv2.VideoCapture is available (headless build check)
if ! python -c "import cv2; assert hasattr(cv2, 'VideoCapture')" 2>/dev/null; then
    echo -e "${YELLOW}  ⚠ cv2.VideoCapture not found — reinstalling opencv-python under constraints...${NC}"
    python -m pip uninstall -y opencv-python opencv-python-headless opencv-contrib-python \
        || true
    python -m pip install -q --no-cache-dir -c "$_CONSTRAINTS_FILE" "opencv-python==4.9.0.80"
    if ! python -c "import cv2; assert hasattr(cv2, 'VideoCapture')" 2>/dev/null; then
        echo -e "${RED}  ✘ cv2.VideoCapture still missing after reinstall.${NC}"
        rm -f "$_CONSTRAINTS_FILE"
        exit 1
    fi
    echo -e "${GREEN}  ✔ cv2.VideoCapture available after reinstall.${NC}"
fi

# 10) Clean up temp constraints file
rm -f "$_CONSTRAINTS_FILE"

echo -e "${GREEN}✔ All dependencies satisfied${NC}"

# ─── Browse university folders (offered when Desktop/A or Desktop/X are empty) ─
# Rather than hard-failing the moment the flat drop folders are empty, check
# whether a university folder structure is available and offer to navigate it
# instead — picking a Year/Semester/Class/Week finds the video and slides for
# that lecture (or tutorial) in one pass, and routes the final output
# directly into that week's own "Notes" folder instead of the flat
# ~/Desktop/C.
_BROWSE_MODE_USED=false

_MP4_PRECHECK=$(ls "$FOLDER_A"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
shopt -s nullglob
_SLIDES_PRECHECK_PPT=( "$FOLDER_X"/*.pptx "$FOLDER_X"/*.ppt )
_SLIDES_PRECHECK_PDF=( "$FOLDER_X"/*.pdf )
_SLIDES_PRECHECK_COUNT=$(( ${#_SLIDES_PRECHECK_PPT[@]} + ${#_SLIDES_PRECHECK_PDF[@]} ))
shopt -u nullglob

if [ "$_MP4_PRECHECK" -eq 0 ] || [ "$_SLIDES_PRECHECK_COUNT" -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}No video found in ~/Desktop/A and/or no slides found in ~/Desktop/X.${NC}"
    if [ -n "${UNIVERSITY_ROOT:-}" ] && [ -d "$UNIVERSITY_ROOT" ] \
        && _ask_yn "Browse your university folders (${UNIVERSITY_ROOT}) instead?" "Y"; then
        _BROWSE_MODE_USED=true

        # Lists the subfolders of $1 (optionally filtered to those matching
        # glob pattern $2, e.g. "Week_*") and lets the user pick one by
        # number; echoes the chosen folder NAME (not full path) to stdout.
        # Auto-picks with no prompt when there's exactly one match.
        _pick_subfolder() {
            local dir="$1" pattern="${2:-*}"
            local -a opts=()
            local d
            shopt -s nullglob
            for d in "$dir"/$pattern/; do
                [ -d "$d" ] && opts+=("$(basename "$d")")
            done
            shopt -u nullglob
            if [ ${#opts[@]} -eq 0 ]; then
                echo ""
                return
            fi
            if [ ${#opts[@]} -eq 1 ]; then
                echo "${opts[0]}"
                return
            fi
            echo -e "${CYAN}  Choose:${NC}" >&2
            local i=1
            for o in "${opts[@]}"; do
                echo "    $i) $o" >&2
                ((i++))
            done
            local choice
            read -p "  Enter number: " choice >&2
            echo "${opts[$((choice-1))]}"
        }

        echo -e "\n${CYAN}University: $UNIVERSITY_ROOT${NC}"
        _b_year=$(_pick_subfolder "$UNIVERSITY_ROOT" "Year*")
        [ -z "$_b_year" ] && { echo -e "${RED}  ✘ No Year folders found under $UNIVERSITY_ROOT.${NC}"; exit 1; }
        echo -e "  Year: ${GREEN}${_b_year}${NC}"

        _b_sem=$(_pick_subfolder "$UNIVERSITY_ROOT/$_b_year" "Semester*")
        [ -z "$_b_sem" ] && { echo -e "${RED}  ✘ No Semester folders found under $_b_year.${NC}"; exit 1; }
        echo -e "  Semester: ${GREEN}${_b_sem}${NC}"

        _b_class=$(_pick_subfolder "$UNIVERSITY_ROOT/$_b_year/$_b_sem")
        [ -z "$_b_class" ] && { echo -e "${RED}  ✘ No Class folders found under $_b_sem.${NC}"; exit 1; }
        echo -e "  Class: ${GREEN}${_b_class}${NC}"

        _B_CLASS_DIR="$UNIVERSITY_ROOT/$_b_year/$_b_sem/$_b_class"
        _b_week=$(_pick_subfolder "$_B_CLASS_DIR" "Week_*")
        [ -z "$_b_week" ] && { echo -e "${RED}  ✘ No Week folders found under $_b_class.${NC}"; exit 1; }
        echo -e "  Week: ${GREEN}${_b_week}${NC}"

        _B_WEEK_DIR="$_B_CLASS_DIR/$_b_week"

        # ── Lecture or Tutorial? ──
        # Tollama needs to work against either pair of folders — a lecture
        # recording or a tutorial recording, each with its own video/slides
        # pair — so ask which this run is for rather than assuming lecture.
        echo -e "${CYAN}  Content type:${NC}"
        echo "    1) Lecture"
        echo "    2) Tutorial"
        read -p "  Enter choice (1-2) [1]: " _b_content_choice
        _b_content_choice="${_b_content_choice:-1}"
        if [ "$_b_content_choice" == "2" ]; then
            _B_CONTENT_LABEL="Tutorial"
        else
            _B_CONTENT_LABEL="Lecture"
        fi

        # Tolerate either singular ("Lecture_Video") or plural
        # ("Lecture_Videos") folder naming — the wizard creates the singular
        # form, but folders get renamed/recreated by hand often enough that
        # this shouldn't be a hard requirement.
        _B_VIDEO_DIR="$_B_WEEK_DIR/${_B_CONTENT_LABEL}_Video"
        [ ! -d "$_B_VIDEO_DIR" ] && [ -d "$_B_WEEK_DIR/${_B_CONTENT_LABEL}_Videos" ] \
            && _B_VIDEO_DIR="$_B_WEEK_DIR/${_B_CONTENT_LABEL}_Videos"
        _B_SLIDES_DIR="$_B_WEEK_DIR/${_B_CONTENT_LABEL}_Slides"

        # ── Video, from this week's <Content>_Video(s) folder ──
        shopt -s nullglob
        _b_mp4s=( "$_B_VIDEO_DIR"/*.mp4 )
        shopt -u nullglob
        if [ ${#_b_mp4s[@]} -eq 0 ]; then
            echo -e "${RED}  ✘ No .mp4 found in $_B_VIDEO_DIR.${NC}"
            echo -e "${YELLOW}  Add the ${_B_CONTENT_LABEL,,} video there and re-run.${NC}"
            exit 1
        elif [ ${#_b_mp4s[@]} -eq 1 ]; then
            INPUT_VIDEO="${_b_mp4s[0]}"
        else
            echo -e "${CYAN}  Multiple videos found:${NC}"
            i=1
            declare -a _B_MP4_LIST
            for f in "${_b_mp4s[@]}"; do
                echo -e "    $i) $(basename "$f")"
                _B_MP4_LIST[$i]="$f"
                ((i++))
            done
            read -p "  Enter the number of the file to use: " _b_mp4_choice
            INPUT_VIDEO="${_B_MP4_LIST[$_b_mp4_choice]}"
        fi
        filename=$(basename "$INPUT_VIDEO" .mp4)
        echo -e "${GREEN}  ✔ Video: $(basename "$INPUT_VIDEO")${NC}"

        # ── Slides, from this week's <Content>_Slides folder (optional —
        # falls back to screengrabs-only if this week has none) ──
        shopt -s nullglob
        _b_ppts=( "$_B_SLIDES_DIR"/*.pptx "$_B_SLIDES_DIR"/*.ppt )
        _b_pdfs=( "$_B_SLIDES_DIR"/*.pdf )
        shopt -u nullglob
        _b_slides_all=( "${_b_ppts[@]}" "${_b_pdfs[@]}" )
        if [ ${#_b_slides_all[@]} -eq 0 ]; then
            echo -e "${YELLOW}  ⚠ No slides found in $_B_SLIDES_DIR.${NC}"
            SLIDE_MODE="screengrabs"
            SLIDES_FILE=""
            SLIDES_TYPE="screengrabs"
        else
            if [ ${#_b_slides_all[@]} -eq 1 ]; then
                SLIDES_FILE="${_b_slides_all[0]}"
            else
                echo -e "${CYAN}  Multiple slides files found:${NC}"
                i=1
                declare -a _B_SLIDES_LIST
                for f in "${_b_slides_all[@]}"; do
                    echo -e "    $i) $(basename "$f")"
                    _B_SLIDES_LIST[$i]="$f"
                    ((i++))
                done
                read -p "  Enter the number of the slides file to use: " _b_slides_choice
                SLIDES_FILE="${_B_SLIDES_LIST[$_b_slides_choice]}"
            fi
            SLIDES_TYPE="${SLIDES_FILE##*.}"
            SLIDE_MODE="slides"
            echo -e "${GREEN}  ✔ Slides: $(basename "$SLIDES_FILE")${NC}"
            if ! _confirm_slides_file "$SLIDES_FILE"; then
                echo -e "${YELLOW}  Please re-run and choose the correct slides file.${NC}"
                exit 1
            fi
        fi

        # ── Route output directly into this week's own "Notes" folder ──
        # Notes already exists as a sibling of Lecture_Video/Lecture_Slides/
        # Tutorial_Video/Tutorial_Slides inside every Week_N folder (it's one
        # of the WEEK_FOLDERS the university wizard creates), so the final
        # .txt/.pdf/.pptx output goes straight there rather than into a
        # separate, parallel folder tree.
        RELATIVE_WEEK_PATH="$_b_year/$_b_sem/$_b_class/$_b_week"
        FOLDER_C="$_B_WEEK_DIR/Notes"
        mkdir -p "$FOLDER_C"
        echo -e "${GREEN}  ✔ Output will be saved to: $FOLDER_C${NC}"
    else
        echo -e "${YELLOW}  Continuing with the flat ~/Desktop/A and ~/Desktop/X folders.${NC}"
    fi
fi

# ─── Check MP4 in Folder A ─────────────────────────────────────────────────────
if ! $_BROWSE_MODE_USED; then
echo -e "\n${YELLOW}Checking for MP4 in ~/Desktop/A...${NC}"

MP4_COUNT=$(ls "$FOLDER_A"/*.mp4 2>/dev/null | wc -l | tr -d ' ')

if [ "$MP4_COUNT" -eq 0 ]; then
    echo -e "${RED}  ✘ No .mp4 files found in $FOLDER_A.${NC}"
    echo -e "${YELLOW}  Please add your .mp4 file to ~/Desktop/A/ and re-run the script.${NC}"
    exit 1
elif [ "$MP4_COUNT" -eq 1 ]; then
    DETECTED_MP4=$(ls "$FOLDER_A"/*.mp4 | head -n 1)
    DETECTED_NAME=$(basename "$DETECTED_MP4" .mp4)
    echo -e "${GREEN}  ✔ Found: ${DETECTED_NAME}.mp4${NC}"
    echo ""
    read -p "  Use ${DETECTED_NAME}.mp4? [Y/n]: " use_detected
    use_detected="${use_detected:-Y}"
    if [[ "$use_detected" =~ ^[Yy]$ ]]; then
        filename="$DETECTED_NAME"
    else
        read -p "  Enter the MP4 filename (without extension): " filename
    fi
else
    echo -e "${CYAN}  Multiple .mp4 files found in $FOLDER_A:${NC}"
    i=1
    declare -a MP4_LIST
    for f in "$FOLDER_A"/*.mp4; do
        NAME=$(basename "$f" .mp4)
        echo -e "    $i) $NAME"
        MP4_LIST[$i]="$NAME"
        ((i++))
    done
    echo ""
    read -p "  Enter the number of the file to use: " mp4_choice
    filename="${MP4_LIST[$mp4_choice]}"
    echo -e "${GREEN}  Selected: ${filename}.mp4${NC}"
fi

INPUT_VIDEO="$FOLDER_A/${filename}.mp4"

if [ ! -f "$INPUT_VIDEO" ]; then
    echo -e "${RED}  ✘ $INPUT_VIDEO not found. Please check the filename.${NC}"
    exit 1
fi

if [ ! -s "$INPUT_VIDEO" ]; then
    echo -e "${RED}  ✘ $INPUT_VIDEO is empty.${NC}"
    exit 1
fi
fi  # end: if ! $_BROWSE_MODE_USED (MP4 check)

# ─── Select Processing Mode ────────────────────────────────────────────────────
if ! $_BROWSE_MODE_USED; then
echo ""
echo -e "${BLUE}Select processing mode:${NC}"
echo "  1) Use lecture slides  (PPTX / PDF from ~/Desktop/X)"
echo "  2) Screen-grabs only   (no slides file required)"
echo ""
read -p "Enter choice (1-2) [1]: " mode_choice
mode_choice="${mode_choice:-1}"

case "$mode_choice" in
    2) SLIDE_MODE="screengrabs" ;;
    *) SLIDE_MODE="slides" ;;
esac

if [[ "$SLIDE_MODE" == "screengrabs" ]]; then
    echo -e "${CYAN}  Mode: Screen-grabs only — Folder X will not be used.${NC}"
    SLIDES_FILE=""
    SLIDES_TYPE="screengrabs"
else
    echo -e "${GREEN}  Mode: Lecture slides (PPTX / PDF from ~/Desktop/X)${NC}"
fi
fi  # end: if ! $_BROWSE_MODE_USED (processing mode)

# ─── Check Slides in Folder X ──────────────────────────────────────────────────
if ! $_BROWSE_MODE_USED && [[ "$SLIDE_MODE" == "slides" ]]; then

echo -e "\n${YELLOW}Checking for slides in ~/Desktop/X...${NC}"

SLIDES_FILE=""
SLIDES_TYPE=""

shopt -s nullglob
ppt_files=( "$FOLDER_X"/*.pptx "$FOLDER_X"/*.ppt )
pdf_files=( "$FOLDER_X"/*.pdf )
SLIDES_COUNT=$(( ${#ppt_files[@]} + ${#pdf_files[@]} ))

if (( SLIDES_COUNT == 0 )); then
    echo -e "${RED}  ✘ No .pptx, .ppt, or .pdf files found in $FOLDER_X.${NC}"
    echo -e "${YELLOW}  Please add your slides file to ~/Desktop/X/ and re-run.${NC}"
    exit 1
elif (( ${#ppt_files[@]} > 0 )); then
    if (( ${#ppt_files[@]} == 1 && ${#pdf_files[@]} == 0 )); then
        SLIDES_FILE="${ppt_files[0]}"
        SLIDES_TYPE="${SLIDES_FILE##*.}"
        echo -e "${GREEN}  ✔ Found: $(basename "$SLIDES_FILE")${NC}"
        if ! _confirm_slides_file "$SLIDES_FILE"; then
            echo -e "${YELLOW}  Please place the correct slides file in ~/Desktop/X/ and re-run.${NC}"
            exit 1
        fi
    else
        echo -e "${CYAN}  Slides files found in $FOLDER_X:${NC}"
        i=1
        declare -a SLIDES_LIST
        declare -a SLIDES_TYPE_LIST
        for f in "${ppt_files[@]}" "${pdf_files[@]}"; do
            echo -e "    $i) $(basename "$f")"
            SLIDES_LIST[$i]="$f"
            SLIDES_TYPE_LIST[$i]="${f##*.}"
            ((i++))
        done
        echo ""
        read -p "  Enter the number of the slides file to use: " slides_choice
        SLIDES_FILE="${SLIDES_LIST[$slides_choice]}"
        SLIDES_TYPE="${SLIDES_TYPE_LIST[$slides_choice]}"
        echo -e "${GREEN}  Selected: $(basename "$SLIDES_FILE")${NC}"
        if ! _confirm_slides_file "$SLIDES_FILE"; then
            echo -e "${YELLOW}  Please place the correct slides file in ~/Desktop/X/ and re-run.${NC}"
            exit 1
        fi
    fi
else
    if (( ${#pdf_files[@]} == 1 )); then
        SLIDES_FILE="${pdf_files[0]}"
        SLIDES_TYPE="pdf"
        echo -e "${GREEN}  ✔ Found: $(basename "$SLIDES_FILE")${NC}"
        if ! _confirm_slides_file "$SLIDES_FILE"; then
            echo -e "${YELLOW}  Please place the correct slides file in ~/Desktop/X/ and re-run.${NC}"
            exit 1
        fi
    else
        echo -e "${CYAN}  Slides files found in $FOLDER_X:${NC}"
        i=1
        declare -a SLIDES_LIST
        for f in "${pdf_files[@]}"; do
            echo -e "    $i) $(basename "$f")"
            SLIDES_LIST[$i]="$f"
            ((i++))
        done
        echo ""
        read -p "  Enter the number of the slides file to use: " slides_choice
        SLIDES_FILE="${SLIDES_LIST[$slides_choice]}"
        SLIDES_TYPE="pdf"
        echo -e "${GREEN}  Selected: $(basename "$SLIDES_FILE")${NC}"
        if ! _confirm_slides_file "$SLIDES_FILE"; then
            echo -e "${YELLOW}  Please place the correct slides file in ~/Desktop/X/ and re-run.${NC}"
            exit 1
        fi
    fi
fi

shopt -u nullglob

if [[ -z "$SLIDES_FILE" || -z "$SLIDES_TYPE" ]]; then
    echo -e "${RED}  ✘ Failed to select slides file from $FOLDER_X.${NC}"
    exit 1
fi

# ─── Convert legacy .ppt → .pptx via LibreOffice ──────────────────────────────
if [[ "$SLIDES_TYPE" == "ppt" ]]; then
    echo -e "${YELLOW}  Legacy .ppt file detected — converting to .pptx via LibreOffice...${NC}"
    LO_BIN=$(command -v libreoffice || command -v soffice || echo "/Applications/LibreOffice.app/Contents/MacOS/soffice")
    PPT_CONVERT_DIR=$(mktemp -d)
    if "$LO_BIN" --headless --convert-to pptx --outdir "$PPT_CONVERT_DIR" "$SLIDES_FILE" 2>/dev/null; then
        CONVERTED_PPTX=$(ls "$PPT_CONVERT_DIR"/*.pptx 2>/dev/null | head -n 1)
        if [ -f "$CONVERTED_PPTX" ]; then
            DEST_PPTX="$FOLDER_X/$(basename "$SLIDES_FILE" .ppt).pptx"
            cp "$CONVERTED_PPTX" "$DEST_PPTX"
            rm -rf "$PPT_CONVERT_DIR"
            SLIDES_FILE="$DEST_PPTX"
            SLIDES_TYPE="pptx"
            echo -e "${GREEN}  ✔ Converted to: $(basename "$SLIDES_FILE")${NC}"
        else
            rm -rf "$PPT_CONVERT_DIR"
            echo -e "${RED}  ✘ Conversion produced no output. Please convert the .ppt manually.${NC}"
            exit 1
        fi
    else
        rm -rf "$PPT_CONVERT_DIR"
        echo -e "${RED}  ✘ LibreOffice conversion failed. Please convert the .ppt manually.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}  Slides type: ${SLIDES_TYPE}${NC}"

# ─── Validate PPTX (if applicable) ────────────────────────────────────────────
if [[ "$SLIDES_TYPE" == "pptx" ]]; then
    echo -e "${YELLOW}  Validating PPTX file...${NC}"

    _validate_pptx() {
        PPTX_VALIDATE_PATH="$1" python -c "
import sys, os
try:
    from pptx import Presentation
    Presentation(os.environ['PPTX_VALIDATE_PATH'])
    sys.exit(0)
except Exception as e:
    print(f'  ✘ PPTX validation error: {e}', flush=True)
    sys.exit(2)
" 2>&1
        return $?
    }

    _attempt_pptx_repair() {
        local src="$1"
        local lo_bin
        lo_bin=$(command -v libreoffice || command -v soffice || echo "/Applications/LibreOffice.app/Contents/MacOS/soffice")
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if "$lo_bin" --headless --convert-to pptx --outdir "$tmp_dir" "$src" 2>/dev/null; then
            local repaired
            repaired=$(ls "$tmp_dir"/*.pptx 2>/dev/null | head -n 1)
            if [ -f "$repaired" ]; then
                cp "$repaired" "$src"
                rm -rf "$tmp_dir"
                echo -e "${GREEN}  ✔ PPTX repaired via LibreOffice.${NC}"
                return 0
            fi
        fi
        rm -rf "$tmp_dir"
        return 1
    }

    _validate_pptx "$SLIDES_FILE"
    PPTX_VALID=$?

    if [ "$PPTX_VALID" -eq 2 ]; then
        echo ""
        read -p "  Attempt LibreOffice repair? [Y/n]: " repair_yn
        repair_yn="${repair_yn:-Y}"
        if [[ "$repair_yn" =~ ^[Yy]$ ]]; then
            if _attempt_pptx_repair "$SLIDES_FILE"; then
                _validate_pptx "$SLIDES_FILE"
                PPTX_VALID=$?
                [ "$PPTX_VALID" -ne 0 ] && PPTX_VALID=1
            else
                PPTX_VALID=1
            fi
        else
            PPTX_VALID=1
        fi

        if [ "$PPTX_VALID" -ne 0 ]; then
            echo ""
            echo -e "${YELLOW}  Options:${NC}"
            echo "    1) Convert to PDF and use that as a fallback"
            echo "    2) Exit"
            read -p "  Enter choice (1-2): " fallback_choice
            fallback_choice="${fallback_choice:-2}"
            if [ "$fallback_choice" = "1" ]; then
                lo_bin=$(command -v libreoffice || command -v soffice || echo "/Applications/LibreOffice.app/Contents/MacOS/soffice")
                pdf_dir=$(mktemp -d)
                if "$lo_bin" --headless --convert-to pdf --outdir "$pdf_dir" "$SLIDES_FILE" 2>/dev/null; then
                    PDF_FILE=$(ls "$pdf_dir"/*.pdf 2>/dev/null | head -n 1)
                    if [ -f "$PDF_FILE" ]; then
                        FALLBACK_PDF="$FOLDER_X/$(basename "$SLIDES_FILE" .pptx).pdf"
                        cp "$PDF_FILE" "$FALLBACK_PDF"
                        rm -rf "$pdf_dir"
                        SLIDES_FILE="$FALLBACK_PDF"
                        SLIDES_TYPE="pdf"
                        echo -e "${GREEN}  ✔ Using PDF fallback: $(basename "$SLIDES_FILE")${NC}"
                    else
                        rm -rf "$pdf_dir"
                        echo -e "${RED}  ✘ PDF conversion failed. Exiting.${NC}"
                        exit 1
                    fi
                else
                    rm -rf "$pdf_dir"
                    echo -e "${RED}  ✘ PDF conversion failed. Exiting.${NC}"
                    exit 1
                fi
            else
                exit 1
            fi
        fi
    elif [ "$PPTX_VALID" -eq 1 ]; then
        echo -e "${YELLOW}  ⚠ Warning: could not fully validate PPTX file. Proceeding anyway...${NC}"
    else
        echo -e "${GREEN}  ✔ Slides file validated successfully.${NC}"
    fi
else
    echo -e "${GREEN}  ✔ Slides file present and non-empty.${NC}"
fi

fi  # end SLIDE_MODE == "slides"

# ─── AI Enhancement Option (Ollama) ────────────────────────────────────────────
AI_ENABLED=false
if [[ "$OLLAMA_AVAILABLE" == true ]]; then
    echo ""
    echo -e "${BLUE}AI enhancements available (local, via Ollama — model: ${OLLAMA_MODEL})${NC}"
    echo -e "  Adds a 1-2 sentence AI takeaway per slide and a short lecture overview."
    echo -e "  Runs entirely on-device; nothing leaves your Mac."
    read -p "  Enable AI enhancements? [Y/n]: " ai_yn
    ai_yn="${ai_yn:-Y}"
    if [[ "$ai_yn" =~ ^[Yy]$ ]]; then
        AI_ENABLED=true
        echo -e "${GREEN}  ✔ AI enhancements enabled.${NC}"
    else
        echo -e "${CYAN}  AI enhancements skipped.${NC}"
    fi
fi

# ─── Output Format Selection ───────────────────────────────────────────────────
echo ""
echo -e "${BLUE}Select output format:${NC}"
echo "  1) .txt"
echo "  2) .pdf"
if [[ "$SLIDE_MODE" == "slides" ]]; then
    echo "  3) .pptx"
    echo "  4) All three"
else
    echo -e "  3) .pptx  ${YELLOW}(not available in screen-grabs only mode — will be skipped)${NC}"
    echo "  4) All three  (PPTX will be skipped)"
fi
read -p "Enter choice (1-4): " format_choice

# ─── Summary Confirmation ──────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Ready to process:${NC}"
echo -e "  📹 Video  : $INPUT_VIDEO"
if [[ "$SLIDE_MODE" == "slides" ]]; then
    echo -e "  📑 Slides : $SLIDES_FILE  (${SLIDES_TYPE})"
else
    echo -e "  📷 Mode   : Screen-grabs only (no lecture slides)"
fi
_fmt_label="TXT"
case "$format_choice" in
    1) _fmt_label="TXT" ;;
    2) _fmt_label="PDF" ;;
    3) _fmt_label="PPTX" ;;
    4) _fmt_label="TXT + PDF + PPTX" ;;
esac
echo -e "  📄 Output : ${_fmt_label}"
if [[ "$AI_ENABLED" == true ]]; then
    echo -e "  🤖 AI     : Enabled  (Ollama model: ${OLLAMA_MODEL})"
else
    echo -e "  🤖 AI     : Disabled"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "  Proceed? [Y/n]: " proceed_yn
proceed_yn="${proceed_yn:-Y}"
if [[ ! "$proceed_yn" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}  Aborted.${NC}"
    exit 0
fi

OUTPUT_WAV="$FOLDER_B/${filename}_16k_mono.wav"

# ─── Step 1: Convert MP4 → WAV ─────────────────────────────────────────────────
_phase 1 "Convert video to audio (MP4 → 16 kHz mono WAV)"

if [ -f "$OUTPUT_WAV" ] && [ -s "$OUTPUT_WAV" ]; then
    echo -e "${CYAN}  WAV already exists — skipping conversion.${NC}"
else
    ffmpeg -y -i "$INPUT_VIDEO" -ac 1 -ar 16000 -vn -threads 0 "$OUTPUT_WAV"
    echo -e "${GREEN}  WAV saved to $OUTPUT_WAV${NC}"
fi

# ─── Step 2: Transcribe with Whisper / stable-ts ───────────────────────────────
_phase 2 "Transcribe audio (Whisper / stable-ts)"

_SEG_JSON="$FOLDER_C/${filename}_segments.json"
_TRANSCRIPT_TXT="$FOLDER_C/${filename}_transcript.txt"

if [ -f "$_SEG_JSON" ] && [ -s "$_SEG_JSON" ]; then
    echo -e "${CYAN}  Segments JSON already exists — skipping transcription.${NC}"
else
python - << PYEOF
import json, os, sys

# ─── Console styling (auto-disables when output isn't a terminal, e.g. piped to a log) ──
_TTY = sys.stdout.isatty()
def _c(code): return code if _TTY else ""
_GRN, _YLW, _RED, _BLU, _CYN, _DIM, _BLD, _RST = (
    _c("\033[0;32m"), _c("\033[1;33m"), _c("\033[0;31m"), _c("\033[0;34m"),
    _c("\033[0;36m"), _c("\033[2m"), _c("\033[1m"), _c("\033[0m"),
)
def _ok(msg):   print(f"  {_GRN}✔{_RST} {msg}", flush=True)
def _warn(msg): print(f"  {_YLW}⚠{_RST} {msg}", flush=True)
def _err(msg):  print(f"  {_RED}✘{_RST} {msg}", flush=True)
def _ai(msg):   print(f"  {_CYN}🤖{_RST} {msg}", flush=True)
def _note(msg): print(f"  {_DIM}{msg}{_RST}", flush=True)
def _step(msg): print(f"\n  {_BLU}{_BLD}{msg}{_RST}", flush=True)

audio_file = "$OUTPUT_WAV"
output_dir = "$FOLDER_C"
filename   = "$filename"
# Model size can be overridden via WHISPER_MODEL env var.
# Choices: tiny, base, small (default), medium, large.
# Larger models are more accurate but slower and require more RAM.
model_size = os.environ.get("WHISPER_MODEL", "small")

try:
    import stable_whisper
    print("  Loading stable-ts model...", flush=True)
    model  = stable_whisper.load_model(model_size)
    print("  Transcribing — live output below:\n", flush=True)
    result = model.transcribe(audio_file, language="en", fp16=False, verbose=True, word_timestamps=False)
    result = result.to_dict()
    _note("[Step 2] Using stable-ts for word-level timestamps")
except ImportError:
    import whisper
    print("  Loading Whisper model...", flush=True)
    model  = whisper.load_model(model_size)
    print("  Transcribing — live output below:\n", flush=True)
    result = model.transcribe(audio_file, language="en", fp16=False, verbose=True)
    _note("[Step 2] stable-ts not available, using standard Whisper")

segments = []
for seg in result["segments"]:
    segments.append({
        "start": seg["start"],
        "end":   seg["end"],
        "text":  seg["text"].strip()
    })

seg_path = os.path.join(output_dir, filename + "_segments.json")
with open(seg_path, "w") as f:
    json.dump(segments, f, indent=2)

txt_path = os.path.join(output_dir, filename + "_transcript.txt")
with open(txt_path, "w") as f:
    for seg in segments:
        f.write(seg["text"] + "\n")

_ok(f"Segments saved to:   {seg_path}")
_ok(f"Transcript saved to: {txt_path}")
PYEOF
fi

echo -e "${GREEN}  Transcription complete.${NC}"

# ─── Step 3: Detect Slide Changes ──────────────────────────────────────────────
_phase 3 "Detect slide changes in the video"

_SLIDE_TIMES_JSON="$FOLDER_C/${filename}_slide_times.json"
_SCREENGRABS_JSON="$FOLDER_C/${filename}_screengrabs.json"

if [ -f "$_SLIDE_TIMES_JSON" ] && [ -s "$_SLIDE_TIMES_JSON" ] \
   && [ -f "$_SCREENGRABS_JSON" ] && [ -s "$_SCREENGRABS_JSON" ]; then
    echo -e "${CYAN}  Slide times already exist — skipping detection.${NC}"
else
python - << PYEOF
import cv2, json, mmap, os, sys
import numpy as np

# ─── Console styling (auto-disables when output isn't a terminal, e.g. piped to a log) ──
_TTY = sys.stdout.isatty()
def _c(code): return code if _TTY else ""
_GRN, _YLW, _RED, _BLU, _CYN, _DIM, _BLD, _RST = (
    _c("\033[0;32m"), _c("\033[1;33m"), _c("\033[0;31m"), _c("\033[0;34m"),
    _c("\033[0;36m"), _c("\033[2m"), _c("\033[1m"), _c("\033[0m"),
)
_DEBUG_ON = bool(os.environ.get("LM_DEBUG"))
def _ok(msg):   print(f"  {_GRN}✔{_RST} {msg}", flush=True)
def _warn(msg): print(f"  {_YLW}⚠{_RST} {msg}", flush=True)
def _err(msg):  print(f"  {_RED}✘{_RST} {msg}", flush=True)
def _ai(msg):   print(f"  {_CYN}🤖{_RST} {msg}", flush=True)
def _note(msg): print(f"  {_DIM}{msg}{_RST}", flush=True)
def _step(msg): print(f"\n  {_BLU}{_BLD}{msg}{_RST}", flush=True)
def _dbg(msg):
    # Verbose internal diagnostics — off by default to keep output readable;
    # set LM_DEBUG=1 to see them (e.g. LM_DEBUG=1 ./noties.sh).
    if _DEBUG_ON:
        print(f"  {_DIM}DEBUG: {msg}{_RST}", flush=True)

def mmap_read_json(path, default=None):
    """Load a JSON file via mmap instead of a plain read().

    Mirrors the mmap_read_text/mmap_read_json helpers in lamav2.py. The
    files this reads back (Whisper's segments.json) are the one part of
    Tollama that can genuinely get large — a couple of hours of lecture
    produces thousands of segments — and mmap lets the OS page the file in
    lazily off the page cache instead of an extra buffered-read copy,
    which matters more here than for the small state files (slide_times,
    screengrabs) that stay tiny regardless of lecture length. Falls back
    to a plain read if mmap fails for any reason (permissions, unusual
    filesystem, empty file) so behavior is unchanged when mmap can't help.
    """
    try:
        size = os.path.getsize(path)
        if size == 0:
            return default
        with open(path, "rb") as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                text = mm.read().decode("utf-8", errors="ignore")
    except Exception:
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                text = f.read()
        except Exception:
            return default
    if not text.strip():
        return default
    try:
        return json.loads(text)
    except Exception:
        return default

video_path  = "$INPUT_VIDEO"
output_dir  = "$FOLDER_C"
filename    = "$filename"
slides_file = "$SLIDES_FILE"
slides_type = "$SLIDES_TYPE"

cap            = cv2.VideoCapture(video_path)
fps            = cap.get(cv2.CAP_PROP_FPS)
_frame_count   = cap.get(cv2.CAP_PROP_FRAME_COUNT)
video_duration = (_frame_count / fps) if fps else 0.0
cap.release()

# ── Cheap slide-count lookup (no rendering needed) — gives detection a target ──
# so an under-count is caught and corrected instead of silently shipped.
expected_slide_count = None
if slides_type == "pptx" and slides_file:
    try:
        from pptx import Presentation as _Presentation
        expected_slide_count = len(_Presentation(slides_file).slides)
    except Exception as _e:
        _note(f"[Step 3] Could not pre-count PPTX slides ({_e})")
elif slides_type == "pdf" and slides_file:
    try:
        import fitz as _fitz
        expected_slide_count = _fitz.open(slides_file).page_count
    except Exception as _e:
        _note(f"[Step 3] Could not pre-count PDF pages ({_e})")

if expected_slide_count:
    _note(f"[Step 3] Source deck has {expected_slide_count} slide(s) — using this as a detection target.")

# Fraction of width/height blacked out in the bottom-right corner to ignore a
# lecturer's webcam/face PIP overlay. Read from the shared bash-level
# WEBCAM_MASK_FRAC (set once, near the top of the script) instead of being
# hardcoded here, so this and the Step 4-7 heredoc below can never drift out
# of sync with each other.
WEBCAM_MASK_FRAC = float("$WEBCAM_MASK_FRAC")
_PROCESS_WIDTH    = 640

def _grayscale_masked(frame):
    h, w = frame.shape[:2]
    masked = frame.copy()
    masked[int(h * (1 - WEBCAM_MASK_FRAC)):, int(w * (1 - WEBCAM_MASK_FRAC)):] = 0
    small = cv2.resize(masked, (_PROCESS_WIDTH, int(h * _PROCESS_WIDTH / w)))
    return cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)

def _robust_center_spread(diffs):
    """Median/IQR-based estimate of (center, spread) for a list of frame-diff
    scores, used in place of raw mean/std for threshold calibration.

    A handful of outlier frames early in the calibration window — a title
    animation before the lecture proper starts, a single dropped/glitched
    frame, a quick camera adjustment — can drag a raw mean and inflate a raw
    std enough to push the resulting threshold too high, causing genuine
    slide transitions later in the video to go undetected. The median is
    unmoved by a small number of outliers, and IQR/1.35 is a standard
    approximation of the standard deviation for roughly-normal data that's
    similarly resistant to a handful of extreme values.
    """
    n = len(diffs)
    s = sorted(diffs)
    median = s[n // 2]
    q1 = s[n // 4]
    q3 = s[(3 * n) // 4]
    iqr = q3 - q1
    if iqr > 1e-6:
        return median, iqr / 1.35
    # IQR collapsed (very stable video) — fall back to plain std, which is
    # well-behaved when the data has little spread to begin with.
    return median, float(np.std(diffs))

def _diff_scan(start_sec=0.0, end_sec=None, std_mult=1.5, floor=10.0, ceiling=60.0, cal_limit=300):
    """Webcam-masked adaptive frame-diff scan of the video (or a sub-range).
    Tuned for slide content (subtle text/bullet changes) rather than the hard
    cuts a generic film scene-cut detector expects. Returns (timestamps, threshold_used).

    Added debug logging: sample rate, calibration stats, early calibration
    samples, and top near-misses for visibility when expected transitions
    are absent.
    """
    cap_local = cv2.VideoCapture(video_path)
    if start_sec > 0:
        cap_local.set(cv2.CAP_PROP_POS_MSEC, start_sec * 1000)

    # How often we sample frames (originally: max(1, int(fps / 5)))
    sample_every = max(1, int(fps / 5))
    # Pre-calibration default threshold
    threshold = max(35.0, floor * 3.0) if floor >= 10.0 else floor * 1.5

    cal_diffs, finalised = [], False
    prev_gray = None
    frame_idx = int(start_sec * fps)
    found = []
    near_misses = []  # (score, ts), kept sorted descending, capped at 5

    # Debug header
    _dbg(f"_diff_scan: start={start_sec}s end={end_sec} std_mult={std_mult} floor={floor} ceiling={ceiling} cal_limit={cal_limit} sample_every={sample_every}")

    sample_count = 0
    while True:
        ret, frame = cap_local.read()
        if not ret:
            break
        ts = frame_idx / fps
        if end_sec is not None and ts > end_sec:
            break
        # sampling down to reduce work
        if frame_idx % sample_every != 0:
            frame_idx += 1
            continue
        sample_count += 1
        gray = _grayscale_masked(frame)
        if prev_gray is not None:
            score = float(np.mean(cv2.absdiff(gray, prev_gray)))
            # calibration window
            if not finalised:
                cal_diffs.append(score)
                if len(cal_diffs) >= cal_limit:
                    _center, _spread = _robust_center_spread(cal_diffs)
                    threshold = max(floor, min(_center + std_mult * _spread, ceiling))
                    finalised = True
                    _dbg(f"_diff_scan: calibration finished after {len(cal_diffs)} samples -> center={_center:.3f}, spread={_spread:.3f}, threshold={threshold:.3f}")
            # when not finalised we still compare with the current provisional threshold
            if score > threshold:
                found.append(round(ts, 3))
                _dbg(f"_diff_scan: FOUND at {ts:.3f}s (score={score:.3f})")
            else:
                near_misses.append((score, round(ts, 3)))
                near_misses.sort(key=lambda x: -x[0])
                del near_misses[5:]
        prev_gray = gray
        frame_idx += 1

    cap_local.release()

    # If calibration never finalised, compute threshold from collected cal_diffs now
    if not finalised and cal_diffs:
        _center, _spread = _robust_center_spread(cal_diffs)
        threshold = max(floor, min(_center + std_mult * _spread, ceiling))
        _dbg(f"_diff_scan: calibration fallback -> samples={len(cal_diffs)}, center={_center:.3f}, spread={_spread:.3f}, threshold={threshold:.3f}")

    # Summarise sampling and near-misses for diagnosis
    _dbg(f"_diff_scan: sampled_frames={sample_count}, found={len(found)}, top_near_misses={[ (round(s,3), t) for s,t in near_misses[:5] ]}")
    return found, threshold, near_misses

def _merge_timestamps(*lists, gap=1.5):
    """Union multiple candidate timestamp lists, treating anything within 'gap'
    seconds of an already-kept timestamp as the same transition."""
    merged = []
    for lst in lists:
        for t in lst:
            if not any(abs(t - m) <= gap for m in merged):
                merged.append(t)
    return sorted(merged)

# ── Robust scene detection: run multiple detectors, debug outputs, and sensitivity fallback ──
sd_timestamps = []
try:
    from scenedetect import open_video, SceneManager
    from scenedetect.detectors import ContentDetector, AdaptiveDetector

    # Read configured value (backwards-compatible); user may supply small numbers tuned for AdaptiveDetector.
    try:
        _raw_sd_val = float("$SCENE_DETECT_THRESHOLD")
    except Exception:
        _raw_sd_val = 1.0

    # Map the user-provided value to sensible ContentDetector and AdaptiveDetector values.
    # ContentDetector expects a pixel-difference threshold (typical ~12..30).
    if _raw_sd_val <= 3.0:
        _cd_threshold = 18.0
    else:
        _cd_threshold = max(8.0, _raw_sd_val)

    # AdaptiveDetector uses an adaptive_threshold scale; keep a low tuned value for slide decks.
    _ad_threshold = 0.6 if _raw_sd_val <= 1.0 else min(1.5, _raw_sd_val)

    # Minimum scene length in frames: small fraction of a second so short slides are not ignored.
    _min_scene_len_frames = max(1, int(max(1, fps) * 0.15))  # ~0.15s at fps

    _note(f"[Step 3] Running scenedetect ContentDetector(threshold={_cd_threshold}, min_scene_len={_min_scene_len_frames})")
    _note(f"[Step 3] Also running scenedetect AdaptiveDetector(adaptive_threshold={_ad_threshold}, min_scene_len={_min_scene_len_frames})")

    # Helper to run one detector and return a sorted list of start timestamps (seconds).
    def _run_detector(detector_cls, *args, **kwargs):
        try:
            v = open_video(video_path)
            sm = SceneManager()
            det = detector_cls(*args, **kwargs)
            sm.add_detector(det)
            sm.detect_scenes(v, show_progress=False)
            scenes = sm.get_scene_list() or []
        except Exception as e:
            _dbg(f"detector {detector_cls.__name__} failed: {e}")
            scenes = []
        starts = []
        for s in scenes:
            try:
                start_obj = s[0]
            except Exception:
                start_obj = s
            try:
                starts.append(round(float(start_obj.get_seconds()), 3))
            except Exception:
                try:
                    starts.append(round(float(start_obj), 3))
                except Exception:
                    pass
        # dedupe small duplicates that may appear inside the same detector output
        out = []
        tol = 0.25
        for t in sorted(starts):
            if not out or abs(t - out[-1]) > tol:
                out.append(t)
        return out

    # Run both detectors
    _cd_starts = _run_detector(ContentDetector, threshold=_cd_threshold, min_scene_len=_min_scene_len_frames)
    _ad_starts = _run_detector(AdaptiveDetector, adaptive_threshold=_ad_threshold, min_scene_len=_min_scene_len_frames)

    _note(f"[Step 3] ContentDetector found {len(_cd_starts)} transitions: {_cd_starts}")
    _note(f"[Step 3] AdaptiveDetector found {len(_ad_starts)} transitions: {_ad_starts}")

    # Merge (union) with small tolerance to collapse near-duplicates coming from different detectors.
    _merged_raw = sorted(_cd_starts + _ad_starts)
    _dedup = []
    _tol = max(0.35, 0.25)  # ~0.35s tolerance by default
    for t in _merged_raw:
        if not _dedup:
            _dedup.append(t)
        elif abs(t - _dedup[-1]) > _tol:
            _dedup.append(t)
        else:
            # keep existing entry (the earlier one)
            continue

    # If we have an expected_slide_count and we found substantially fewer transitions than expected,
    # run a short, higher-sensitivity ContentDetector pass (fallback) to try to recover missed transitions.
    if 'expected_slide_count' in globals() and expected_slide_count and (len(_dedup) - 1) < expected_slide_count:
        missing = expected_slide_count - max(0, len(_dedup) - 1)
        _note(f"[Step 3] scenedetect merged found {len(_dedup)} timestamps (incl 0), expects {expected_slide_count} slides -> attempting high-sensitivity re-run to recover ~{missing} missing transitions")
        try:
            # More sensitive threshold (lower), smaller min_scene_len for the fallback run
            _cd_lo = max(8.0, _cd_threshold * 0.55)
            _min_scene_len_frames_lo = max(1, int(max(1, fps) * 0.08))  # ~0.08s
            _cd_lo_starts = _run_detector(ContentDetector, threshold=_cd_lo, min_scene_len=_min_scene_len_frames_lo)
            _note(f"[Step 3] High-sensitivity ContentDetector found {len(_cd_lo_starts)} transitions: {_cd_lo_starts}")
            # merge these too
            for t in sorted(_cd_lo_starts):
                if not _dedup or all(abs(t - d) > _tol for d in _dedup):
                    _dedup.append(t)
            _dedup = sorted(_dedup)
        except Exception as e:
            _dbg(f"high-sensitivity scenedetect fallback failed: {e}")

    # Ensure 0.0 is anchor start
    if not _dedup or _dedup[0] != 0.0:
        _dedup = [0.0] + _dedup

    sd_timestamps = list(_dedup)
    _note(f"[Step 3] scenedetect merged (Content+Adaptive) found {len(sd_timestamps)} transitions (merged): {sd_timestamps}")

    # Save raw per-detector outputs for offline debugging
    try:
        with open(os.path.join(output_dir, filename + "_scenedetect_debug.json"), "w") as _f:
            json.dump({"cd": _cd_starts, "ad": _ad_starts, "merged": sd_timestamps}, _f, indent=2)
    except Exception:
        pass

except Exception as _e:
    _warn(f"scenedetect pass failed or is unavailable ({_e}) — continuing with 0 transitions from this pass; Pass 2 (content-diff) still runs.")
    sd_timestamps = []
# ── Pass 2: webcam-masked adaptive content-diff — this is the pass actually
# suited to slide decks, and previously only ran when scenedetect was missing
# entirely, so scenedetect's blind spots were never being covered. Now both
# passes always run and their results are merged. ─────────────────────────────
_note(f"[Step 3] FPS: {fps:.2f} — running webcam-masked content-diff pass...")
diff_timestamps, _threshold_used, _ = _diff_scan()
print(f"  [Step 3] Content-diff pass found {len(diff_timestamps)} transitions "
      f"(threshold={_threshold_used:.2f})", flush=True)

slide_timestamps = _merge_timestamps(sd_timestamps, diff_timestamps)
if not slide_timestamps or slide_timestamps[0] > 2.0:
    slide_timestamps.insert(0, 0.0)
    slide_timestamps.sort()

_note(f"[Step 3] Merged both passes: {len(slide_timestamps)} total transitions")

# ── Targeted re-scan of unusually long gaps ──────────────────────────────────
# Re-scans only the specific long gap(s) involved (never the whole video,
# which would be far slower for an hours-long lecture). A gap qualifies for
# re-scanning if it's a clear outlier by EITHER of two independent measures:
#   - more than 2x the video's naive average dwell (video_duration /
#     expected_slide_count), or
#   - more than 2x the MEDIAN of the gaps actually observed so far.
# Two separate measures rather than one because either alone can miss real
# cases: the average-dwell measure is skewed by a long intro/title slide (a
# single 4-minute opening slide inflates the "average" enough that a later
# 3.5-minute dead zone hiding 2 missed slides can look unremarkable by
# comparison); the median-of-observed-gaps measure is skewed if the deck is
# genuinely short on detected transitions overall (every observed gap is
# inflated, so nothing looks like an outlier relative to its neighbours).
# Taking whichever measure is more sensitive for a given gap — min() of the
# two computed thresholds — means a gap only has to clear the *easier* of the
# two bars, not both, which is deliberately permissive: re-scanning a gap
# that turns out fine costs a little compute, but skipping a gap that hid a
# real transition produces exactly the misaligned-slide-sequence failure this
# is meant to prevent.
if expected_slide_count and video_duration > 0:
    avg_dwell    = video_duration / expected_slide_count
    global_short = len(slide_timestamps) < 0.85 * expected_slide_count
    boundaries   = slide_timestamps + [video_duration]
    all_gaps     = [(boundaries[i], boundaries[i + 1]) for i in range(len(boundaries) - 1)]
    gap_lengths  = sorted(b - a for a, b in all_gaps)
    median_gap   = gap_lengths[len(gap_lengths) // 2] if gap_lengths else avg_dwell
    # Tunable: baseline minimum threshold for identifying unusually long gaps.
    # Lowering this makes the re-scan more aggressive for shorter lectures/decks.
    _MIN_RESCAN_BASE = 30.0  # seconds (was 45.0)

    thresh_by_avg    = max(2.0 * avg_dwell, _MIN_RESCAN_BASE)
    thresh_by_median = max(2.0 * median_gap, _MIN_RESCAN_BASE)
    qualify_thresh   = min(thresh_by_avg, thresh_by_median)
    gaps = [g for g in all_gaps if g[1] - g[0] > qualify_thresh]
    if gaps:
        _reason = (f"Only {len(slide_timestamps)}/{expected_slide_count} expected slides found"
                   if global_short else
                   f"{len(slide_timestamps)}/{expected_slide_count} expected slides found, but "
                   f"{len(gaps)} gap(s) are outliers relative to the rest of the video")
        print(f"  [Step 3] {_reason} — "
              f"re-scanning {len(gaps)} unusually long gap(s) with higher sensitivity "
              f"(threshold={qualify_thresh:.0f}s)...", flush=True)
        recovered   = 0
        _still_dark = []  # gaps where even the sensitive visual re-scan found nothing
        for g_start, g_end in gaps:
            extra, _rescan_threshold, _near_misses = _diff_scan(
                start_sec=g_start, end_sec=g_end,
                std_mult=0.6, floor=5.0, ceiling=45.0, cal_limit=120)
            _found_here = 0
            for t in extra:
                if not any(abs(t - s) <= 1.5 for s in slide_timestamps):
                    slide_timestamps.append(t)
                    recovered += 1
                    _found_here += 1
            if _found_here == 0:
                _still_dark.append((g_start, g_end))
                # This gap came back empty — show the actual numbers instead
                # of a bare "found nothing", so it's clear whether this is a
                # threshold-tuning problem (near-misses sitting just under
                # the bar) or something else entirely (near-misses far below
                # it, e.g. webcam masking removing the only region that
                # actually changes in this recording).
                if _near_misses:
                    _top = ", ".join(f"{ts:.1f}s (score={sc:.1f})" for sc, ts in _near_misses[:3])
                    print(f"      {g_start:.1f}s-{g_end:.1f}s: no transition cleared threshold="
                          f"{_rescan_threshold:.1f} — highest-scoring frames in this range: {_top}",
                          flush=True)
        slide_timestamps.sort()
        print(f"  [Step 3] Gap re-scan recovered {recovered} additional transition(s): "
              f"{len(slide_timestamps)} total now.", flush=True)

        # ── Ollama fallback: transcript-based topic-shift detection ─────────
        # Some slides are visually near-identical to their neighbour (same
        # template, bullets revealed incrementally) — no amount of pixel
        # sensitivity finds those, because there's genuinely nothing to see.
        # But the *spoken content* usually shifts topic when the slide does,
        # which a language model can pick up even where pixels can't.
        #
        # Triggered by whether an unresolved *silent* gap exists at all — NOT
        # by whether the running total has reached expected_slide_count. The
        # aggregate count reaching the target is not evidence that this
        # specific gap was resolved: other gaps elsewhere can (and did, in
        # testing) recover enough transitions to make the total look complete
        # while this exact stretch remains untouched. Checking the total
        # instead of the specific gap's own outcome is what silently produced
        # a fully-populated-looking output with two slides missing and a
        # visually-similar neighbour standing in for both.
        _AI_ENABLED_S3   = "$AI_ENABLED" == "true"
        _OLLAMA_MODEL_S3 = "$OLLAMA_MODEL"
        if _AI_ENABLED_S3 and _still_dark:
            try:
                _segments = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []
            except Exception:
                _segments = []

            def _ollama_gen_s3(prompt, timeout=90):
                import urllib.request as _ur, json as _json2
                try:
                    req = _ur.Request(
                        "http://localhost:11434/api/generate",
                        data=_json2.dumps({
                            "model": _OLLAMA_MODEL_S3, "prompt": prompt,
                            "stream": False, "options": {"temperature": 0.1},
                        }).encode("utf-8"),
                        headers={"Content-Type": "application/json"},
                    )
                    with _ur.urlopen(req, timeout=timeout) as resp:
                        return (_json2.loads(resp.read().decode("utf-8")).get("response") or "").strip()
                except Exception as _e:
                    _warn(f"Ollama request failed ({_e}) — skipping topic-shift pass for this gap.")
                    return ""

            _ai(f"[Step 3] {len(_still_dark)} gap(s) had no visual signal at all — "
                f"asking Ollama to find topic shifts in the transcript instead...")
            _ai_recovered = 0
            for g_start, g_end in _still_dark[:15]:  # bound total Ollama calls per run
                segs_in_gap = [s for s in _segments if g_start <= s.get("start", 0) < g_end]
                if len(segs_in_gap) < 3:
                    continue
                segs_in_gap = segs_in_gap[:60]  # bound prompt size for a small local model
                listing = "\n".join(
                    f"{k+1}) {s['text'].strip()[:150]}" for k, s in enumerate(segs_in_gap)
                )
                prompt = (
                    "These are consecutive transcript segments from one stretch of a "
                    "recorded lecture, numbered in order. No visual slide-change was "
                    "detected across this whole stretch, but it may still contain "
                    "several slides whose content changed with no strong visual cue "
                    "(e.g. bullet points appearing one by one).\n\n"
                    f"{listing}\n\n"
                    "List the segment numbers where a new topic most likely begins "
                    "(do not include segment 1). Reply with ONLY a comma-separated "
                    "list of numbers, or 'none' if this whole stretch is one topic."
                )
                reply = _ollama_gen_s3(prompt)
                if not reply or reply.strip().lower().startswith("none"):
                    continue
                import re as _re3
                for _num in _re3.findall(r"\d+", reply):
                    idx = int(_num) - 1
                    if 1 <= idx < len(segs_in_gap):
                        t = segs_in_gap[idx]["start"]
                        if not any(abs(t - s) <= 1.5 for s in slide_timestamps):
                            slide_timestamps.append(t)
                            _ai_recovered += 1
            if _ai_recovered:
                slide_timestamps.sort()
                _ai(f"[Step 3] Ollama topic-shift pass added {_ai_recovered} more "
                    f"transition(s): {len(slide_timestamps)} total now.")

if expected_slide_count and len(slide_timestamps) < expected_slide_count:
    _warn(f"Still found fewer transitions ({len(slide_timestamps)}) than the deck's "
          f"{expected_slide_count} slides. Remaining gaps are likely slides shown very "
          f"briefly, skipped in the recording, or visually near-identical to a neighbour.")

# ── Filter out transient transitions (quick flicks/scrolls, not genuinely
# presented slides) ──────────────────────────────────────────────────────────
# Every detected transition up to this point becomes its own "slide" with its
# own screengrab — but not every transition is one. A lecturer glancing ahead
# then immediately going back, or scrolling quickly past a slide on the way
# to another, produces a real, detectable visual transition with essentially
# no dwell time and (usually) no speech of its own. Treating those the same
# as a deliberately presented slide is exactly what produces near-duplicate,
# repeated-looking entries in the final output — the "slide" is really just a
# blip on either side of the slide the lecturer actually meant to be on.
#
# A transition is kept as a genuine slide if EITHER holds:
#   - it was on screen for at least MIN_DWELL_SEC, or
#   - the lecturer said at least MIN_SPOKEN_WORDS words while on it
# (a brief-but-intentional revisit — "quickly, back to this point" — still
# has speech attached to it, so it survives; a pure flick has neither).
# We now only *drop* transients when we have *more* detected transitions than
# the source deck's expected slide count (if the deck count is available).
# If we know the deck length and we have fewer-or-equal transitions than the
# deck, prefer keeping them (better for completeness); the "drop" pass is
# therefore conservative and only removes surplus detections.
MIN_DWELL_SEC     = MIN_DWELL_SEC if 'MIN_DWELL_SEC' in globals() else 1.5
MIN_SPOKEN_WORDS  = MIN_SPOKEN_WORDS if 'MIN_SPOKEN_WORDS' in globals() else 4

try:
    _all_segments_s3 = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []
except Exception:
    _all_segments_s3 = []

def _spoken_word_count(a, b):
    return sum(
        len(s.get("text", "").split())
        for s in _all_segments_s3 if a <= s.get("start", 0) < b
    )

# If the source deck's expected_slide_count is known, only run the destructive
# removal pass when we have more detected transitions than the deck — otherwise
# keep everything and surface a warning so the user can inspect remaining gaps.
_apply_transient_drop = True
if expected_slide_count and len(slide_timestamps) <= expected_slide_count:
    _apply_transient_drop = False
    _note(f"[Step 3] Detected {len(slide_timestamps)} transition(s) and source deck has {expected_slide_count} slide(s) — skipping transient DROP pass to avoid losing real slides.")

# Still compute dwell/word stats and log any candidates (but only actually remove
# them if _apply_transient_drop is True).
if len(slide_timestamps) > 2:
    _boundaries = slide_timestamps + [video_duration if video_duration > 0 else slide_timestamps[-1] + MIN_DWELL_SEC]
    _kept, _transient = [], []
    _transient_info = []
    for idx, t in enumerate(slide_timestamps):
        # Never drop the very first transition — it's a structural anchor.
        if idx == 0:
            _kept.append(t)
            continue
        dwell = _boundaries[idx + 1] - t
        words = _spoken_word_count(t, _boundaries[idx + 1])
        if dwell < MIN_DWELL_SEC and words < MIN_SPOKEN_WORDS:
            _transient.append(t)
            _transient_info.append((idx, t, dwell, words))
            # if not removing, still keep in _kept for now
            if not _apply_transient_drop:
                _kept.append(t)
        else:
            _kept.append(t)

    if _transient_info:
        # Log detailed info so user can see why items were considered transient.
        _note(f"[Step 3] {len(_transient_info)} transient-candidate(s) detected (dwell < {MIN_DWELL_SEC}s and words < {MIN_SPOKEN_WORDS}):")
        for idx, t, dwell, words in _transient_info:
            print(f"      idx={idx+1}  t={t:.2f}s  dwell={dwell:.2f}s  words={words}", flush=True)

    if _apply_transient_drop and _transient:
        _warn(f"Dropping {len(_transient)} transient transition(s) — too brief (<{MIN_DWELL_SEC}s) with little/no speech: {[round(t, 2) for t in _transient]}")
        slide_timestamps = sorted(_kept)
        _transient_path = os.path.join(output_dir, filename + "_transient_transitions.json")
        with open(_transient_path, "w") as _f:
            json.dump(_transient, _f, indent=2)
    else:
        # Either nothing to drop, or we deliberately skipped destructive removal.
        slide_timestamps = sorted(_kept)


if len(slide_timestamps) > 2:
    _boundaries = slide_timestamps + [video_duration if video_duration > 0 else slide_timestamps[-1] + MIN_DWELL_SEC]
    _kept, _transient = [], []
    for idx, t in enumerate(slide_timestamps):
        # Never drop the very first transition — it's a structural anchor
        # (the opening slide). The *last* transition gets no such exemption:
        # a brief flick 15 seconds before the recording ends is exactly the
        # kind of transient this filter exists to catch, and nothing
        # downstream depends on it surviving (screengrabs are captured from
        # slide_timestamps after this filtering step, so dropping an entry
        # here just means one fewer screengrab gets taken, not a misalignment
        # with anything already-computed).
        if idx == 0:
            _kept.append(t)
            continue
        dwell = _boundaries[idx + 1] - t
        words = _spoken_word_count(t, _boundaries[idx + 1])
        if dwell < MIN_DWELL_SEC and words < MIN_SPOKEN_WORDS:
            _transient.append(t)
        else:
            _kept.append(t)
    if _transient:
        _warn(f"Dropping {len(_transient)} transient transition(s) — too brief "
              f"(<{MIN_DWELL_SEC}s) with no meaningful speech, so likely a quick flick "
              f"or scroll-through rather than a slide the lecturer actually presented: "
              f"{[round(t, 2) for t in _transient]}")
        slide_timestamps = sorted(_kept)
        _transient_path = os.path.join(output_dir, filename + "_transient_transitions.json")
        with open(_transient_path, "w") as _f:
            json.dump(_transient, _f, indent=2)

# Debug: print final slide_times with index for quick cross-check
print("  Final slide_times (index: seconds):", flush=True)
for idx, t in enumerate(slide_timestamps):
    print(f"    {idx+1}: {t:.3f}s", flush=True)

out_path = os.path.join(output_dir, filename + "_slide_times.json")
with open(out_path, "w") as f:
    json.dump(slide_timestamps, f, indent=2)

# Final check: flag any still-unresolved outlier gap in the list that's
# actually shipping, even on an apparently-complete run. The count reaching
# expected_slide_count is NOT proof every individual gap was resolved — other
# gaps can recover enough transitions elsewhere to make the total look
# complete while one specific stretch was never touched (this is exactly
# what happened in testing: two missed slides sat inside a gap that fell
# just under the re-scan threshold, while two unrelated gaps elsewhere
# recovered enough transitions to push the total past the deck's slide count
# and mask the problem). Surfacing this explicitly, with the actual time
# range, means a leftover dead zone is visible instead of hiding behind a
# total that merely adds up.
if expected_slide_count and video_duration > 0 and len(slide_timestamps) >= 2:
    _final_boundaries  = slide_timestamps + [video_duration]
    _final_gaps        = [(_final_boundaries[i], _final_boundaries[i + 1])
                           for i in range(len(_final_boundaries) - 1)]
    _final_gap_lengths = sorted(b - a for a, b in _final_gaps)
    _final_median      = _final_gap_lengths[len(_final_gap_lengths) // 2]
    _final_avg_dwell   = video_duration / expected_slide_count
    _final_qualify     = min(max(2.0 * _final_avg_dwell, 45.0), max(2.0 * _final_median, 45.0))
    _unresolved         = [g for g in _final_gaps if g[1] - g[0] > _final_qualify]
    if _unresolved:
        _warn(f"{len(_unresolved)} gap(s) are still unusually long relative to the rest "
              f"of the video even though the overall count looks complete — these are worth "
              f"checking by hand, since they can hide a missed slide standing in for a "
              f"visually-similar neighbour:")
        for g_start, g_end in _unresolved:
            print(f"      {g_start:.1f}s – {g_end:.1f}s  ({g_end - g_start:.1f}s, "
                  f"vs {_final_qualify:.0f}s expected)", flush=True)

print(f"  Found {len(slide_timestamps)} slides.", flush=True)
_ok(f"Saved to {out_path}")

# ── Capture screengrabs at each detected slide timestamp (robust + metadata) ──
screengrabs_dir = os.path.join(output_dir, filename + "_screengrabs")
os.makedirs(screengrabs_dir, exist_ok=True)

cap2 = cv2.VideoCapture(video_path)
screengrab_meta = []

# Prefer slide_timestamps (high-fidelity) then slide_times
if 'slide_timestamps' in globals() and isinstance(slide_timestamps, (list, tuple)) and slide_timestamps:
    times = list(slide_timestamps)
elif 'slide_times' in globals() and isinstance(slide_times, (list, tuple)) and slide_times:
    times = list(slide_times)
else:
    times = []

if not cap2.isOpened():
    _warn(f"Failed to open video for screengrabs: {video_path}")
    # still write empty metadata for compatibility
    screengrab_meta = [{"path": "", "t": (float(t) if t is not None else 0.0)} for t in times]
else:
    # Parameters (override via globals if set)
    SETTLE_OFFSET = float(globals().get("SETTLE_OFFSET", 0.6))
    BLACK_MEAN_THRESH = float(globals().get("BLACK_MEAN_THRESH", 14.0))
    MAX_PROBE_AHEAD = float(globals().get("MAX_PROBE_AHEAD", 2.5))
    PROBE_STEP = float(globals().get("PROBE_STEP", 0.3))

    def _read_frame_at(cap, t_sec):
        try:
            cap.set(cv2.CAP_PROP_POS_MSEC, max(t_sec, 0) * 1000)
            ok, frm = cap.read()
            return frm if ok else None
        except Exception:
            return None

    def _mean_intensity(frame):
        try:
            return float(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).mean())
        except Exception:
            return 0.0

    def _sharpness(frame):
        try:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            return float(cv2.Laplacian(gray, cv2.CV_64F).var())
        except Exception:
            return 0.0

    for idx, t in enumerate(times):
        try:
            ts = float(t)
        except Exception:
            ts = 0.0
        next_ts = times[idx + 1] if idx + 1 < len(times) else None
        # ceiling prevents probing past the next cut
        ceiling = (next_ts - 0.15) if next_ts is not None else (ts + MAX_PROBE_AHEAD + SETTLE_OFFSET)
        capture_ts = min(ts + SETTLE_OFFSET, max(ts, ceiling))

        frame = _read_frame_at(cap2, capture_ts)

        # If too dark, probe forward and choose the sharpest non-black frame
        if frame is not None and _mean_intensity(frame) < BLACK_MEAN_THRESH:
            probe_ts = capture_ts
            probe_limit = min(ts + SETTLE_OFFSET + MAX_PROBE_AHEAD, ceiling)
            candidates = []  # (sharpness, probe_ts, frame)
            while probe_ts < probe_limit:
                probe_ts += PROBE_STEP
                probe_frame = _read_frame_at(cap2, probe_ts)
                if probe_frame is None:
                    continue
                meanv = _mean_intensity(probe_frame)
                if meanv >= BLACK_MEAN_THRESH:
                    candidates.append((_sharpness(probe_frame), probe_ts, probe_frame))
            if candidates:
                _, capture_ts, frame = max(candidates, key=lambda c: c[0])

        if frame is not None:
            sg_img_path = os.path.join(screengrabs_dir, f"screengrab_{idx:03d}.png")
            try:
                cv2.imwrite(sg_img_path, frame)
            except Exception as _e:
                _warn(f"Failed to write screengrab {idx+1}: {_e}")
                sg_img_path = ""
            meanv = _mean_intensity(frame)
            flag = "  ⚠ still near-black — screen-share may have dropped" if meanv < BLACK_MEAN_THRESH else ""
            print(f"  Screengrab {idx+1} (t={capture_ts:.2f}s){flag}: {sg_img_path}", flush=True)
            screengrab_meta.append({"path": sg_img_path, "t": round(float(capture_ts), 3)})
        else:
            print(f"  Screengrab {idx+1} (t={ts:.2f}s): could not read frame", flush=True)
            screengrab_meta.append({"path": "", "t": round(float(ts), 3)})

    cap2.release()

# Atomically write metadata as list of dicts {"path":..., "t":...}
sg_list_path = os.path.join(output_dir, filename + "_screengrabs.json")
try:
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False, dir=output_dir, encoding="utf-8") as _tf:
        json.dump(screengrab_meta, _tf, indent=2)
        tmp_path = _tf.name
    os.replace(tmp_path, sg_list_path)
    _ok(f"Screengrabs saved to: {screengrabs_dir}")
    _ok(f"Screengrab metadata saved to: {sg_list_path}")
except Exception as _e:
    _warn(f"Failed to save screengrab metadata: {_e}")
    try:
        if 'tmp_path' in locals() and os.path.exists(tmp_path):
            os.remove(tmp_path)
    except Exception:
        pass

# Populate helper lists for downstream steps
screengrab_imgs = [entry.get("path", "") for entry in screengrab_meta]
screengrab_times = [entry.get("t") for entry in screengrab_meta]
num_segments = len(screengrab_imgs)
_note(f"{num_segments} screengrab entries loaded (paths + timestamps).")
PYEOF
fi

# ─── Steps 4–7: Render, Align, Assign, Generate ────────────────────────────────
_note "Continuing — slide rendering, alignment, transcript assignment, and output generation are announced below as they run."

python - << PYEOF
import json, mmap, os, fitz
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.oxml.ns import qn
from lxml import etree
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Image as RLImage, HRFlowable
from reportlab.lib import colors
from PIL import Image as PILImage
import sys as _sys

# ─── Console styling (auto-disables when output isn't a terminal, e.g. piped to a log) ──
_TTY = _sys.stdout.isatty()
def _c(code): return code if _TTY else ""
_GRN, _YLW, _RED, _BLU, _CYN, _DIM, _BLD, _RST = (
    _c("\033[0;32m"), _c("\033[1;33m"), _c("\033[0;31m"), _c("\033[0;34m"),
    _c("\033[0;36m"), _c("\033[2m"), _c("\033[1m"), _c("\033[0m"),
)
def _ok(msg):   print(f"  {_GRN}✔{_RST} {msg}", flush=True)
def _warn(msg): print(f"  {_YLW}⚠{_RST} {msg}", flush=True)
def _err(msg):  print(f"  {_RED}✘{_RST} {msg}", flush=True)
def _ai(msg):   print(f"  {_CYN}🤖{_RST} {msg}", flush=True)
def _note(msg): print(f"  {_DIM}{msg}{_RST}", flush=True)
def _step(msg): print(f"\n  {_BLU}{_BLD}{msg}{_RST}", flush=True)

def mmap_read_json(path, default=None):
    """Load a JSON file via mmap instead of a plain read() — see the same
    helper in Step 3 for the full rationale. This is the heredoc that
    re-reads segments.json on every run (including resumed ones), so it's
    the one place in the pipeline where a long lecture's transcript size
    actually shows up as a meaningful read.
    """
    try:
        size = os.path.getsize(path)
        if size == 0:
            return default
        with open(path, "rb") as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                text = mm.read().decode("utf-8", errors="ignore")
    except Exception:
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                text = f.read()
        except Exception:
            return default
    if not text.strip():
        return default
    try:
        return json.loads(text)
    except Exception:
        return default

output_dir  = "$FOLDER_C"
slides_file = "$SLIDES_FILE"
slides_type = "$SLIDES_TYPE"
filename    = "$filename"
fmt_choice  = "$format_choice"
AI_ENABLED   = "$AI_ENABLED" == "true"
OLLAMA_MODEL = "$OLLAMA_MODEL"

# Fraction of each dimension masked in the bottom-right corner to ignore the
# lecturer's webcam/face PIP overlay. Read from the same shared bash-level
# WEBCAM_MASK_FRAC as the Step 3 scene-detection block above — single source
# of truth, set once near the top of the script.
WEBCAM_MASK_FRAC = float("$WEBCAM_MASK_FRAC")

# True when the user chose screen-grabs only mode (no lecture slides file).
USE_SCREENGRABS_ONLY = (slides_type == "screengrabs")

# ─── AI helper (local Ollama) — improved, robust helper set ───────────────────
# Everything here is best-effort: if Ollama isn't enabled or a request fails,
# callers get None back and the pipeline proceeds without AI.
import urllib.request, urllib.error, socket, http.client
import sys, time, threading, math

def _fmt_eta(seconds):
    """Format a duration in seconds as e.g. '3m 12s' or '47s'."""
    seconds = max(0, int(seconds))
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"

class ProgressBar:
    """Live, single-line terminal progress bar with a rolling-average ETA.

    Gracefully degrades when stdout is not a TTY (prints lines rather than
    trying to overwrite). Shares a small API for use by ollama_generate().
    """
    def __init__(self, total, label="Generating AI content"):
        self.total   = max(int(total), 1)
        self.done    = 0
        self.label   = label
        self.start   = time.time()
        self.durations = []
        self.lock    = threading.Lock()
        self._stop   = False
        self._status = ""
        self._item_start = time.time()
        self._is_tty = bool(getattr(sys.stdout, "isatty", lambda: False)())
        self._tick   = 0.5 if self._is_tty else 5.0
        self._last_nontty_render = 0.0
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start_render(self):
        self._render(force=True)
        self._thread.start()

    def _loop(self):
        while not self._stop:
            time.sleep(self._tick)
            if not self._stop:
                self._render()

    def item_done(self, duration):
        with self.lock:
            self.done += 1
            self.durations.append(duration)
            self._item_start = time.time()
        self._render(force=True)

    def set_status(self, msg):
        with self.lock:
            self._status = msg or ""
            self._item_start = time.time()
        self._render(force=True)

    def _render(self, force=False):
        with self.lock:
            done, total, status = self.done, self.total, self._status
            avg = (sum(self.durations) / len(self.durations)) if self.durations else None
            item_elapsed = time.time() - self._item_start
        elapsed = time.time() - self.start
        remaining_items = max(total - done, 0)
        eta_str = _fmt_eta(remaining_items * avg) if avg else "estimating..."
        pct = done / total
        bar_len = 28
        filled = int(bar_len * pct)
        bar = "█" * filled + "░" * (bar_len - filled)
        line = (f"  🤖 {self.label}: [{bar}] {done}/{total} ({pct*100:3.0f}%)"
                f"  elapsed {_fmt_eta(elapsed)}  ETA {eta_str}")
        if status:
            line += f"  — {status}"
        if item_elapsed > 20:
            line += f"  [no response yet — {_fmt_eta(item_elapsed)} on this item]"

        if self._is_tty:
            padded = line[:190].ljust(190)
            sys.stdout.write("\r" + padded)
            sys.stdout.flush()
        else:
            now = time.time()
            if not force and (now - self._last_nontty_render) < self._tick:
                return
            self._last_nontty_render = now
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def finish(self):
        self._stop = True
        self._thread.join(timeout=1)
        with self.lock:
            self._status = ""
        self._render(force=True)
        if self._is_tty:
            sys.stdout.write("\n")
            sys.stdout.flush()

# Shared progress bar container used by callers (unchanged external API).
_AI_PROGRESS_BAR = [None]

# Simple on-disk cache for short AI responses to avoid repeated identical queries.
_AI_CACHE_PATH = os.path.join(output_dir, filename + "_ai_cache.json")
_ai_cache = mmap_read_json(_AI_CACHE_PATH, default={}) or {}

def _save_ai_cache():
    try:
        with open(_AI_CACHE_PATH, "w") as _f:
            json.dump(_ai_cache, _f, indent=2)
    except Exception:
        pass

# Mutable single-element list for failure metric accessible to nested code.
_OLLAMA_FAILURE_COUNT = [0]

def _parse_ollama_response(raw_text):
    """Try to robustly parse common Ollama response shapes into a short string.
    Ollama local servers vary by model/wrapper; this routine attempts several
    common locations for the textual output.
    """
    if not raw_text:
        return None
    try:
        data = json.loads(raw_text)
    except Exception:
        # Not JSON — treat raw_text as plain text
        text = raw_text.strip()
        return text if text else None

    # Common shapes:
    # { "response": "..." }
    # { "output": "..."}
    # { "choices": [{"text": "..."}] }
    # { "results": [{"output": "..."}] }
    for key in ("response", "output", "text"):
        if key in data and isinstance(data[key], str):
            t = data[key].strip()
            if t:
                return t
    # choices array:
    ch = data.get("choices") or data.get("results") or data.get("generations")
    if isinstance(ch, list) and len(ch):
        # attempt to extract text field from first element
        first = ch[0]
        if isinstance(first, dict):
            for sub in ("text", "output", "response"):
                if sub in first and isinstance(first[sub], str):
                    t = first[sub].strip()
                    if t:
                        return t
            # some wrappers use nested dicts
            for v in first.values():
                if isinstance(v, str) and v.strip():
                    return v.strip()
    return None

def _is_retryable_http_error(exc):
    """Return True for errors that deserve a retry (transient)."""
    if isinstance(exc, urllib.error.URLError):
        # network/connectivity issues are retryable
        return True
    if isinstance(exc, socket.timeout):
        return True
    if isinstance(exc, urllib.error.HTTPError):
        try:
            code = exc.code
            # 5xx are server errors, retryable; 429 (rate-limit) retryable with backoff
            if code >= 500 or code == 429:
                return True
            return False
        except Exception:
            return False
    # http.client.BadStatusLine etc are retryable transiently
    if isinstance(exc, http.client.IncompleteRead):
        return True
    return False

def ollama_generate(prompt, timeout=90, context="", retries=1):
    """Call the local Ollama server's /api/generate endpoint.

    Returns:
      - string: generated text (sanitised), or
      - None on any failure.
    Behaviour:
      - Conservative prompt-size guard to avoid blowing up local models.
      - Exponential backoff for retryable transient errors (connect/timeouts/5xx).
      - Single retry for timeouts by default (retries arg controls extra tries).
      - Logs failures to _OLLAMA_FAILURE_COUNT and to stdout.
    """
    if not globals().get("AI_ENABLED"):
        return None
    if not prompt or not isinstance(prompt, str):
        return None

    # Safety: avoid sending enormous prompts that will almost certainly time out
    max_prompt_bytes = 200_000
    if len(prompt.encode("utf-8")) > max_prompt_bytes:
        _warn(f"Prompt too large for Ollama{' (' + context + ')' if context else ''} — skipping AI for this item.")
        return None

    # Build request payload
    payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": False, "options": {"temperature": 0.2}}
    url = "http://localhost:11434/api/generate"

    # Attempt loop with exponential backoff on retryable errors
    attempt = 0
    max_attempts = max(1, retries + 1)
    base_sleep = 1.0
    max_sleep = 15.0
    attempt_timeout = timeout
    last_error = None

    # If there's a visible progress bar, report status there instead of printing many lines.
    bar = _AI_PROGRESS_BAR[0]

    while attempt < max_attempts:
        attempt += 1
        try:
            if bar:
                bar.set_status(f"{context or 'item'} contacting Ollama (attempt {attempt}/{max_attempts})")
            req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=attempt_timeout) as resp:
                raw = resp.read().decode("utf-8")
            # Try to parse common shapes safely
            text = _parse_ollama_response(raw)
            if not text:
                # treat absent/empty text as failure (no meaningful response)
                _warn(f"Ollama returned no usable text{' (' + context + ')' if context else ''} — skipping AI for this item.")
                _OLLAMA_FAILURE_COUNT[0] += 1
                return None
            # Sanity filter: tiny answers or stock "I don't know" are treated as empty
            if len(text) < 5:
                return None
            low = text.lower()
            if any(m in low for m in ("i don't know", "i am not sure", "i'm not sure", "cannot determine", "no information", "unable to determine")):
                return None
            return text.strip()
        except Exception as e:
            last_error = e
            retryable = _is_retryable_http_error(e)
            # If exception indicates a timeout and we still have retry attempts left, retry with longer timeout
            if retryable and attempt < max_attempts:
                sleep = min(max_sleep, base_sleep * (2 ** (attempt - 1)))
                attempt_timeout = min(timeout * int(1 + attempt * 0.5), timeout * 3)
                if bar:
                    bar.set_status(f"{context or 'item'} timed out/errored — retrying in {int(sleep)}s")
                else:
                    _warn(f"Ollama request error (attempt {attempt}/{max_attempts}): {e} — retrying in {int(sleep)}s")
                time.sleep(sleep)
                continue
            # Non-retryable or out of attempts
            _label = f" ({context})" if context else ""
            if bar:
                bar.set_status(f"{context or 'item'} failed — skipping")
            else:
                _warn(f"Ollama request failed ({e}){_label} — skipping AI content for this item.")
            _OLLAMA_FAILURE_COUNT[0] += 1
            return None

    # If we exit loop, return None and log
    if last_error:
        _warn(f"Ollama requests exhausted — last error: {last_error}")
    _OLLAMA_FAILURE_COUNT[0] += 1
    return None

# ─── Extract text from source slides ─────────────────────────────────────────
# Moved ahead of Step 4/5 so the alignment step below can hand slide text to
# Ollama as a secondary, semantic signal when image similarity is ambiguous.

def extract_pptx_texts(path):
    """Extract text from each slide in a PPTX."""
    prs, texts = Presentation(path), []
    for slide in prs.slides:
        parts = []
        for shape in slide.shapes:
            if shape.has_text_frame:
                for para in shape.text_frame.paragraphs:
                    t = para.text.strip()
                    if t:
                        parts.append(t)
        texts.append("\n".join(parts))
    return texts

# --- Ensure slide_times is defined and sane before Step 4 uses it ----------
# slide_times may come from:
#  - previous in-memory variable slide_timestamps (from detection),
#  - a saved JSON file <filename>_slide_times.json in output_dir,
#  - or nothing (rare). Normalise to a list of floats here so subsequent
#  Step 4/5 code can rely on slide_times always existing.
try:
    if 'slide_times' not in globals() or not isinstance(slide_times, (list, tuple)) or not slide_times:
        # Prefer an in-memory slide_timestamps if present
        if 'slide_timestamps' in globals() and isinstance(slide_timestamps, (list, tuple)) and slide_timestamps:
            slide_times = list(slide_timestamps)
        else:
            # Otherwise try to read the saved JSON produced by Step 3
            try:
                slide_times = mmap_read_json(os.path.join(output_dir, filename + "_slide_times.json"), default=[]) or []
            except Exception:
                slide_times = []
except Exception:
    slide_times = []

# Normalise entries to floats, rounded to milliseconds, sorted, and ensure at least one anchor at 0.0
_clean = []
for t in (slide_times or []):
    try:
        _t = float(t)
        _clean.append(round(_t, 3))
    except Exception:
        pass
_clean = sorted(list(dict.fromkeys(_clean)))  # dedupe while preserving order-ish
if not _clean:
    # Fallback single anchor at 0.0 if nothing else
    _clean = [0.0]
if _clean[0] != 0.0:
    _clean.insert(0, 0.0)
slide_times = _clean
# Make slide_timestamps an alias used elsewhere
slide_timestamps = list(slide_times)


def extract_pdf_texts(path):
    """Extract text from a PDF (pdfplumber → ghostscript → PyMuPDF)."""
    texts = []
    try:
        import pdfplumber
        with pdfplumber.open(path) as _pdf:
            texts = [(p.extract_text() or "").strip() for p in _pdf.pages]
        if any(texts):
            return texts
        _warn("pdfplumber returned empty text — trying ghostscript normalisation")
    except Exception as _pdf_err:
        _warn(f"pdfplumber failed ({_pdf_err}), falling back")

    try:
        import subprocess as _sp2, tempfile as _tf2
        _gs_out = _tf2.mktemp(suffix=".pdf")
        _sp2.run(
            ["gs", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite",
             "-dCompatibilityLevel=1.4", f"-sOutputFile={_gs_out}", path],
            capture_output=True, timeout=60
        )
        if os.path.exists(_gs_out):
            import pdfplumber as _pp2
            with _pp2.open(_gs_out) as _pdf2:
                texts = [(_p.extract_text() or "").strip() for _p in _pdf2.pages]
            os.remove(_gs_out)
            if any(t.strip() for t in texts):
                return [t.strip() for t in texts]
    except Exception as _gs_err:
        _warn(f"ghostscript normalisation failed ({_gs_err})")

    try:
        return [page.get_text().strip() for page in fitz.open(path)]
    except Exception as _fitz_path_err:
        # Path-based open can fail on a locked/permission-restricted file —
        # not uncommon for a PDF sitting in an iCloud-synced Desktop folder
        # that's mid-sync. Same fallback lamav2.py uses for PyMuPDF: map
        # the file and hand fitz the buffer directly instead of a path.
        try:
            with open(path, "rb") as _f:
                with mmap.mmap(_f.fileno(), 0, access=mmap.ACCESS_READ) as _mm:
                    return [page.get_text().strip() for page in fitz.open(stream=_mm, filetype="pdf")]
        except Exception as _fitz_err:
            _warn(f"PyMuPDF extraction failed ({_fitz_path_err}); mmap fallback also failed ({_fitz_err})")
            return []

# === Determine authoritative slide count and normalise timestamps ===
# Prefer the source-deck count (expected_slide_count) when available;
# otherwise use the number of detected slide_times. Keep slide_times
# length equal to num_slides (trim or pad appropriately) so indexing is stable.
detected_count = len(slide_times) if isinstance(slide_times, (list, tuple)) else 0
expected = int(expected_slide_count) if ('expected_slide_count' in globals() and expected_slide_count) else 0

if expected > 0:
    num_slides = expected
    if detected_count != num_slides:
        _warn(f"Slide count mismatch: source file has {num_slides} slides, video detection found {detected_count} transitions.")
        # If the detector found more timestamps than the deck, trim to best N
        if detected_count > num_slides:
            # Choose timestamps closest to evenly-spaced positions across the lecture
            total_duration = (slide_times[-1] if slide_times else (video_duration or 0.0))
            if total_duration <= 0 or num_slides == 1:
                slide_times = slide_times[:num_slides]
            else:
                chosen = []
                for k in range(num_slides):
                    target = (k / (num_slides - 1)) * total_duration if num_slides > 1 else 0.0
                    # pick the detected timestamp closest to this target
                    closest = min(slide_times, key=lambda t: abs(t - target))
                    chosen.append(closest)
                # dedupe + sort + ensure exactly num_slides entries
                slide_times = sorted(list(dict.fromkeys([round(t, 3) for t in chosen])))
                while len(slide_times) < num_slides:
                    slide_times.append(slide_times[-1] if slide_times else 0.0)
                if len(slide_times) > num_slides:
                    slide_times = slide_times[:num_slides]
        else:
            # detector found fewer than expected — pad last timestamp to keep indexing
            pad_count = num_slides - detected_count
            last = slide_times[-1] if slide_times else 0.0
            slide_times = list(slide_times) + [last] * pad_count
else:
    # No deck present — use the detected transitions as authoritative
    num_slides = max(1, detected_count)

# Keep a canonical alias used elsewhere
slide_timestamps = list(slide_times)

# ─── Load screengrab list and extract timestamps (do NOT truncate to num_slides) ───
sg_list_path = os.path.join(output_dir, filename + "_screengrabs.json")
screengrab_imgs = []
screengrab_times = []

if os.path.exists(sg_list_path):
    _sg_meta = mmap_read_json(sg_list_path, default=[]) or []
    for item in _sg_meta:
        # item can be a plain path string or a dict like {"path": "...", "t": 12.34}
        if isinstance(item, dict):
            p = item.get("path") or item.get("p") or item.get("file") or item.get("filename") or item.get("img")
            t = item.get("t") or item.get("time") or item.get("ts") or item.get("start")
            screengrab_imgs.append(p or "")
            try:
                screengrab_times.append(float(t) if t is not None else None)
            except Exception:
                screengrab_times.append(None)
        else:
            # assume a plain path or string timestamp representation
            try:
                s = str(item)
            except Exception:
                s = ""
            # Heuristic: if it looks like a number, treat as time placeholder; otherwise path
            try:
                _val = float(s)
                screengrab_imgs.append("")   # unknown path
                screengrab_times.append(_val)
            except Exception:
                screengrab_imgs.append(s)
                screengrab_times.append(None)
else:
    screengrab_imgs = []
    screengrab_times = []

# Normalize lists: ensure both are lists and have the same length; do NOT truncate screengrabs to num_slides.
if not isinstance(screengrab_imgs, list):
    screengrab_imgs = list(screengrab_imgs or [])
if not isinstance(screengrab_times, list):
    screengrab_times = list(screengrab_times or [])

if len(screengrab_times) < len(screengrab_imgs):
    screengrab_times += [None] * (len(screengrab_imgs) - len(screengrab_times))
elif len(screengrab_times) > len(screengrab_imgs):
    screengrab_times = screengrab_times[:len(screengrab_imgs)]

num_segments = len(screengrab_imgs)
_note(f"[Step 4] {num_segments} screengrab(s) loaded (from {sg_list_path}).")

# ─── AI helper (local Ollama) — set up early so alignment can use it too ─────
# (existing ProgressBar/_ai_cache/ollama_generate block remains unchanged and
# earlier in the file; this code assumes those helpers exist.)

# Extract slide text now (or create empty placeholders in screengrabs-only mode)
if USE_SCREENGRABS_ONLY:
    _note("[Step 4b] Screen-grabs only mode — no source slide text to extract.")
    slide_texts = [""] * num_slides
else:
    if slides_type == "pptx":
        slide_texts = extract_pptx_texts(slides_file)
    else:
        slide_texts = extract_pdf_texts(slides_file)
    _n_source = len(slide_texts)
    if _n_source != num_slides:
        # Keep all source slide texts/rendered images available for alignment.
        # We will reconcile counts after rendering rather than chopping text now.
        _warn(f"Slide count mismatch: source file has {_n_source} slides, video detection found {num_slides} transitions. "
              f"Keeping all {_n_source} source slides available for alignment (likely under-detection in video).")

# ─── Step 4: Render source slides to images ──────────────────────────────────
_step("Step 4/7 — Render source slides to images")
def render_pdf_to_image_files(path, out_dir, prefix, dpi=150):
    """Render PDF pages to PNG files. Tries pdftoppm first, falls back to PyMuPDF."""
    import subprocess, shutil as _shutil, glob as _glob
    paths = []

    pdftoppm_bin = _shutil.which("pdftoppm")
    if pdftoppm_bin:
        try:
            img_prefix = os.path.abspath(os.path.join(out_dir, f"{prefix}_source_slide"))
            subprocess.run(
                [pdftoppm_bin, "-r", str(dpi), "-png", path, img_prefix],
                check=True, capture_output=True
            )
            found = sorted(_glob.glob(f"{img_prefix}-*.png"))
            if found:
                for j, old_p in enumerate(found):
                    new_p = os.path.join(out_dir, f"{prefix}_source_slide_{j:03d}.png")
                    os.rename(old_p, new_p)
                    paths.append(new_p)
                return paths
        except Exception:
            pass  # fall through to PyMuPDF

    try:
        doc = fitz.open(path)
    except Exception as _fitz_path_err:
        # Path-open → mmap-stream fallback
        with open(path, "rb") as _f:
            with mmap.mmap(_f.fileno(), 0, access=mmap.ACCESS_READ) as _mm:
                doc = fitz.open(stream=_mm, filetype="pdf")
    try:
        for i, page in enumerate(doc):
            pix = page.get_pixmap(dpi=dpi)
            img = PILImage.frombytes("RGB", [pix.width, pix.height], pix.samples)
            out_path = os.path.join(out_dir, f"{prefix}_source_slide_{i:03d}.png")
            img.save(out_path, format="PNG", optimize=True)
            paths.append(out_path)
    finally:
        doc.close()
    return paths

def render_pptx_to_image_files(pptx_path, out_dir, prefix, dpi=150):
    """Convert PPTX → PDF via LibreOffice, then render to PNG. Returns list of file paths."""
    import subprocess, tempfile, shutil, glob
    tmp_dir = tempfile.mkdtemp()
    profile_dir = None
    try:
        lo_bin = (
            shutil.which("libreoffice")
            or shutil.which("soffice")
            or "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        )

        result1 = subprocess.run(
            [lo_bin, "--headless", "--convert-to", "pdf",
             "--outdir", tmp_dir, pptx_path],
            capture_output=True, text=True
        )
        pdfs = glob.glob(os.path.join(tmp_dir, "*.pdf"))

        if not pdfs:
            _note("[Step 4] LibreOffice: no PDF on first attempt — retrying with fresh profile...")
            profile_dir = tempfile.mkdtemp()
            result2 = subprocess.run(
                [lo_bin, "--headless",
                 f"-env:UserInstallation=file://{profile_dir}",
                 "--convert-to", "pdf",
                 "--outdir", tmp_dir, pptx_path],
                capture_output=True, text=True
            )
            pdfs = glob.glob(os.path.join(tmp_dir, "*.pdf"))

            if not pdfs:
                lo_out = (
                    f"--- attempt 1 stdout ---\n{result1.stdout}\n"
                    f"--- attempt 1 stderr ---\n{result1.stderr}\n"
                    f"--- attempt 2 stdout ---\n{result2.stdout}\n"
                    f"--- attempt 2 stderr ---\n{result2.stderr}"
                )
                raise RuntimeError(
                    f"LibreOffice failed to produce a PDF from '{pptx_path}' after two attempts.\n"
                    f"Try exporting the file to PDF manually.\n\n{lo_out}"
                )

        pdf_path = pdfs[0]
        return render_pdf_to_image_files(pdf_path, out_dir, prefix, dpi=dpi)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        if profile_dir:
            shutil.rmtree(profile_dir, ignore_errors=True)

# Render or reuse screengrabs as source images
if USE_SCREENGRABS_ONLY:
    print("\n  [Step 4] Screen-grabs only mode — skipping source slide rendering.", flush=True)
    slide_source_imgs = list(screengrab_imgs)
    available = sum(1 for p in slide_source_imgs if p and os.path.exists(p))
    _note(f"[Step 4] {available} screengrab image(s) available (out of {len(slide_source_imgs)} expected).")
else:
    source_slides_dir = os.path.join(output_dir, filename + "_source_slides")
    os.makedirs(source_slides_dir, exist_ok=True)
    print("\n  [Step 4] Rendering source slide images...", flush=True)
    try:
        if slides_type == "pdf":
            slide_source_imgs = render_pdf_to_image_files(slides_file, source_slides_dir, filename)
        else:
            slide_source_imgs = render_pptx_to_image_files(slides_file, source_slides_dir, filename)
    except Exception as e_render:
        _err(f"ERROR rendering source slides: {e_render}")
        slide_source_imgs = []

    for _k, _p in enumerate(slide_source_imgs):
        print(f"  Source slide {_k+1} (base deck): {_p}", flush=True)
    _note(f"[Step 4] {len(slide_source_imgs)} source slide image(s) rendered.")
    _ok(f"Source slides saved to: {source_slides_dir}")

# --- Sanity: ensure the key lists all have a slot per target slide (num_slides) ---
def _pad_or_truncate_list(lst, target_len, name):
    if lst is None:
        lst = []
    if len(lst) < target_len:
        _warn(f"{name} shorter than target slides ({len(lst)} < {target_len}) — padding with placeholders.")
        lst = list(lst) + [""] * (target_len - len(lst))
    elif len(lst) > target_len:
        _warn(f"{name} longer than target slides ({len(lst)} > {target_len}) — truncating to {target_len}.")
        lst = lst[:target_len]
    return lst

# If rendered source count differs from num_slides, reconcile now while preserving all detected screengrabs.
rendered_count = len(slide_source_imgs) if isinstance(slide_source_imgs, (list, tuple)) else 0
# Treat screengrab count (num_segments) separately from source slide count (num_slides).
num_segments = len(screengrab_imgs) if isinstance(screengrab_imgs, (list, tuple)) else 0

if rendered_count and rendered_count != num_slides:
    _warn(f"Rendered source slides ({rendered_count}) != target slides ({num_slides}). Reconciling (source deck is authoritative).")

    # Make the rendered deck the authoritative source-slide count
    num_slides = rendered_count

    # Adjust slide_times to match num_slides without losing meaningful timestamps:
    try:
        if len(slide_times) > num_slides:
            # Choose timestamps closest to evenly-spaced positions across the lecture
            total_duration = slide_times[-1] if slide_times else (globals().get("video_duration") or 0.0)
            if total_duration <= 0 or num_slides == 1:
                slide_times = slide_times[:num_slides]
            else:
                chosen = []
                for k in range(num_slides):
                    target = (k / (num_slides - 1)) * total_duration if num_slides > 1 else 0.0
                    closest = min(slide_times, key=lambda t: abs(t - target))
                    chosen.append(closest)
                # dedupe, sort, enforce exact length
                slide_times = sorted(list(dict.fromkeys([round(float(t), 3) for t in chosen])))
                while len(slide_times) < num_slides:
                    slide_times.append(slide_times[-1] if slide_times else 0.0)
                if len(slide_times) > num_slides:
                    slide_times = slide_times[:num_slides]
        elif len(slide_times) < num_slides:
            pad_val = slide_times[-1] if slide_times else 0.0
            slide_times = list(slide_times) + [pad_val] * (num_slides - len(slide_times))
    except Exception:
        slide_times = [0.0] + [0.0] * (num_slides - 1)

    # Do NOT truncate screengrab_imgs here. Alignment must score every detected screengrab.
    # Ensure screengrab_imgs has at least num_segments entries (pad if missing placeholders).
    if num_segments < (len(slide_times) if slide_times else 0):
        num_segments = max(num_segments, len(slide_times))
    if len(screengrab_imgs) < num_segments:
        screengrab_imgs += [""] * (num_segments - len(screengrab_imgs))

# Final pad/truncate for alignment lists (source-side lists should match num_slides)
slide_source_imgs = _pad_or_truncate_list(slide_source_imgs, num_slides, "slide_source_imgs")

# For screengrabs: do not truncate to num_slides — keep every detected segment.
# But if screengrab_imgs is shorter than the number of detected segments, pad placeholders.
if not isinstance(screengrab_imgs, list):
    screengrab_imgs = []
# Let num_segments reflect actual screengrab count after any padding
num_segments = len(screengrab_imgs)

# Slide texts: prefer full source list (do not truncate to num_slides), but ensure indexing won't break
if 'slide_texts' not in globals() or slide_texts is None:
    slide_texts = [""] * num_slides
else:
    # Keep whatever full slide_texts exist, but pad to at least num_slides for safe indexing
    if len(slide_texts) < num_slides:
        slide_texts += [""] * (num_slides - len(slide_texts))

# Keep slide_timestamps alias in sync with slide_times
slide_timestamps = list(slide_times)

print(f"  INFO: num_slides={num_slides}, num_segments={num_segments}, screengrab_imgs={len(screengrab_imgs)}, slide_source_imgs={len(slide_source_imgs)}, slide_texts={len(slide_texts)}", flush=True)

# If a large fraction of source slide images failed to render, handle conservatively:
_failed_source_loads = [p for p in slide_source_imgs if not p or not os.path.exists(p)]
_bad_frac = (len(_failed_source_loads) / max(1, len(slide_source_imgs))) if slide_source_imgs else 1.0
if _bad_frac >= 0.4:
    valid_count = len([p for p in slide_source_imgs if p and os.path.exists(p)])
    if valid_count >= 1:
        _warn("Many source slides failed to render, but some valid renders exist — adjusting target to rendered valid count.")
        # Reduce num_slides to the count of valid renders, but still preserve all screengrabs.
        num_slides = valid_count
        slide_source_imgs = [p for p in slide_source_imgs if p and os.path.exists(p)]
        # Reconcile slide_times to num_slides (trim/pad conservatively)
        if len(slide_times) > num_slides:
            slide_times = slide_times[:num_slides]
        elif len(slide_times) < num_slides:
            slide_times += [slide_times[-1] if slide_times else 0.0] * (num_slides - len(slide_times))
        # Ensure slide_texts is padded/truncated appropriately (do not discard extra source texts if present)
        if len(slide_texts) > num_slides:
            slide_texts = slide_texts[:num_slides]
        else:
            slide_texts += [""] * max(0, num_slides - len(slide_texts))
        slide_timestamps = list(slide_times)
    else:
        _err("ERROR: too many source slide images failed to render or are missing. This will break alignment.")
        print("      Missing sample(s):", flush=True)
        for idx, p in enumerate(slide_source_imgs[:10]):
            print(f"        {idx+1}: {p}", flush=True)
        print("  Suggestion: re-run Step 3 (regenerate screengrabs) and ensure LibreOffice / pdftoppm rendered the source slides correctly.", flush=True)
        raise SystemExit(2)

# Canonicalise lists (ensure they are plain lists)
slide_timestamps = list(slide_times)
screengrab_imgs = list(screengrab_imgs)
slide_source_imgs = list(slide_source_imgs)
slide_texts = list(slide_texts)


# ─── Step 5: Align screengrabs → source slides ───────────────────────────────
_step("Step 5/7 — Align screengrabs to source slides")

def _load_gray_thumbnail(path, size=(256, 144), mask_webcam=False):
    """Load an image as a grayscale thumbnail. Returns None on any failure."""
    import cv2 as _cv2
    try:
        if not path or not os.path.exists(path):
            return None
        img = _cv2.imread(path)
        if img is None or img.size == 0:
            return None
        img = _cv2.resize(img, size, interpolation=_cv2.INTER_AREA)
        gray = _cv2.cvtColor(img, _cv2.COLOR_BGR2GRAY)
    except Exception as _load_err:
        _warn(f"Could not load/decode image, skipping ({path}): {_load_err}")
        return None

    try:
        _clahe = _cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray = _clahe.apply(gray)
    except Exception:
        pass

    try:
        if mask_webcam and 'WEBCAM_MASK_FRAC' in globals():
            _h, _w = gray.shape
            _frac = float(WEBCAM_MASK_FRAC)
            gray[int(_h * (1 - _frac)):, int(_w * (1 - _frac)):] = 128
    except Exception:
        pass
    return gray

def _compare_with_masks(sg_gray, src_gray):
    """Blended similarity score (SSIM + NCC + optional pixelmatch) with multiple corner masks."""
    import numpy as _np
    try:
        import cv2 as _cv2
    except Exception:
        _cv2 = None
    HIGH_CONF_EARLY_EXIT = 0.85
    try:
        h, w = sg_gray.shape
    except Exception:
        return 0.0, "none"
    _mf = globals().get("WEBCAM_MASK_FRAC", 0.20)
    masks = [
        ("bottom_right", slice(int(h * (1 - _mf)), h), slice(int(w * (1 - _mf)), w)),
        ("bottom_left",  slice(int(h * (2/3)), h),         slice(0, int(w/3))),
        ("top_right",    slice(0, int(h/3)),               slice(int(w * (2/3)), w)),
        ("top_left",     slice(0, int(h/3)),               slice(0, int(w/3))),
        ("bottom_third", slice(int(h * (2/3)), h),         slice(0, w)),
        ("bottom_half",  slice(int(h/2), h),               slice(0, w)),
        ("none",         None,                             None),
    ]
    best_score = -1.0
    best_mask = "none"

    for name, rs, cs in masks:
        sg = sg_gray.copy()
        src = src_gray.copy()
        if rs is not None:
            try:
                sg[rs, cs] = 128
            except Exception:
                pass

        # SSIM
        try:
            from skimage.metrics import structural_similarity as _ssim
            ssim_score = float(_ssim(sg, src, data_range=255))
        except Exception:
            try:
                sgf = sg.astype(_np.float32) - sg.mean()
                srcf = src.astype(_np.float32) - src.mean()
                denom = float(_np.std(sgf) * _np.std(srcf))
                ssim_score = float((_np.sum(sgf * srcf) / sgf.size) / denom) if denom > 1e-3 else 0.0
            except Exception:
                ssim_score = 0.0

        # NCC (matchTemplate)
        try:
            if _cv2 is not None:
                res = _cv2.matchTemplate(sg.astype(_np.float32), src.astype(_np.float32), _cv2.TM_CCOEFF_NORMED)
                ncc_score = float(res.max())
            else:
                ncc_score = ssim_score
        except Exception:
            ncc_score = ssim_score

        # pixelmatch (best-effort)
        pixel_score = None
        try:
            from pixelmatch import pixelmatch as _pixelmatch
            _rgba1 = _np.dstack([sg, sg, sg, _np.full_like(sg, 255)]).flatten().tolist()
            _rgba2 = _np.dstack([src, src, src, _np.full_like(src, 255)]).flatten().tolist()
            mismatched = _pixelmatch(_rgba1, _rgba2, w, h, threshold=0.15)
            pixel_score = 1.0 - (mismatched / float(w * h))
        except Exception:
            pixel_score = None

        if pixel_score is not None:
            score = 0.55 * ssim_score + 0.30 * ncc_score + 0.15 * pixel_score
        else:
            score = 0.65 * ssim_score + 0.35 * ncc_score

        if score > best_score:
            best_score = score
            best_mask = name

        if best_score >= HIGH_CONF_EARLY_EXIT:
            break

    return best_score, best_mask

def _is_near_black(gray, mean_threshold=14.0):
    import numpy as _np
    try:
        return bool(_np.mean(gray) < mean_threshold)
    except Exception:
        return False

_ocr_cache = {}

def _ocr_text_for_image(path):
    if not globals().get("_OCR_AVAILABLE"):
        return ""
    if not path:
        return ""
    if path in _ocr_cache:
        return _ocr_cache[path]
    text = ""
    try:
        import pytesseract
        from PIL import Image as _PILImage
        img = _PILImage.open(path)
        text = pytesseract.image_to_string(img) or ""
    except Exception:
        text = ""
    _ocr_cache[path] = text
    return text

def _normalize_words(text):
    import re as _re
    return [w for w in _re.findall(r"[a-z0-9]+", (text or "").lower()) if len(w) > 1]

def _text_similarity(a, b):
    if not a or not b:
        return 0.0
    import difflib as _difflib
    words_a, words_b = set(_normalize_words(a)), set(_normalize_words(b))
    if not words_a or not words_b:
        return 0.0
    overlap = len(words_a & words_b) / max(1, len(words_a | words_b))
    ratio = _difflib.SequenceMatcher(None, a[:1000], b[:1000]).ratio()
    return 0.5 * overlap + 0.5 * ratio

def compute_alignment(screengrab_imgs, slide_source_imgs, slide_texts=None):
    """Compute DP-based monotonic alignment; returns list of alignment dicts."""
    n_sg = len(screengrab_imgs)
    n_src = len(slide_source_imgs)
    if n_sg == 0 or n_src == 0:
        return []

    _note(f"[Step 5] compute_alignment: comparing {n_sg} screengrabs -> {n_src} source slides")

    src_grays = [_load_gray_thumbnail(p) if (p and os.path.exists(p)) else None for p in slide_source_imgs]
    sg_grays = [_load_gray_thumbnail(p, mask_webcam=True) if (p and os.path.exists(p)) else None for p in screengrab_imgs]

    # Flags for near-black screengrabs
    black_flags = [g is not None and _is_near_black(g) for g in sg_grays]
    if any(black_flags):
        black_idxs = [i for i,f in enumerate(black_flags) if f]
        _warn(f"{len(black_idxs)} screengrab(s) look near-black: {[i+1 for i in black_idxs]}")

    # Banding for large matrices
    MAX_CELLS = globals().get("MAX_CELLS", 12000)
    band = None
    if n_sg * n_src > MAX_CELLS:
        band = max(8, MAX_CELLS // max(n_sg, 1))
        print(f"  Large deck — limiting comparisons to ±{band} slides around expected positions.", flush=True)

    NEUTRAL = 0.0
    S = [[NEUTRAL] * n_src for _ in range(n_sg)]
    mask_used = [["none"] * n_src for _ in range(n_sg)]

    have_texts = bool(slide_texts)
    sg_ocr_texts = [None] * n_sg
    if have_texts:
        print("  OCR'ing screengrabs for text tie-breaks...", flush=True)
        for i, p in enumerate(screengrab_imgs):
            if p and os.path.exists(p) and not black_flags[i]:
                sg_ocr_texts[i] = _ocr_text_for_image(p)

    # Boilerplate filter
    _BOILERPLATE_WORDS = set()
    if have_texts and n_src > 2:
        _df = {}
        for t in slide_texts:
            for w in set(_normalize_words(t or "")):
                _df[w] = _df.get(w, 0) + 1
        _BOILERPLATE_WORDS = {w for w,c in _df.items() if c > max(2, n_src * 0.5)}

    # Tunables
    IMG_WEIGHT = 0.65
    TEXT_WEIGHT = 0.35
    _TEXT_STRONG_FLOOR = globals().get("TEXT_STRONG_FLOOR", 6)

    # Score matrix fill
    for i in range(n_sg):
        print(f"  Scoring screengrab {i+1}/{n_sg}...", end=" ", flush=True)
        if sg_grays[i] is None:
            print("no screengrab image", flush=True)
            continue
        if band is not None:
            center = int(round(i * (n_src - 1) / max(n_sg - 1, 1)))
            lo, hi = max(0, center - band), min(n_src - 1, center + band)
            j_range = range(lo, hi + 1)
        else:
            j_range = range(n_src)
        n_scored = 0
        if black_flags[i]:
            print("near-black — skipping visual scoring", flush=True)
            continue
        row_overlaps = {}
        for j in j_range:
            if src_grays[j] is None:
                continue
            img_score, mask_name = _compare_with_masks(sg_grays[i], src_grays[j])
            score = img_score
            if have_texts and sg_ocr_texts[i] and slide_texts[j].strip():
                txt_score = _text_similarity(sg_ocr_texts[i], slide_texts[j])
                score = IMG_WEIGHT * img_score + TEXT_WEIGHT * txt_score
                distinctive_overlap = (set(_normalize_words(sg_ocr_texts[i])) - _BOILERPLATE_WORDS) & (set(_normalize_words(slide_texts[j])) - _BOILERPLATE_WORDS)
                if len(distinctive_overlap) >= 5 and img_score >= 0.12:
                    row_overlaps[j] = len(distinctive_overlap)
            S[i][j] = score
            mask_used[i][j] = mask_name
            n_scored += 1
        if row_overlaps:
            sorted_over = sorted(row_overlaps.items(), key=lambda kv: kv[1], reverse=True)
            best_j, best_n = sorted_over[0]
            second_n = sorted_over[1][1] if len(sorted_over) > 1 else 0
            if best_n >= _TEXT_STRONG_FLOOR and best_n >= 2 * max(second_n, 1):
                boosted = min(0.97, 0.55 + 0.01 * best_n)
                if boosted > S[i][best_j]:
                    S[i][best_j] = boosted
        print(f"scored against {n_scored}", flush=True)

    # Strong-text matches reporting
    # (we can re-run detection of strong matches if desired; already applied per-row)

    # Dynamic programming: compute best non-decreasing path
    # dp optimization: running best prefix
    dp = list(S[0])
    choice = [[0] * n_src for _ in range(n_sg)]
    for i in range(1, n_sg):
        running_best = float("-inf")
        running_best_idx = 0
        running_max = [0.0] * n_src
        running_from = [0] * n_src
        for j in range(n_src):
            if dp[j] > running_best:
                running_best = dp[j]
                running_best_idx = j
            running_max[j] = running_best
            running_from[j] = running_best_idx
        new_dp = [S[i][j] + running_max[j] for j in range(n_src)]
        choice[i] = running_from
        dp = new_dp

    end_j = max(range(n_src), key=lambda j: dp[j])
    path = [0] * n_sg
    path[n_sg - 1] = end_j
    for i in range(n_sg - 1, 0, -1):
        end_j = choice[i][end_j]
        path[i - 1] = end_j

    alignment = []
    for i in range(n_sg):
        j = path[i]
        score = S[i][j]
        row_sorted = sorted(S[i], reverse=True)
        second_best = row_sorted[1] if len(row_sorted) > 1 else 0.0
        alignment.append({
            "screengrab_index": i,
            "source_slide_index": j,
            "score": round(float(score), 4),
            "second_best_score": round(float(second_best), 4),
            "mask_region": mask_used[i][j],
            "near_black": black_flags[i],
        })
        print(f"  Screengrab {i+1}/{n_sg} → src slide {j+1}  score={score:.3f} (runner-up {second_best:.3f}) mask={mask_used[i][j]}", flush=True)

    # Check for pathological collapse
    if n_sg >= 4:
        from collections import Counter
        dest_counts = Counter(path)
        top_j, top_n = dest_counts.most_common(1)[0]
        if top_n / n_sg >= 0.6:
            failed_src = [j for j,g in enumerate(src_grays) if g is None]
            _warn(f"ALIGNMENT LOOKS BROKEN: {top_n}/{n_sg} screengrabs matched source slide {top_j+1}.")
            if failed_src:
                print(f"      {len(failed_src)}/{n_src} source slide images failed to load: {[j+1 for j in failed_src]}", flush=True)
                print(f"      Files: {[slide_source_imgs[j] for j in failed_src[:5]]}{' ...' if len(failed_src)>5 else ''}", flush=True)
            else:
                print("      All source images loaded — this may be near-identical templated slides; ensure OCR is available.", flush=True)

    return alignment

def _find_stuck_runs(alignment, min_len=3):
    runs = []
    i = 0
    n = len(alignment)
    while i < n:
        j = i
        while j + 1 < n and alignment[j + 1]["source_slide_index"] == alignment[i]["source_slide_index"]:
            j += 1
        if j - i + 1 >= min_len:
            runs.append((i, j))
        i = j + 1
    return runs

def _reenforce_monotonic(alignment):
    floor = -1
    fixed = 0
    for entry in alignment:
        j = entry.get("source_slide_index")
        if j is None:
            continue
        if j < floor:
            _warn(f"Ollama re-check placed screengrab {entry['screengrab_index']+1} at slide {j+1}, out of sequence after slide {floor+1} — reverting.")
            entry["source_slide_index"] = floor
            entry["mask_region"] = f"{entry.get('mask_region','none')}+order_corrected"
            fixed += 1
            j = floor
        floor = max(floor, j)
    if fixed:
        _warn(f"{fixed} Ollama re-check(s) were reverted to keep slide order consistent.")
    return alignment
# Ensure 'segments' (Whisper transcript segments) exists and is well-formed
if 'segments' not in globals() or not isinstance(segments, (list, tuple)):
    try:
        segments = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []
    except Exception:
        segments = []

# Normalise each segment to have numeric 'start' and 'text' keys
_normalised_segs = []
for s in (segments or []):
    try:
        start = float(s.get("start", s.get("t", 0))) if isinstance(s, dict) else 0.0
    except Exception:
        try:
            start = float(s[0]) if isinstance(s, (list, tuple)) and s else 0.0
        except Exception:
            start = 0.0
    text = ""
    try:
        if isinstance(s, dict):
            text = (s.get("text") or s.get("txt") or "").strip()
        elif isinstance(s, (list, tuple)) and len(s) > 1:
            text = str(s[1]).strip()
        else:
            text = str(s).strip()
    except Exception:
        text = ""
    _normalised_segs.append({"start": round(start, 3), "text": text})
segments = _normalised_segs

# Ensure 'segments' (Whisper transcript segments) exists and is well-formed
if 'segments' not in globals() or not isinstance(segments, (list, tuple)):
    try:
        segments = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []
    except Exception:
        segments = []

# Normalise each segment to have numeric 'start' and 'text' keys
_normalised_segs = []
for s in (segments or []):
    try:
        if isinstance(s, dict):
            # common dict shapes: {"start": 12.34, "text": "..."} or {"t":12.34, "text": "..."}
            start = float(s.get("start", s.get("t", 0)))
            text = (s.get("text") or s.get("txt") or "").strip()
        elif isinstance(s, (list, tuple)) and len(s) >= 2:
            # e.g. [start, text]
            start = float(s[0])
            text = str(s[1]).strip()
        else:
            start = 0.0
            text = str(s).strip()
    except Exception:
        # fallback for weird shapes
        try:
            start = float(s[0]) if isinstance(s, (list, tuple)) and s else 0.0
        except Exception:
            start = 0.0
        try:
            text = str(s[1]) if isinstance(s, (list, tuple)) and len(s) > 1 else (s.get("text") if isinstance(s, dict) else str(s))
            text = (text or "").strip()
        except Exception:
            text = ""
    _normalised_segs.append({"start": round(start, 3), "text": text})

# Sort by start and dedupe very-close timestamps (within 5ms) to avoid zero-length intervals
_normalised_segs.sort(key=lambda x: x["start"])
_clean = []
_prev = None
_tol = 0.005
for seg in _normalised_segs:
    if _prev is None or abs(seg["start"] - _prev["start"]) > _tol:
        _clean.append(seg)
        _prev = seg
    else:
        # merge texts if duplicates are found at nearly identical timestamps
        _prev["text"] = (_prev.get("text", "") + " " + seg.get("text", "")).strip()

segments = _clean

def ollama_verify_alignment(alignment, slide_texts, slide_times, segments, screengrab_imgs=None):
    """Semantic verification of ambiguous matches using Ollama (if enabled)."""
    if not globals().get("AI_ENABLED") or not alignment or not callable(globals().get("ollama_generate")):
        return alignment

    LOW_CONF = 0.42
    MARGIN_THRESH = 0.06
    STUCK_RUN_MIN = 3
    WINDOW = 5
    n_src = len(slide_texts)
    n_sg = len(alignment)
    resolved = 0

    stuck_idxs = set()
    for start, end in _find_stuck_runs(alignment, STUCK_RUN_MIN):
        for k in range(start + 1, end + 1):
            stuck_idxs.add(k)
    if stuck_idxs:
        _warn(f"{len(stuck_idxs)} screengrab(s) in repeated-match runs will get semantic re-checks.")

    def _spoken_between(a, b):
        return " ".join(s.get("text","").strip() for s in segments if a <= s.get("start",0) < b).strip()

    for i, entry in enumerate(alignment):
        margin = entry["score"] - entry.get("second_best_score", 0.0)
        needs_help = (entry["score"] < LOW_CONF) or entry.get("near_black") or margin < MARGIN_THRESH or i in stuck_idxs
        if not needs_help or n_src == 0:
            continue

        center = entry.get("source_slide_index", 0)
        lo, hi = max(0, center - WINDOW), min(n_src - 1, center + WINDOW)
        candidates = [c for c in range(lo, hi + 1) if slide_texts[c].strip() or (c < len(slide_source_imgs) and slide_source_imgs[c])]
        if len(candidates) <= 1:
            continue

        # Robustly determine a time window for this screengrab.
        # 1) Prefer explicit screengrab timestamps if available (screengrab_times or screengrab metadata).
        # 2) Else map the screengrab index proportionally across video_duration (if known).
        # 3) Else fall back to mapping to the nearest slide_time entry when possible.
        sg_times = globals().get("screengrab_times")
        if not sg_times and isinstance(screengrab_imgs, (list, tuple)):
            # attempt to extract times from screengrab metadata if entries are dicts
            sg_times = []
            for item in screengrab_imgs:
                tval = None
                if isinstance(item, dict):
                    for k in ("t", "time", "ts", "start"):
                        if k in item:
                            tval = item.get(k)
                            break
                sg_times.append(float(tval) if tval is not None else None)

        start_t = None
        end_t = None
        if isinstance(sg_times, (list, tuple)) and i < len(sg_times) and sg_times[i] is not None:
            # use screengrab timestamp and the next one (if present) as the interval
            start_t = float(sg_times[i])
            end_t = float(sg_times[i+1]) if (i + 1) < len(sg_times) and sg_times[i+1] is not None else (start_t + 5.0)
        else:
            # no screengrab timestamp available — try proportional mapping
            try:
                n_sg_local = len(alignment)
                if 'video_duration' in globals() and isinstance(video_duration, (int, float)) and video_duration > 0 and n_sg_local > 1:
                    frac = (i / max(1, n_sg_local - 1))
                    tguess = frac * float(video_duration)
                    start_t = max(0.0, tguess - 2.0)
                    end_t = tguess + 2.0
                else:
                    # map screengrab index into the slide_times index space as a best-effort guess
                    if isinstance(slide_times, (list, tuple)) and len(slide_times):
                        mapped_idx = int(round(i * (len(slide_times) - 1) / max(1, n_sg_local - 1)))
                        mapped_idx = max(0, min(len(slide_times) - 1, mapped_idx))
                        start_t = float(slide_times[mapped_idx])
                        end_t = float(slide_times[mapped_idx + 1]) if (mapped_idx + 1) < len(slide_times) else (start_t + 5.0)
                    else:
                        start_t = 0.0
                        end_t = 5.0
            except Exception:
                start_t = 0.0
                end_t = 5.0

        # Primary spoken window; if empty, try a slightly larger nearby window before skipping
        spoken = _spoken_between(start_t, end_t)
        if not spoken:
            alt_start = max(0.0, start_t - 5.0)
            alt_end = (end_t + 5.0) if end_t != float("inf") else (start_t + 10.0)
            spoken = _spoken_between(alt_start, alt_end)
            if not spoken:
                # no transcript available for this screengrab — skip semantic check
                continue

        prev_spoken = _spoken_between(max(0.0, start_t - 45), start_t)
        next_spoken = _spoken_between(end_t, end_t + 45) if end_t != float("inf") else ""

        ocr_text = ""
        if screengrab_imgs and i < len(screengrab_imgs) and screengrab_imgs[i]:
            ocr_text = _ocr_text_for_image(screengrab_imgs[i]).strip()

        # Build prompt with descriptors and optional tiny thumb (size-guarded)
        candidates_block_lines = []
        for c in candidates:
            slide_txt_short = (slide_texts[c].strip()[:300]) if c < len(slide_texts) else ""
            cand_img = slide_source_imgs[c] if c < len(slide_source_imgs) else None
            cand_vis = {}
            try:
                cand_vis = _image_visual_descriptor(cand_img) if cand_img else {}
            except Exception:
                cand_vis = {}
            cand_vis_str = ", ".join(f"{k}={v}" for k,v in cand_vis.items() if v is not None)
            candidates_block_lines.append(f"{c+1}) {slide_txt_short}  [{cand_vis_str}]")

        s_img = screengrab_imgs[i] if screengrab_imgs and i < len(screengrab_imgs) else None
        sg_vis = {}
        try:
            sg_vis = _image_visual_descriptor(s_img) if s_img else {}
        except Exception:
            sg_vis = {}
        sg_vis_str = ", ".join(f"{k}={v}" for k,v in sg_vis.items() if v is not None)
        sg_thumb = ""
        try:
            tmp = _small_base64_thumbnail(s_img) if s_img else ""
            if tmp and len(tmp.encode("utf-8")) < 80_000:
                sg_thumb = tmp
        except Exception:
            sg_thumb = ""

        context_lines = []
        if prev_spoken:
            context_lines.append(f"(just before) \"{prev_spoken[-400:]}\"")
        context_lines.append(f"(this moment) \"{spoken[:1500]}\"")
        if next_spoken:
            context_lines.append(f"(just after) \"{next_spoken[:400]}\"")
        spoken_block = "\n".join(context_lines)

        ocr_block = f"\nText OCR read from screengrab:\n\"{ocr_text[:400]}\"\n" if ocr_text else ""
        vis_block = f"\nScreengrab descriptors: {sg_vis_str}\n"
        thumb_block = f"\nScreengrab tiny data-uri included below (may be ignored by model):\n{sg_thumb}\n" if sg_thumb else ""

        options_block = "\n".join(candidates_block_lines)
        prompt = (
            "A lecture recording's automatic slide-detection was ambiguous for one "
            "moment. Use the spoken transcript (context), any OCR from the screengrab, "
            "and the candidate slide texts to pick the best candidate number.\n\n"
            f"{spoken_block}\n"
            f"{ocr_block}\n"
            f"{vis_block}\n"
            f"{thumb_block}\n"
            f"Candidates:\n{options_block}\n\n"
            "Reply with exactly one integer: the candidate number (e.g. '3'), or '0' if none match."
        )

        result = ollama_generate(prompt, timeout=60, context=f"screengrab {i+1} alignment")
        if not result:
            continue
        import re as _re
        m = _re.search(r"\d+", result)
        if not m:
            continue
        picked_raw = int(m.group())
        if picked_raw == 0:
            _ai(f"Ollama: screengrab {i+1} judged to match none — will use video screengrab.")
            entry["use_screengrab"] = True
            entry["mask_region"] = f"{entry.get('mask_region','none')}+ai_no_match"
            resolved += 1
            continue
        picked = picked_raw - 1
        if picked in candidates and picked != center:
            _ai(f"Ollama re-aligned screengrab {i+1}: {center+1} → {picked+1}")
            entry["source_slide_index"] = picked
            entry["score"] = max(entry.get("score", 0.0), 0.5)
            entry["mask_region"] = f"{entry.get('mask_region','none')}+ai_verified"
            resolved += 1

    if resolved:
        _ai(f"Ollama alignment verification resolved {resolved} ambiguous match(es).")
    return _reenforce_monotonic(alignment)

def apply_screengrab_fallback(alignment, threshold=None):
    """Flag entries with no plausible match to use screengrabs instead."""
    if threshold is None:
        threshold = globals().get("NO_MATCH_FLOOR", 0.25)
    flagged = 0
    for i, entry in enumerate(alignment):
        if entry.get("use_screengrab"):
            continue
        if entry.get("near_black"):
            continue
        if float(entry.get("score", 0.0)) >= threshold:
            continue

        should_force = True
        if globals().get("AI_ENABLED") and callable(globals().get("ollama_generate")):
            try:
                sg_img = screengrab_imgs[i] if (isinstance(screengrab_imgs, (list, tuple)) and i < len(screengrab_imgs)) else None
                sg_vis = {}
                try:
                    sg_vis = _image_visual_descriptor(sg_img) if sg_img else {}
                except Exception:
                    sg_vis = {}
                try:
                    best_text = get_slide_text_for_index(i)[:400]
                except Exception:
                    best_text = ""
                prompt_base = (f"Screengrab at {fmt_ts(slide_times[i])} has low match scores.\n"
                               f"Descriptors: {sg_vis}\nBest-matching slide text: {best_text}\n\n"
                               "Based on transcript/OCR, is this screengrab present in the source deck? Reply YES or NO.")
                prompt = prompt_base
                try:
                    tmp = _small_base64_thumbnail(sg_img) if sg_img else ""
                    if tmp and len((prompt_base + tmp).encode("utf-8")) < 150_000:
                        prompt = prompt_base + "\n\nScreengrab attached.\n" + tmp
                except Exception:
                    prompt = prompt_base

                cache_key = f"no_match_check_{i}_{round(slide_times[i],1)}"
                reply = None
                if isinstance(globals().get("_ai_cache"), dict) and cache_key in _ai_cache:
                    reply = _ai_cache[cache_key]
                else:
                    reply = ollama_generate(prompt, timeout=20, context=f"no-match {i+1}")
                    try:
                        if isinstance(globals().get("_ai_cache"), dict):
                            _ai_cache[cache_key] = reply
                            if callable(globals().get("_save_ai_cache")):
                                _save_ai_cache()
                    except Exception:
                        pass
                if reply and isinstance(reply, str) and reply.strip().lower().startswith("y"):
                    _ai(f"Ollama no-match check: screengrab {i+1} -> KEEP")
                    should_force = False
                else:
                    _ai(f"Ollama no-match check: screengrab {i+1} -> FALLBACK")
            except Exception as e_ai:
                _warn(f"Ollama fallback check failed for screengrab {i+1}: {e_ai} — proceeding with fallback.")
                should_force = True

        if should_force:
            entry["use_screengrab"] = True
            flagged += 1

    if flagged:
        _warn(f"{flagged} screengrab(s) flagged to show actual video frames (score < {threshold}).")
    return alignment

# Run alignment
_skipped_slide_indices = []
if globals().get("USE_SCREENGRABS_ONLY"):
    print("\n  [Step 5] Screen-grabs only mode — 1:1 identity alignment.", flush=True)
    alignment = [{"screengrab_index": i, "source_slide_index": i, "score": 1.0, "mask_region": "none"} for i in range(len(screengrab_imgs))]
else:
    print("\n  [Step 5] Building slide alignment (screengrab → source slide)...", flush=True)
    alignment = compute_alignment(screengrab_imgs, slide_source_imgs, slide_texts=slide_texts)
    if globals().get("AI_ENABLED"):
        print("\n  [Step 5b] Ollama verification pass on ambiguous matches...", flush=True)
        alignment = ollama_verify_alignment(alignment, slide_texts, slide_times, segments, screengrab_imgs=screengrab_imgs)
    alignment = apply_screengrab_fallback(alignment)

align_json_path = os.path.join(output_dir, filename + "_slide_alignment.json")
try:
    with open(align_json_path, "w") as _f:
        json.dump(alignment, _f, indent=2)
except Exception:
    pass

if alignment:
    _scores = [e["score"] for e in alignment if e.get("score", 0) > 0]
    _avg_score = sum(_scores) / len(_scores) if _scores else 0.0
    print(f"  Alignment: {len(alignment)} segments  avg_score={_avg_score:.3f}", flush=True)
    if not globals().get("USE_SCREENGRABS_ONLY"):
        _LOW_CONF = 0.40
        _low_conf = [e["screengrab_index"] for e in alignment if (0 < e.get("score", 0) < _LOW_CONF) or e.get("near_black")]
        if _low_conf:
            _hint = " (try enabling AI enhancements for a semantic re-check)" if not globals().get("AI_ENABLED") else ""
            _warn(f"Low-confidence or near-black segments{_hint}: {_low_conf}")

        _remaining_runs = _find_stuck_runs(alignment, min_len=3)
        if _remaining_runs:
            _hint = " (enable AI for re-checks)" if not globals().get("AI_ENABLED") else ""
            for rs, re_ in _remaining_runs:
                _src = alignment[rs]["source_slide_index"]
                _warn(f"Screengrabs {rs+1}-{re_+1} all matched src slide {_src+1} ({re_ - rs + 1} in a row){_hint}")

        _n_source_slides = len(slide_texts)
        _used = {e["source_slide_index"] for e in alignment if e.get("source_slide_index") is not None}
        _skipped_slide_indices = [j for j in range(_n_source_slides) if j not in _used]
        if _skipped_slide_indices:
            _warn(f"{len(_skipped_slide_indices)} source slide(s) were never matched: {[j+1 for j in _skipped_slide_indices]}")
else:
    print("  No alignment computed.", flush=True)

# ─── Helper accessors for downstream steps ──────────────────────────────────

def is_screengrab_fallback(i):
    return bool(alignment and i < len(alignment) and alignment[i].get("use_screengrab"))

def get_source_slide(i):
    if is_screengrab_fallback(i) and screengrab_imgs and i < len(screengrab_imgs):
        p = screengrab_imgs[i]
        if p and os.path.exists(p):
            return p
    if alignment and i < len(alignment):
        src_idx = alignment[i].get("source_slide_index")
        if src_idx is not None and src_idx < len(slide_source_imgs):
            p = slide_source_imgs[src_idx]
            if p and os.path.exists(p):
                return p
    if slide_source_imgs and i < len(slide_source_imgs):
        p = slide_source_imgs[i]
        if p and os.path.exists(p):
            return p
    if screengrab_imgs and i < len(screengrab_imgs):
        p = screengrab_imgs[i]
        if p and os.path.exists(p):
            return p
    return None

def get_slide_text_for_index(i):
    if is_screengrab_fallback(i) and screengrab_imgs and i < len(screengrab_imgs) and screengrab_imgs[i]:
        return _ocr_text_for_image(screengrab_imgs[i]).strip()
    if alignment and i < len(alignment):
        src_idx = alignment[i].get("source_slide_index")
        if src_idx is not None and src_idx < len(slide_texts):
            return slide_texts[src_idx]
    if i < len(slide_texts):
        return slide_texts[i]
    return ""

def fmt_ts(seconds):
    try:
        mm, ss = int(seconds // 60), int(seconds % 60)
        return f"{mm:02d}:{ss:02d}"
    except Exception:
        return "00:00"

# ─── Step 6: Assign transcript segments to slides + AI content generators ───
_step("Step 6/7 — Assign transcript to slides")

def get_transcript_for_slide(idx, with_timestamps=False):
    """Return transcript text for slide idx, with optional MM:SS prefixes.

    Each whisper segment belongs to slide idx if its start time is in
    [slide_times[idx], slide_times[idx+1]). Every segment appears under
    exactly one slide (no silent drops).
    """
    try:
        start = slide_times[idx]
        end = slide_times[idx + 1] if idx + 1 < len(slide_times) else float("inf")
    except Exception:
        return "(no speech detected)"

    segs = [s for s in segments if start <= s.get("start", 0) < end]
    if not segs:
        return "(no speech detected)"
    if with_timestamps:
        return "\n".join(f"[{fmt_ts(s['start'])}] {s['text'].strip()}" for s in segs)
    return " ".join(s["text"].strip() for s in segs)

def get_full_transcript(with_timestamps=True):
    sorted_segs = sorted(segments or [], key=lambda s: s.get("start", 0))
    if not sorted_segs:
        return "(no speech detected)"
    if with_timestamps:
        return "\n".join(f"[{fmt_ts(s['start'])}] {s['text'].strip()}" for s in sorted_segs)
    return " ".join(s["text"].strip() for s in sorted_segs)

# --- AI content helpers (use cached results in _ai_cache) ---------------------
def _cache_set(key, value):
    try:
        _ai_cache[key] = value
        _save_ai_cache()
    except Exception:
        pass

def _cache_get(key):
    try:
        return _ai_cache.get(key, None)
    except Exception:
        return None

def _get_ai_slide_takeaway_direct(cache_key, slide_txt, label=""):
    if not globals().get("AI_ENABLED"):
        return None
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached or None
    slide_txt = (slide_txt or "").strip()
    if not slide_txt:
        _cache_set(cache_key, "")
        return None
    prompt = (
        "You are summarizing one slide of a recorded lecture, based only on "
        "the text printed on the slide (ignore anything the lecturer may "
        "have said).\n\n"
        f"Slide text:\n{slide_txt}\n\n"
        "In 1-2 concise sentences, state the key takeaway a student should "
        "remember from what is written on this slide. Reply with only the "
        "takeaway, no preamble."
    )
    try:
        result = ollama_generate(prompt, timeout=45, context=f"{label or cache_key} — slide takeaway")
        if result is not None:
            _cache_set(cache_key, result)
            return result
    except Exception:
        pass
    return None

def _get_ai_spoken_takeaway_direct(cache_key, slide_txt, spoken, label=""):
    if not globals().get("AI_ENABLED"):
        return None
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached or None
    spoken = (spoken or "").strip()
    slide_txt = (slide_txt or "").strip()
    if spoken in ("", "(no speech detected)"):
        _cache_set(cache_key, "")
        return None
    # Bound the spoken text to avoid excessive prompt sizes
    _MAX = 4000
    if len(spoken) > _MAX:
        spoken = spoken[:_MAX] + " ...(truncated)"
    prompt = (
        "You are summarizing what a lecturer said while presenting one slide.\n\n"
        f"Slide text (for context only):\n{slide_txt or '(none)'}\n\n"
        f"What the lecturer said while on this slide:\n{spoken}\n\n"
        "In 1-2 concise sentences, state the key takeaway from what the "
        "lecturer said in relation to this slide. Reply with only the takeaway."
    )
    try:
        result = ollama_generate(prompt, timeout=90, context=f"{label or cache_key} — spoken takeaway")
        if result is not None:
            _cache_set(cache_key, result)
            return result
    except Exception:
        pass
    return None

def get_ai_slide_takeaway(i):
    return _get_ai_slide_takeaway_direct(f"slide_{i}_slide_only", get_slide_text_for_index(i), label=f"slide {i+1}")

def get_ai_spoken_takeaway(i):
    spoken = get_transcript_for_slide(i, with_timestamps=False)
    return _get_ai_spoken_takeaway_direct(f"slide_{i}_spoken", get_slide_text_for_index(i), spoken, label=f"slide {i+1}")

def get_ai_lecture_summary():
    if not globals().get("AI_ENABLED"):
        return None
    cached = _cache_get("full_summary")
    if cached is not None:
        return cached or None
    full_txt = get_full_transcript(with_timestamps=False)
    _MAX_CHARS = 12000
    if len(full_txt) > _MAX_CHARS:
        full_txt = full_txt[:_MAX_CHARS] + " ...(truncated)"
    prompt = (
        "Below is the verbatim transcript of a recorded lecture.\n\n"
        f"{full_txt}\n\n"
        "Write a short overview for a student: first a 2-3 sentence summary of "
        "what the lecture covered, then a bullet list of the 4-6 main topics or "
        "takeaways. Reply with only that, no preamble."
    )
    try:
        result = ollama_generate(prompt, timeout=180, context="lecture overview")
        if result is not None:
            _cache_set("full_summary", result)
            return result
    except Exception:
        pass
    return None

# ─── AI pre-generation (best-effort) ---------------------------------------
if globals().get("AI_ENABLED"):
    _ai_jobs = []
    # Build per-segment jobs (slide text + spoken takeaways) in order
    for i in range(num_slides):
        _ai_jobs.append((f"slide {i+1} — slide takeaway", lambda _i=i: get_ai_slide_takeaway(_i)))
        _ai_jobs.append((f"slide {i+1} — spoken takeaway", lambda _i=i: get_ai_spoken_takeaway(_i)))

    # Deck-level slide takeaways for PPTX (if building PPTX)
    try:
        want_pptx = (fmt_choice in ("3", "4")) and not globals().get("USE_SCREENGRABS_ONLY") and slides_type == "pptx"
    except Exception:
        want_pptx = False

    if want_pptx:
        # Map deck slide -> list of segment indices assigned to it
        _pptx_map = {}
        for seg_i in range(num_slides):
            if is_screengrab_fallback(seg_i):
                continue
            src_idx = seg_i
            if alignment and seg_i < len(alignment):
                sidx = alignment[seg_i].get("source_slide_index")
                if sidx is not None:
                    src_idx = sidx
            _pptx_map.setdefault(src_idx, []).append(seg_i)

        def _pptx_slide_job(idx):
            segs = _pptx_map.get(idx, [])
            spoken_plain = "\n".join(get_transcript_for_slide(si, with_timestamps=False) for si in segs)
            _get_ai_slide_takeaway_direct(f"srcslide_{idx}_slide_only", slide_texts[idx] if idx < len(slide_texts) else "", label=f"deck slide {idx+1}")
            _get_ai_spoken_takeaway_direct(f"srcslide_{idx}_spoken", slide_texts[idx] if idx < len(slide_texts) else "", spoken_plain, label=f"deck slide {idx+1}")

        for idx in range(len(slide_texts)):
            _ai_jobs.append((f"deck slide {idx+1} — PPTX takeaway", lambda _idx=idx: _pptx_slide_job(_idx)))

    # Lecture overview last
    _ai_jobs.append(("lecture overview", get_ai_lecture_summary))

    # Quick Ollama health-check
    _ollama_ok = False
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2) as _r:
            _ollama_ok = (_r.status == 200)
    except Exception:
        _warn("Ollama health-check failed — skipping AI pre-generation.")
        _ollama_ok = False

    if not _ollama_ok:
        AI_ENABLED = False

if globals().get("AI_ENABLED"):
    _pb = ProgressBar(len(_ai_jobs), label="AI content") if '_ai_jobs' in globals() else None
    if _pb:
        _AI_PROGRESS_BAR[0] = _pb
        _pb.start_render()
    try:
        for label, fn in (_ai_jobs or []):
            if _pb:
                _pb.set_status(label)
            t0 = time.time()
            try:
                fn()
            except Exception:
                pass
            if _pb:
                _pb.item_done(time.time() - t0)
    finally:
        if _pb:
            _AI_PROGRESS_BAR[0] = None
            _pb.finish()
    if _OLLAMA_FAILURE_COUNT[0]:
        _warn(f"{_OLLAMA_FAILURE_COUNT[0]} AI item(s) failed during pre-generation.")

# ─── Step 7: Generate outputs (TXT, PDF, PPTX) ───────────────────────────────
_step("Step 7/7 — Generate outputs (TXT / PDF / PPTX)")

BORDER = "═" * 54

def build_toc():
    toc = []
    for i in range(num_slides):
        title = get_slide_text_for_index(i) or "(no text)"
        first_line = title.split("\n")[0].strip()[:80] if title else "(no text)"
        ts = fmt_ts(slide_times[i]) if i < len(slide_times) else "00:00"
        toc.append((i + 1, first_line, ts))
    return toc

def save_txt():
    out = os.path.join(output_dir, filename + "_merged.txt")
    lines = []
    lines += [
        "╔══════════════════════════════════════════════╗",
        "║            TABLE OF CONTENTS                 ║",
        "╚══════════════════════════════════════════════╝",
        ""
    ]
    for num, title, ts in build_toc():
        lines.append(f"  Slide {num:>3}  [{ts}]  {title}")
    lines += ["", "─" * 60, ""]

    if globals().get("AI_ENABLED"):
        lec = get_ai_lecture_summary()
        if lec:
            lines += [
                "╔══════════════════════════════════════════════╗",
                "║          🤖 AI LECTURE OVERVIEW               ║",
                "╚══════════════════════════════════════════════╝",
                ""
            ]
            lines += lec.split("\n")
            lines += ["", "─" * 60, ""]

    for i in range(num_slides):
        ts_str = fmt_ts(slide_times[i]) if i < len(slide_times) else "00:00"
        lines += [BORDER, f"  Slide {i+1}  [{ts_str}]", BORDER, ""]
        slide_img = get_source_slide(i)
        if globals().get("USE_SCREENGRABS_ONLY"):
            img_label = "🖼 SCREENGRAB"
        elif is_screengrab_fallback(i):
            img_label = "🖼 SCREENGRAB  (not found in slide file — showing video frame instead)"
        else:
            img_label = "📑 SLIDE IMAGE"
        lines.append(img_label)
        lines.append(f"  {slide_img}" if slide_img else "  (no slide image available)")
        lines.append("")
        if globals().get("USE_SCREENGRABS_ONLY"):
            content_label = "📋 SLIDE CONTENT  (screen-grabs only — no source text)"
        elif is_screengrab_fallback(i):
            content_label = "📋 SLIDE CONTENT  (OCR'd from video frame — not in slide file)"
        else:
            content_label = "📋 SLIDE CONTENT"
        lines.append(content_label)
        slide_content = get_slide_text_for_index(i)
        if slide_content.strip():
            for line in slide_content.split("\n"):
                lines.append(f"  {line}")
        else:
            lines.append("  (no text on slide)")
        lines.append("")
        lines.append("🗣 SPOKEN (VERBATIM)")
        transcript = get_transcript_for_slide(i, with_timestamps=True)
        lines += [f"  {l}" for l in transcript.split("\n")]
        lines.append("")
        if globals().get("AI_ENABLED"):
            st = get_ai_slide_takeaway(i)
            if st:
                lines.append("🤖 AI TAKEAWAY (Slide)")
                lines += [f"  {l}" for l in st.split("\n")]
                lines.append("")
            sp = get_ai_spoken_takeaway(i)
            if sp:
                lines.append("🤖 AI TAKEAWAY (Spoken)")
                lines += [f"  {l}" for l in sp.split("\n")]
                lines.append("")
        lines.append("")

    lines += ["", "═" * 54, "  📝 FULL VERBATIM TRANSCRIPT", "═" * 54, ""]
    lines += [f"  {l}" for l in get_full_transcript(with_timestamps=True).split("\n")]
    lines.append("")

    if _skipped_slide_indices:
        lines += ["", "═" * 54, "  📎 APPENDIX: SLIDES NOT CAPTURED", "═" * 54, ""]
        for j in _skipped_slide_indices:
            lines += [BORDER, f"  Slide {j+1}  (not captured)", BORDER, ""]
            _img = slide_source_imgs[j] if j < len(slide_source_imgs) else None
            lines.append(f"  {_img}" if _img else "  (no slide image available)")
            lines.append("")
            _txt = slide_texts[j] if j < len(slide_texts) else ""
            if _txt.strip():
                lines += [f"  {l}" for l in _txt.split("\n")]
            else:
                lines.append("  (no text on slide)")
            lines.append("")
    with open(out, "w") as f:
        f.write("\n".join(lines))
    _ok(f"TXT saved: {out}")

def _pdf_escape(text):
    from xml.sax.saxutils import escape as _xml_escape
    return _xml_escape(text or "")
def save_pdf():
    out = os.path.join(output_dir, filename + "_merged.pdf")

    # Try to import reportlab locally; if unavailable, fall back to image-based PDF.
    try:
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, HRFlowable, Image as RLImage
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import ParagraphStyle
        from reportlab.lib import colors
        from reportlab.lib.units import inch
    except Exception as e:
        _warn(f"reportlab unavailable or failed to import ({e}) — falling back to image-based PDF generation.")
        try:
            images = build_final_image_sequence(len(alignment) if alignment else len(screengrab_imgs))
            ok = save_pdf_from_images(images, out)
            if ok:
                _ok(f"Fallback PDF written from images: {out}")
            else:
                _err("Fallback PDF generation also failed.")
        except Exception as e2:
            _warn(f"Fallback PDF generation failed: {e2}")
        return

    # Small helper: safe escape (use existing _pdf_escape if available)
    try:
        _escape = globals().get("_pdf_escape", None) or (lambda x: __import__("xml.sax.saxutils").saxutils.escape(x or ""))
    except Exception:
        from xml.sax.saxutils import escape as _escape

    # Styles
    h_sty = ParagraphStyle("H", fontSize=13, leading=16, textColor=colors.HexColor("#1a1a2e"), spaceAfter=4, fontName="Helvetica-Bold")
    lbl_sty = ParagraphStyle("LBL", fontSize=10, fontName="Helvetica-Bold", textColor=colors.HexColor("#1a1a2e"), spaceAfter=4)
    b_sty = ParagraphStyle("B", fontSize=10, leading=14, textColor=colors.HexColor("#333333"), spaceAfter=4, fontName="Helvetica")
    s_sty = ParagraphStyle("S", fontSize=9, leading=13, textColor=colors.HexColor("#1a6b3c"), spaceAfter=3, fontName="Helvetica-Oblique")
    toc_h_sty = ParagraphStyle("TOCH", fontSize=15, fontName="Helvetica-Bold", textColor=colors.HexColor("#1a1a2e"), spaceAfter=10)
    toc_sty = ParagraphStyle("TOC", fontSize=10, fontName="Helvetica", textColor=colors.HexColor("#333333"), spaceAfter=4, leftIndent=20)
    ai_lbl_sty = ParagraphStyle("AILBL", fontSize=10, fontName="Helvetica-Bold", textColor=colors.HexColor("#7a3ea1"), spaceAfter=4)
    ai_sty = ParagraphStyle("AI", fontSize=9.5, leading=13, textColor=colors.HexColor("#4a2564"), spaceAfter=3, fontName="Helvetica-Oblique")
    full_h_sty = ParagraphStyle("FH", fontSize=15, fontName="Helvetica-Bold", textColor=colors.HexColor("#1a1a2e"), spaceAfter=10)
    full_s_sty = ParagraphStyle("FS", fontSize=9, leading=13, textColor=colors.HexColor("#1a6b3c"), spaceAfter=3, fontName="Helvetica-Oblique")
    appendix_h_sty = ParagraphStyle("AH", fontSize=15, fontName="Helvetica-Bold", textColor=colors.HexColor("#1a1a2e"), spaceAfter=10)

    # Build document
    try:
        doc = SimpleDocTemplate(out, pagesize=A4,
                                leftMargin=0.75*inch, rightMargin=0.75*inch,
                                topMargin=0.75*inch, bottomMargin=0.75*inch)
    except Exception as e:
        _warn(f"Failed to create PDF document: {e}")
        # fallback to image-based PDF
        try:
            images = build_final_image_sequence(len(alignment) if alignment else len(screengrab_imgs))
            ok = save_pdf_from_images(images, out)
            if ok:
                _ok(f"Fallback PDF written from images: {out}")
            else:
                _err("Fallback PDF generation also failed.")
        except Exception as e2:
            _warn(f"Fallback PDF generation failed: {e2}")
        return

    story = []
    page_w = A4[0] - 1.5 * inch

    # Table of Contents
    story.append(Paragraph("Table of Contents", toc_h_sty))
    story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor("#1a1a2e"), spaceAfter=6))
    try:
        for num, title, ts in build_toc():
            story.append(Paragraph(f"<b>Slide {num}</b>&nbsp;&nbsp;[{ts}]&nbsp;&nbsp;— {_escape(title)}", toc_sty))
    except Exception:
        pass
    story.append(Spacer(1, 20))
    story.append(HRFlowable(width="100%", thickness=2, color=colors.HexColor("#1a1a2e"), spaceAfter=20))

    # AI overview (if available)
    if globals().get("AI_ENABLED"):
        try:
            lec = get_ai_lecture_summary()
            if lec:
                story.append(Paragraph("🤖 AI Lecture Overview", toc_h_sty))
                story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor("#7a3ea1"), spaceAfter=8))
                for line in lec.split("\n"):
                    if line.strip():
                        story.append(Paragraph(_escape(line.strip()), ai_sty))
                story.append(Spacer(1, 20))
                story.append(HRFlowable(width="100%", thickness=2, color=colors.HexColor("#1a1a2e"), spaceAfter=20))
        except Exception:
            pass

    # Slides
    for i in range(num_slides):
        ts_str = fmt_ts(slide_times[i]) if i < len(slide_times) else "00:00"
        story.append(Paragraph(f"Slide {i+1}&nbsp;&nbsp;<font color='#888888' size='10'>[{ts_str}]</font>", h_sty))

        label = "🖼 Screengrab" if globals().get("USE_SCREENGRABS_ONLY") else ("🖼 Screengrab (video frame)" if is_screengrab_fallback(i) else "📑 Source Slide")
        story.append(Paragraph(label, lbl_sty))

        slide_img = None
        try:
            slide_img = get_source_slide(i)
        except Exception:
            slide_img = None

        if slide_img and os.path.exists(slide_img):
            try:
                # scale image to page width while preserving aspect
                story.append(RLImage(slide_img, width=page_w, height=page_w * 0.56))
                story.append(Spacer(1, 6))
            except Exception:
                story.append(Paragraph("(image unavailable)", b_sty))
        else:
            story.append(Paragraph("(no slide image available)", b_sty))

        # Slide text (unless screengrabs-only)
        if not globals().get("USE_SCREENGRABS_ONLY"):
            story.append(Paragraph("📋 Slide Text:", lbl_sty))
            sc = ""
            try:
                sc = get_slide_text_for_index(i) or ""
            except Exception:
                sc = ""
            if sc.strip():
                for line in sc.split("\n"):
                    if line.strip():
                        story.append(Paragraph(_escape(line.strip()), b_sty))
            else:
                story.append(Paragraph("(no text on slide)", b_sty))
            story.append(Spacer(1, 6))

        # Spoken transcript
        story.append(Paragraph("🗣 Spoken:", s_sty))
        try:
            transcript = get_transcript_for_slide(i, with_timestamps=True)
        except Exception:
            transcript = "(no speech detected)"
        for spoken_line in transcript.split("\n"):
            if spoken_line.strip():
                story.append(Paragraph(_escape(spoken_line.strip()), s_sty))

        # AI takeaways
        if globals().get("AI_ENABLED"):
            try:
                st = get_ai_slide_takeaway(i)
                if st:
                    story.append(Spacer(1, 6))
                    story.append(Paragraph("🤖 AI Takeaway (Slide):", ai_lbl_sty))
                    for l in st.split("\n"):
                        if l.strip():
                            story.append(Paragraph(_escape(l.strip()), ai_sty))
                sp = get_ai_spoken_takeaway(i)
                if sp:
                    story.append(Spacer(1, 6))
                    story.append(Paragraph("🤖 AI Takeaway (Spoken):", ai_lbl_sty))
                    for l in sp.split("\n"):
                        if l.strip():
                            story.append(Paragraph(_escape(l.strip()), ai_sty))
            except Exception:
                pass

        story.append(Spacer(1, 14))
        story.append(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#cccccc"), spaceAfter=10))

    # Full transcript page(s)
    try:
        story.append(PageBreak())
        story.append(Paragraph("📝 Full Verbatim Transcript", full_h_sty))
        story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor("#1a1a2e"), spaceAfter=8))
        full_txt = get_full_transcript(with_timestamps=True)
        for line in (full_txt or "").split("\n"):
            if line.strip():
                story.append(Paragraph(_escape(line.strip()), full_s_sty))
    except Exception:
        pass

    # Appendix for skipped source slides
    try:
        if _skipped_slide_indices:
            story.append(PageBreak())
            story.append(Paragraph("📎 Appendix: Slides Not Captured in This Recording", appendix_h_sty))
            story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor("#1a1a2e"), spaceAfter=8))
            for j in _skipped_slide_indices:
                story.append(Paragraph(f"Slide {j+1}", h_sty))
                _img = slide_source_imgs[j] if j < len(slide_source_imgs) else None
                if _img and os.path.exists(_img):
                    try:
                        story.append(RLImage(_img, width=page_w, height=page_w * 0.56))
                        story.append(Spacer(1, 6))
                    except Exception:
                        story.append(Paragraph("(image unavailable)", b_sty))
                else:
                    story.append(Paragraph("(no slide image available)", b_sty))
                _txt = slide_texts[j] if j < len(slide_texts) else ""
                if _txt.strip():
                    for l in _txt.split("\n"):
                        if l.strip():
                            story.append(Paragraph(_escape(l.strip()), b_sty))
                else:
                    story.append(Paragraph("(no text on slide)", b_sty))
                story.append(Spacer(1, 14))
                story.append(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#cccccc"), spaceAfter=10))
    except Exception:
        pass

    # Build PDF
    try:
        doc.build(story)
        _ok(f"PDF saved: {out}")
    except Exception as e:
        _warn(f"Failed to build PDF: {e}")
        # Attempt image-based fallback
        try:
            images = build_final_image_sequence(len(alignment) if alignment else len(screengrab_imgs))
            ok = save_pdf_from_images(images, out)
            if ok:
                _ok(f"Fallback PDF written from images: {out}")
            else:
                _err("Fallback PDF generation also failed.")
        except Exception as e2:
            _warn(f"PDF fallback failed: {e2}")
def save_pptx():
    if globals().get("USE_SCREENGRABS_ONLY"):
        _warn("PPTX output not available in screen-grabs-only mode.")
        return
    if slides_type != "pptx":
        _warn("PPTX output requires a .pptx source file. Skipping.")
        return

    out = os.path.join(output_dir, filename + "_merged.pptx")
    try:
        prs = Presentation(slides_file)
    except Exception as e:
        _warn(f"Failed to open original PPTX for augmentation: {e}")
        return

    slide_w = prs.slide_width
    slide_h = prs.slide_height

    # Build mapping deck-slide -> segments assigned
    _slide_to_segments = {}
    _fallback_segments = []
    for seg_i in range(num_slides):
        if is_screengrab_fallback(seg_i):
            _fallback_segments.append(seg_i)
            continue
        src_idx = seg_i
        if alignment and seg_i < len(alignment) and alignment[seg_i].get("source_slide_index") is not None:
            src_idx = alignment[seg_i]["source_slide_index"]
        _slide_to_segments.setdefault(src_idx, []).append(seg_i)

    from pptx.util import Inches, Pt
    from pptx.dml.color import RGBColor

    for i, slide in enumerate(prs.slides):
        if i >= len(slide_texts):
            break
        seg_indices = _slide_to_segments.get(i, [])
        if seg_indices:
            chunks = [get_transcript_for_slide(si, with_timestamps=True) for si in seg_indices]
            chunks = [c for c in chunks if c and c != "(no speech detected)"]
            spoken = "\n".join(chunks) if chunks else "(no speech detected)"
        else:
            spoken = "(no speech detected)"

        box_left = Inches(0.3)
        box_h = Inches(1.6)
        box_top = slide_h - Inches(1.7)
        box_w = slide_w - Inches(0.6)

        txBox = slide.shapes.add_textbox(box_left, box_top, box_w, box_h)
        tf = txBox.text_frame
        tf.word_wrap = True

        try:
            lbl = tf.paragraphs[0]
            lbl.text = "🗣 Spoken:"
            lbl.font.bold = True
            lbl.font.size = Pt(9)
            lbl.font.color.rgb = RGBColor(26, 107, 60)
        except Exception:
            pass

        for spoken_line in spoken.split("\n"):
            s = spoken_line.strip()
            if not s:
                continue
            p = tf.add_paragraph()
            p.text = s
            p.font.size = Pt(7.5)
            p.font.color.rgb = RGBColor(51, 51, 51)

        if globals().get("AI_ENABLED"):
            _spoken_plain = "\n".join(get_transcript_for_slide(si, with_timestamps=False) for si in seg_indices)
            _slide_sum = _get_ai_slide_takeaway_direct(f"srcslide_{i}_slide_only", slide_texts[i] if i < len(slide_texts) else "", label=f"deck slide {i+1}")
            if _slide_sum:
                ai_lbl = tf.add_paragraph()
                ai_lbl.text = "🤖 AI Takeaway (Slide):"
                ai_lbl.font.bold = True
                ai_lbl.font.size = Pt(9)
                ai_lbl.font.color.rgb = RGBColor(122, 62, 161)
                for line in _slide_sum.split("\n"):
                    if not line.strip():
                        continue
                    p = tf.add_paragraph()
                    p.text = line.strip()
                    p.font.size = Pt(7.5)
                    p.font.italic = True
                    p.font.color.rgb = RGBColor(74, 37, 100)

            _spoken_sum = _get_ai_spoken_takeaway_direct(f"srcslide_{i}_spoken", slide_texts[i] if i < len(slide_texts) else "", _spoken_plain, label=f"deck slide {i+1}")
            if _spoken_sum:
                ai_lbl2 = tf.add_paragraph()
                ai_lbl2.text = "🤖 AI Takeaway (Spoken):"
                ai_lbl2.font.bold = True
                ai_lbl2.font.size = Pt(9)
                ai_lbl2.font.color.rgb = RGBColor(122, 62, 161)
                for line in _spoken_sum.split("\n"):
                    if not line.strip():
                        continue
                    p2 = tf.add_paragraph()
                    p2.text = line.strip()
                    p2.font.size = Pt(7.5)
                    p2.font.italic = True
                    p2.font.color.rgb = RGBColor(74, 37, 100)

    try:
        prs.save(out)
        _ok(f"PPTX saved: {out}")
    except Exception as e:
        _warn(f"Failed to save PPTX: {e}")
        return

    # Append fallback segments and transcript slides as separate sections
    try:
        prs2 = Presentation(out)
        slide_w2 = prs2.slide_width
        slide_h2 = prs2.slide_height
        BLANK_LAYOUT = 6
        from pptx.util import Inches, Pt
        from pptx.dml.color import RGBColor
    except Exception as e:
        _warn(f"Failed to re-open PPTX for appending slides: {e}")
        return

    if _fallback_segments:
        for seg_i in _fallback_segments:
            layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
            fb_slide = prs2.slides.add_slide(layout)
            for ph in list(fb_slide.placeholders):
                try:
                    sp_el = ph._element
                    sp_el.getparent().remove(sp_el)
                except Exception:
                    pass
            title_box = fb_slide.shapes.add_textbox(Inches(0.3), Inches(0.2), slide_w2 - Inches(0.6), Inches(0.5))
            title_lbl = title_box.text_frame.paragraphs[0]
            title_lbl.text = (f"🖼 Screengrab — {fmt_ts(slide_times[seg_i])}  (not in original slide file)")
            title_lbl.font.bold = True
            title_lbl.font.size = Pt(13)
            title_lbl.font.color.rgb = RGBColor(26, 26, 46)

            _fb_img = screengrab_imgs[seg_i] if seg_i < len(screengrab_imgs) else None
            _img_top = Inches(0.8)
            if _fb_img and os.path.exists(_fb_img):
                _img_w = slide_w2 - Inches(0.6)
                _img_h = int(_img_w * 9 / 16)
                try:
                    fb_slide.shapes.add_picture(_fb_img, Inches(0.3), _img_top, width=_img_w, height=_img_h)
                    _text_top = int(_img_top + _img_h + Inches(0.15))
                except Exception:
                    _text_top = int(_img_top)
            else:
                _text_top = int(_img_top)

            body_box = fb_slide.shapes.add_textbox(Inches(0.3), _text_top, slide_w2 - Inches(0.6), slide_h2 - _text_top - Inches(0.2))
            tf_fb = body_box.text_frame
            tf_fb.word_wrap = True
            fb_lbl = tf_fb.paragraphs[0]
            fb_lbl.text = "🗣 Spoken:"
            fb_lbl.font.bold = True
            fb_lbl.font.size = Pt(9)
            fb_lbl.font.color.rgb = RGBColor(26, 107, 60)
            _fb_spoken = get_transcript_for_slide(seg_i, with_timestamps=True)
            for _line in _fb_spoken.split("\n"):
                _line = _line.strip()
                if not _line:
                    continue
                p = tf_fb.add_paragraph()
                p.text = _line
                p.font.size = Pt(8)
                p.font.color.rgb = RGBColor(51, 51, 51)
            if globals().get("AI_ENABLED"):
                _fb_takeaway = get_ai_spoken_takeaway(seg_i)
                if _fb_takeaway:
                    ai_lbl = tf_fb.add_paragraph()
                    ai_lbl.text = "🤖 AI Takeaway:"
                    ai_lbl.font.bold = True
                    ai_lbl.font.size = Pt(9)
                    ai_lbl.font.color.rgb = RGBColor(122, 62, 161)
                    for _line in _fb_takeaway.split("\n"):
                        _line = _line.strip()
                        if not _line:
                            continue
                        ap = tf_fb.add_paragraph()
                        ap.text = _line
                        ap.font.size = Pt(8)
                        ap.font.italic = True
                        ap.font.color.rgb = RGBColor(74, 37, 100)

    # Full transcript slides (chunked)
    full_lines = [ln for ln in get_full_transcript(with_timestamps=True).split("\n") if ln.strip()]
    LINES_PER_SLIDE = 30
    for chunk_start in range(0, max(len(full_lines), 1), LINES_PER_SLIDE):
        chunk = full_lines[chunk_start:chunk_start + LINES_PER_SLIDE]
        layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
        new_slide = prs2.slides.add_slide(layout)
        for ph in list(new_slide.placeholders):
            try:
                sp_el = ph._element
                sp_el.getparent().remove(sp_el)
            except Exception:
                pass
        title_box = new_slide.shapes.add_textbox(Inches(0.3), Inches(0.2), slide_w2 - Inches(0.6), Inches(0.55))
        tf_title = title_box.text_frame
        chunk_idx = chunk_start // LINES_PER_SLIDE + 1
        total_chunks = (len(full_lines) - 1) // LINES_PER_SLIDE + 1 if full_lines else 1
        title_lbl = tf_title.paragraphs[0]
        title_lbl.text = "📝 Full Verbatim Transcript" if total_chunks == 1 else f"📝 Full Verbatim Transcript ({chunk_idx}/{total_chunks})"
        title_lbl.font.bold = True
        title_lbl.font.size = Pt(14)
        title_lbl.font.color.rgb = RGBColor(26, 26, 46)
        body_box = new_slide.shapes.add_textbox(Inches(0.3), Inches(0.9), slide_w2 - Inches(0.6), slide_h2 - Inches(1.1))
        tf_body = body_box.text_frame
        tf_body.word_wrap = True
        first = True
        for line in (chunk if chunk else ["(no speech detected)"]):
            if first:
                para = tf_body.paragraphs[0]
                first = False
            else:
                para = tf_body.add_paragraph()
            para.text = line.strip()
            para.font.size = Pt(7.5)
            para.font.color.rgb = RGBColor(26, 107, 60)

    if globals().get("AI_ENABLED"):
        lec = get_ai_lecture_summary()
        if lec:
            layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
            ai_slide = prs2.slides.add_slide(layout)
            for ph in list(ai_slide.placeholders):
                try:
                    sp_el = ph._element
                    sp_el.getparent().remove(sp_el)
                except Exception:
                    pass
            title_box = ai_slide.shapes.add_textbox(Inches(0.3), Inches(0.2), slide_w2 - Inches(0.6), Inches(0.55))
            title_lbl = title_box.text_frame.paragraphs[0]
            title_lbl.text = "🤖 AI Lecture Overview"
            title_lbl.font.bold = True
            title_lbl.font.size = Pt(14)
            title_lbl.font.color.rgb = RGBColor(26, 26, 46)
            body_box = ai_slide.shapes.add_textbox(Inches(0.3), Inches(0.9), slide_w2 - Inches(0.6), slide_h2 - Inches(1.1))
            tf_body = body_box.text_frame
            tf_body.word_wrap = True
            first = True
            for line in lec.split("\n"):
                if not line.strip():
                    continue
                if first:
                    para = tf_body.paragraphs[0]
                    first = False
                else:
                    para = tf_body.add_paragraph()
                para.text = line.strip()
                para.font.size = Pt(11)
                para.font.color.rgb = RGBColor(74, 37, 100)

    try:
        prs2.save(out)
        print("  PPTX full transcript slide(s) appended.", flush=True)
    except Exception as e:
        _warn(f"Failed to save final PPTX: {e}")

# ── CSV summary + final output orchestration (robust, atomic writes) ─────────
def _sanitize_field(text, maxlen=10000):
    """Sanitize a freeform text field for CSV/summary outputs:
    - collapse whitespace/newlines to single spaces,
    - trim to maxlen characters (avoid enormous CSV cells)."""
    if not text:
        return ""
    s = " ".join(str(text).split())
    if len(s) > maxlen:
        return s[:maxlen].rstrip() + " ...(truncated)"
    return s

def save_csv():
    import csv, tempfile
    out_csv = os.path.join(output_dir, filename + "_summary.csv")
    fieldnames = ["slide_number", "timestamp", "timestamp_seconds",
                  "slide_text", "transcript", "source_slide_image",
                  "screengrab_fallback", "ai_takeaway_slide", "ai_takeaway_spoken"]
    rows = []
    for i in range(num_slides):
        try:
            ts = slide_times[i] if i < len(slide_times) else 0.0
        except Exception:
            ts = 0.0
        # AI takeaways: best-effort, sanitized
        _ai_takeaway_slide = ""
        _ai_takeaway_spoken = ""
        if globals().get("AI_ENABLED"):
            try:
                _ai_takeaway_slide = _sanitize_field(get_ai_slide_takeaway(i) or "")
            except Exception:
                _ai_takeaway_slide = ""
            try:
                _ai_takeaway_spoken = _sanitize_field(get_ai_spoken_takeaway(i) or "")
            except Exception:
                _ai_takeaway_spoken = ""
        slide_txt = _sanitize_field(get_slide_text_for_index(i) or "", maxlen=4000)
        transcript = _sanitize_field(get_transcript_for_slide(i, with_timestamps=True) or "", maxlen=8000)
        src_img = get_source_slide(i) or ""
        rows.append({
            "slide_number":        i + 1,
            "timestamp":           fmt_ts(ts),
            "timestamp_seconds":   round(float(ts), 2),
            "slide_text":          slide_txt,
            "transcript":          transcript,
            "source_slide_image":  src_img,
            "screengrab_fallback": bool(is_screengrab_fallback(i)),
            "ai_takeaway_slide":   _ai_takeaway_slide,
            "ai_takeaway_spoken":  _ai_takeaway_spoken,
        })
    # Write atomically: write to a temp file then replace
    try:
        with tempfile.NamedTemporaryFile("w", delete=False, dir=output_dir, newline="", encoding="utf-8") as tf:
            writer = csv.DictWriter(tf, fieldnames=fieldnames, quoting=csv.QUOTE_MINIMAL)
            writer.writeheader()
            writer.writerows(rows)
            tmp_path = tf.name
        os.replace(tmp_path, out_csv)
        _ok(f"CSV summary saved: {out_csv}")
    except Exception as e:
        _warn(f"Failed to write CSV summary: {e}")
        try:
            if 'tmp_path' in locals() and os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception:
            pass

# Generate requested outputs (call each save_* in a guarded way)
_note(f"Generating output(s) for {num_slides} slide(s)...")
_errors = []

def _safe_call(fn, name):
    try:
        fn()
        return True
    except Exception as e:
        _errors.append((name, str(e)))
        _err(f"{name} failed: {e}")
        return False

# TXT
if fmt_choice in ("1", "4"):
    _safe_call(save_txt, "TXT")

# PDF
if fmt_choice in ("2", "4"):
    _safe_call(save_pdf, "PDF")

# PPTX
if fmt_choice in ("3", "4"):
    _safe_call(save_pptx, "PPTX")

# Always produce CSV summary (best-effort)
_safe_call(save_csv, "CSV")

# Report any AI pre-generation issues
if globals().get("AI_ENABLED") and globals().get("_OLLAMA_FAILURE_COUNT") and _OLLAMA_FAILURE_COUNT[0]:
    _warn(f"{_OLLAMA_FAILURE_COUNT[0]} Ollama request(s) failed/timed out during this run "
          f"and were skipped. Their AI content may be uncached; re-running will retry them.")

# ─── Final summary box ─────────────────────────────────────────────────────────
_BAR = "━" * 57
print(f"\n{_BLU}{_BAR}{_RST}", flush=True)
if _errors:
    print(f"{_BLU}  Finished with {len(_errors)} issue(s):{_RST}", flush=True)
    for nm, err_msg in _errors:
        print(f"    {_RED}✘{_RST} {nm}: {err_msg}", flush=True)
else:
    print(f"{_GRN}{_BLD}  ✔ All requested outputs generated successfully.{_RST}", flush=True)
print(f"{_BLU}  Output folder: {output_dir}{_RST}", flush=True)
print(f"{_BLU}{_BAR}{_RST}", flush=True)

print(f"{_DIM}  Done. Open the folder above to view your notes.{_RST}", flush=True)
PYEOF