#!/bin/bash

set -e

# ─── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
NOTES_ROOT="$HOME/notes"
mkdir -p "$NOTES_ROOT"

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
# instead — picking a Year/Semester/Class/Week finds both the video and the
# slides for that lecture in one pass, and routes the final output to
# ~/notes/<same relative path> instead of the flat ~/Desktop/C.
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
        _B_VIDEO_DIR="$_B_WEEK_DIR/Lecture_Video"
        _B_SLIDES_DIR="$_B_WEEK_DIR/Lecture_Slides"

        # ── Video, from this week's Lecture_Video folder ──
        shopt -s nullglob
        _b_mp4s=( "$_B_VIDEO_DIR"/*.mp4 )
        shopt -u nullglob
        if [ ${#_b_mp4s[@]} -eq 0 ]; then
            echo -e "${RED}  ✘ No .mp4 found in $_B_VIDEO_DIR.${NC}"
            echo -e "${YELLOW}  Add the lecture video there and re-run.${NC}"
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

        # ── Slides, from this week's Lecture_Slides folder (optional — falls
        # back to screengrabs-only if this week has none) ──
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

        # ── Route output to ~/notes/<same relative Year/Semester/Class/Week path> ──
        RELATIVE_WEEK_PATH="$_b_year/$_b_sem/$_b_class/$_b_week"
        FOLDER_C="$NOTES_ROOT/$RELATIVE_WEEK_PATH"
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
echo -e "\n${YELLOW}Step 1: Converting MP4 to 16 kHz mono WAV...${NC}"

if [ -f "$OUTPUT_WAV" ] && [ -s "$OUTPUT_WAV" ]; then
    echo -e "${CYAN}  WAV already exists — skipping conversion.${NC}"
else
    ffmpeg -y -i "$INPUT_VIDEO" -ac 1 -ar 16000 -vn -threads 0 "$OUTPUT_WAV"
    echo -e "${GREEN}  WAV saved to $OUTPUT_WAV${NC}"
fi

# ─── Step 2: Transcribe with Whisper / stable-ts ───────────────────────────────
echo -e "\n${YELLOW}Step 2: Transcribing with Whisper (stable-ts if available)...${NC}"

_SEG_JSON="$FOLDER_C/${filename}_segments.json"
_TRANSCRIPT_TXT="$FOLDER_C/${filename}_transcript.txt"

if [ -f "$_SEG_JSON" ] && [ -s "$_SEG_JSON" ]; then
    echo -e "${CYAN}  Segments JSON already exists — skipping transcription.${NC}"
else
python - << PYEOF
import json, os

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
    print("  [Step 2] Using stable-ts for word-level timestamps", flush=True)
except ImportError:
    import whisper
    print("  Loading Whisper model...", flush=True)
    model  = whisper.load_model(model_size)
    print("  Transcribing — live output below:\n", flush=True)
    result = model.transcribe(audio_file, language="en", fp16=False, verbose=True)
    print("  [Step 2] stable-ts not available, using standard Whisper", flush=True)

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

print(f"\n  Segments saved to:   {seg_path}", flush=True)
print(f"  Transcript saved to: {txt_path}", flush=True)
PYEOF
fi

echo -e "${GREEN}  Transcription complete.${NC}"

# ─── Step 3: Detect Slide Changes ──────────────────────────────────────────────
echo -e "\n${YELLOW}Step 3: Detecting slide changes...${NC}"

_SLIDE_TIMES_JSON="$FOLDER_C/${filename}_slide_times.json"
_SCREENGRABS_JSON="$FOLDER_C/${filename}_screengrabs.json"

if [ -f "$_SLIDE_TIMES_JSON" ] && [ -s "$_SLIDE_TIMES_JSON" ] \
   && [ -f "$_SCREENGRABS_JSON" ] && [ -s "$_SCREENGRABS_JSON" ]; then
    echo -e "${CYAN}  Slide times already exist — skipping detection.${NC}"
else
python - << PYEOF
import cv2, json, mmap, os
import numpy as np

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
        print(f"  [Step 3] Could not pre-count PPTX slides ({_e})", flush=True)
elif slides_type == "pdf" and slides_file:
    try:
        import fitz as _fitz
        expected_slide_count = _fitz.open(slides_file).page_count
    except Exception as _e:
        print(f"  [Step 3] Could not pre-count PDF pages ({_e})", flush=True)

if expected_slide_count:
    print(f"  [Step 3] Source deck has {expected_slide_count} slide(s) — using this as a detection target.", flush=True)

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
    cuts a generic film scene-cut detector expects. Returns (timestamps, threshold_used)."""
    cap_local = cv2.VideoCapture(video_path)
    if start_sec > 0:
        cap_local.set(cv2.CAP_PROP_POS_MSEC, start_sec * 1000)
    sample_every = max(1, int(fps / 5))
    cal_diffs, threshold, finalised = [], 35.0, False
    prev_gray = None
    frame_idx = int(start_sec * fps)
    found = []
    while True:
        ret, frame = cap_local.read()
        if not ret:
            break
        ts = frame_idx / fps
        if end_sec is not None and ts > end_sec:
            break
        if frame_idx % sample_every != 0:
            frame_idx += 1
            continue
        gray = _grayscale_masked(frame)
        if prev_gray is not None:
            score = float(np.mean(cv2.absdiff(gray, prev_gray)))
            if not finalised:
                cal_diffs.append(score)
                if len(cal_diffs) >= cal_limit:
                    _center, _spread = _robust_center_spread(cal_diffs)
                    threshold = max(floor, min(_center + std_mult * _spread, ceiling))
                    finalised = True
            if score > threshold:
                found.append(round(ts, 3))
        prev_gray = gray
        frame_idx += 1
    cap_local.release()
    if not finalised and cal_diffs:
        _center, _spread = _robust_center_spread(cal_diffs)
        threshold = max(floor, min(_center + std_mult * _spread, ceiling))
    return found, threshold

def _merge_timestamps(*lists, gap=1.5):
    """Union multiple candidate timestamp lists, treating anything within 'gap'
    seconds of an already-kept timestamp as the same transition."""
    merged = []
    for lst in lists:
        for t in lst:
            if not any(abs(t - m) <= gap for m in merged):
                merged.append(t)
    return sorted(merged)

# ── Pass 1: PySceneDetect AdaptiveDetector — good at hard cuts, but tuned for
# film content, so it under-triggers on subtle slide-to-slide text changes. ──
sd_timestamps = []
try:
    from scenedetect import open_video, SceneManager
    from scenedetect.detectors import AdaptiveDetector

    video = open_video(video_path)
    scene_manager = SceneManager()
    _sd_threshold = float("$SCENE_DETECT_THRESHOLD")
    scene_manager.add_detector(AdaptiveDetector(adaptive_threshold=_sd_threshold, min_scene_len=int(fps)))
    scene_manager.detect_scenes(video, show_progress=False)
    scene_list = scene_manager.get_scene_list()
    sd_timestamps = [0.0] + [s.get_seconds() for s, _ in scene_list[1:]]
    print(f"  [Step 3] scenedetect (cut-detection, threshold={_sd_threshold}) found "
          f"{len(sd_timestamps)} transitions", flush=True)
except ImportError:
    print("  [Step 3] scenedetect not available — relying on the content-diff pass", flush=True)

# ── Pass 2: webcam-masked adaptive content-diff — this is the pass actually
# suited to slide decks, and previously only ran when scenedetect was missing
# entirely, so scenedetect's blind spots were never being covered. Now both
# passes always run and their results are merged. ─────────────────────────────
print(f"  [Step 3] FPS: {fps:.2f} — running webcam-masked content-diff pass...", flush=True)
diff_timestamps, _threshold_used = _diff_scan()
print(f"  [Step 3] Content-diff pass found {len(diff_timestamps)} transitions "
      f"(threshold={_threshold_used:.2f})", flush=True)

slide_timestamps = _merge_timestamps(sd_timestamps, diff_timestamps)
if not slide_timestamps or slide_timestamps[0] > 2.0:
    slide_timestamps.insert(0, 0.0)
    slide_timestamps.sort()

print(f"  [Step 3] Merged both passes: {len(slide_timestamps)} total transitions", flush=True)

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
    thresh_by_avg    = max(2.0 * avg_dwell, 45.0)
    thresh_by_median = max(2.0 * median_gap, 45.0)
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
            extra, _ = _diff_scan(start_sec=g_start, end_sec=g_end,
                                   std_mult=0.6, floor=5.0, ceiling=45.0, cal_limit=120)
            _found_here = 0
            for t in extra:
                if not any(abs(t - s) <= 1.5 for s in slide_timestamps):
                    slide_timestamps.append(t)
                    recovered += 1
                    _found_here += 1
            if _found_here == 0:
                _still_dark.append((g_start, g_end))
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
                    print(f"  ⚠ Ollama request failed ({_e}) — skipping topic-shift pass for this gap.", flush=True)
                    return ""

            print(f"  🤖 [Step 3] {len(_still_dark)} gap(s) had no visual signal at all — "
                  f"asking Ollama to find topic shifts in the transcript instead...", flush=True)
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
                print(f"  🤖 [Step 3] Ollama topic-shift pass added {_ai_recovered} more "
                      f"transition(s): {len(slide_timestamps)} total now.", flush=True)

if expected_slide_count and len(slide_timestamps) < expected_slide_count:
    print(f"  ⚠ Still found fewer transitions ({len(slide_timestamps)}) than the deck's "
          f"{expected_slide_count} slides. Remaining gaps are likely slides shown very "
          f"briefly, skipped in the recording, or visually near-identical to a neighbour.",
          flush=True)

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
MIN_DWELL_SEC     = 1.5
MIN_SPOKEN_WORDS  = 4

try:
    _all_segments_s3 = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []
except Exception:
    _all_segments_s3 = []

def _spoken_word_count(a, b):
    return sum(
        len(s.get("text", "").split())
        for s in _all_segments_s3 if a <= s.get("start", 0) < b
    )

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
        print(f"  ⚠ Dropping {len(_transient)} transient transition(s) — too brief "
              f"(<{MIN_DWELL_SEC}s) with no meaningful speech, so likely a quick flick "
              f"or scroll-through rather than a slide the lecturer actually presented: "
              f"{[round(t, 2) for t in _transient]}", flush=True)
        slide_timestamps = sorted(_kept)
        _transient_path = os.path.join(output_dir, filename + "_transient_transitions.json")
        with open(_transient_path, "w") as _f:
            json.dump(_transient, _f, indent=2)

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
        print(f"  ⚠ {len(_unresolved)} gap(s) are still unusually long relative to the rest "
              f"of the video even though the overall count looks complete — these are worth "
              f"checking by hand, since they can hide a missed slide standing in for a "
              f"visually-similar neighbour:", flush=True)
        for g_start, g_end in _unresolved:
            print(f"      {g_start:.1f}s – {g_end:.1f}s  ({g_end - g_start:.1f}s, "
                  f"vs {_final_qualify:.0f}s expected)", flush=True)

print(f"  Found {len(slide_timestamps)} slides.", flush=True)
print(f"  Saved to {out_path}", flush=True)

# ── Capture screengrabs at each detected slide timestamp ──────────────────────
screengrabs_dir = os.path.join(output_dir, filename + "_screengrabs")
os.makedirs(screengrabs_dir, exist_ok=True)

cap2             = cv2.VideoCapture(video_path)
screengrab_paths = []

# A screen-change is detected at the moment a transition *starts*, which can
# land on a fade/dissolve frame — or, if the recording briefly drops the
# screen-share, an outright black frame. Settling briefly after the cut and,
# if needed, probing a little further forward avoids capturing those instead
# of the actual slide content.
SETTLE_OFFSET      = 0.6   # seconds to wait after a detected cut before grabbing
BLACK_MEAN_THRESH  = 14.0  # mean grayscale intensity below this = near-black frame
MAX_PROBE_AHEAD    = 2.5   # seconds allowed searching forward for real content
PROBE_STEP         = 0.3   # seconds per probe step

def _read_frame_at(cap, t_sec):
    cap.set(cv2.CAP_PROP_POS_MSEC, max(t_sec, 0) * 1000)
    ok, frm = cap.read()
    return frm if ok else None

def _mean_intensity(frame):
    return float(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).mean())

def _sharpness(frame):
    """Laplacian variance — a standard focus/motion-blur proxy. A frame still
    mid-fade or mid-dissolve is low-contrast/blurry even once it's no longer
    dark enough to count as 'black', so this catches what the brightness
    check alone can't."""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())

for idx, ts in enumerate(slide_timestamps):
    next_ts    = slide_timestamps[idx + 1] if idx + 1 < len(slide_timestamps) else None
    # Don't let the settle offset run past the very next transition.
    ceiling    = (next_ts - 0.15) if next_ts is not None else (ts + MAX_PROBE_AHEAD + SETTLE_OFFSET)
    capture_ts = min(ts + SETTLE_OFFSET, max(ts, ceiling))

    frame = _read_frame_at(cap2, capture_ts)

    if frame is not None and _mean_intensity(frame) < BLACK_MEAN_THRESH:
        # Collect every non-black candidate in the probe window (it's already
        # bounded to MAX_PROBE_AHEAD / PROBE_STEP ≈ 8 steps) and keep the
        # sharpest rather than just the first one that clears the brightness
        # bar — the first non-black frame after a fade is often still
        # mid-dissolve and visibly softer than the fully-settled slide a few
        # steps further on.
        probe_ts     = capture_ts
        probe_limit  = min(ts + SETTLE_OFFSET + MAX_PROBE_AHEAD, ceiling)
        candidates   = []  # (sharpness, probe_ts, frame)
        while probe_ts < probe_limit:
            probe_ts   += PROBE_STEP
            probe_frame = _read_frame_at(cap2, probe_ts)
            if probe_frame is not None and _mean_intensity(probe_frame) >= BLACK_MEAN_THRESH:
                candidates.append((_sharpness(probe_frame), probe_ts, probe_frame))
        if candidates:
            _, capture_ts, frame = max(candidates, key=lambda c: c[0])

    if frame is not None:
        sg_img_path = os.path.join(screengrabs_dir, f"screengrab_{idx:03d}.png")
        cv2.imwrite(sg_img_path, frame)
        screengrab_paths.append(sg_img_path)
        _flag = "  ⚠ still near-black — screen-share may have dropped" \
                if _mean_intensity(frame) < BLACK_MEAN_THRESH else ""
        print(f"  Screengrab {idx+1} (t={capture_ts:.2f}s){_flag}: {sg_img_path}", flush=True)
    else:
        screengrab_paths.append("")
        print(f"  Screengrab {idx+1} (t={ts:.2f}s): could not read frame", flush=True)

cap2.release()

sg_list_path = os.path.join(output_dir, filename + "_screengrabs.json")
with open(sg_list_path, "w") as f:
    json.dump(screengrab_paths, f, indent=2)

print(f"  Screengrabs saved to: {screengrabs_dir}", flush=True)
print(f"  Screengrab list saved to: {sg_list_path}", flush=True)
PYEOF
fi

echo -e "${GREEN}  Slide detection complete.${NC}"

# ─── Steps 4–7: Render, Align, Assign, Generate ────────────────────────────────
echo -e "\n${YELLOW}Steps 4–7: Rendering slides, aligning, and generating output...${NC}"

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

# ── Load previously generated data ───────────────────────────────────────────
segments = mmap_read_json(os.path.join(output_dir, filename + "_segments.json"), default=[]) or []

slide_times = mmap_read_json(os.path.join(output_dir, filename + "_slide_times.json"), default=[]) or []
num_slides = len(slide_times)

sg_list_path = os.path.join(output_dir, filename + "_screengrabs.json")
if os.path.exists(sg_list_path):
    screengrab_imgs = mmap_read_json(sg_list_path, default=[]) or []
else:
    screengrab_imgs = []

# ─── AI helper (local Ollama) — set up early so alignment can use it too ─────
# Everything here is best-effort: if Ollama isn't enabled, isn't running, or a
# request fails/times out, callers simply get None back and the rest of the
# pipeline proceeds exactly as it would without AI enabled.
import urllib.request, urllib.error, socket
import sys, time, threading

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

    Redraws itself on a background timer (so the ETA/elapsed time keeps
    ticking even while blocked on a slow/retrying Ollama request) rather
    than only updating when an item finishes. Replaces the old behaviour of
    printing a new scrolling line for every timeout/retry.

    TTY-aware: when stdout is a real interactive terminal, this redraws a
    single line in place using '\\r'. When stdout is NOT a TTY (piped
    through 'tee', redirected to a log file, some IDE terminal panes that
    don't emulate carriage-return overwrite), '\\r' doesn't erase anything —
    every tick would instead show up as its own line, flooding the log with
    thousands of near-duplicate lines. In that case this falls back to
    printing one plain line per completed item (or every few seconds while
    waiting), which stays readable in a log file.
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
        # Once a single item has been running unusually long with no result
        # yet, say so explicitly — otherwise a slow-but-working local model
        # (a big prompt on a small model) looks indistinguishable from a
        # genuine hang, especially on the very first item where 'elapsed'
        # and 'this item' are the same number.
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

# Set by the pre-generation pass below while it's active; ollama_generate()
# reports retries/timeouts through it (as a status suffix on the progress
# bar) instead of printing a new scrolling warning line for each one. Falls
# back to plain print()s when no bar is active (e.g. the Step 3 gap re-scan,
# which runs before this pass and has no per-slide bar of its own).
_AI_PROGRESS_BAR = [None]

_AI_CACHE_PATH = os.path.join(output_dir, filename + "_ai_cache.json")
_ai_cache = mmap_read_json(_AI_CACHE_PATH, default={}) or {}

def _save_ai_cache():
    try:
        with open(_AI_CACHE_PATH, "w") as _f:
            json.dump(_ai_cache, _f, indent=2)
    except Exception:
        pass

def ollama_generate(prompt, timeout=90, context="", retries=1):
    """Call the local Ollama server's /api/generate endpoint. Returns the
    generated text, or None on any failure (server down, timeout, bad model, etc.).

    context: short human-readable label (e.g. "slide 42 spoken takeaway") used
    only to make failure warnings identifiable — without it, every timeout
    prints the same generic line and it's impossible to tell whether a
    handful of items failed (fine — they're just skipped) or something
    systemic is wrong.

    retries: on a timeout specifically (not on other errors — a malformed
    request or a down server won't fix itself), one retry is attempted with
    1.5x the timeout before giving up. A single slow response on a loaded
    local model is common and often just needs a bit more time; giving up
    immediately produces more visible failures than the model actually has.
    """
    if not AI_ENABLED:
        return None
    if not prompt or not isinstance(prompt, str):
        return None
    # A local 3B-class model has a small context window; a prompt this large
    # is almost certainly a bug upstream (e.g. an unbounded transcript dump)
    # rather than something the model could usefully consume anyway, and
    # sending it would just guarantee a timeout after tying up the request.
    if len(prompt.encode("utf-8")) > 200_000:
        print(f"  ⚠ Prompt too large for Ollama{' (' + context + ')' if context else ''} "
              f"— skipping AI for this item.", flush=True)
        return None
    payload = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2},
    }
    MAX_ATTEMPT_TIMEOUT = max(timeout * 3, 180)  # hard ceiling regardless of retries/backoff
    attempt_timeout = timeout
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(
                "http://localhost:11434/api/generate",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=attempt_timeout) as resp:
                raw = resp.read().decode("utf-8")
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                data = None
            if not isinstance(data, dict):
                print(f"  ⚠ Ollama returned a malformed response{' (' + context + ')' if context else ''} "
                      f"— skipping AI content for this item.", flush=True)
                _OLLAMA_FAILURE_COUNT[0] += 1
                return None
            text = (data.get("response") or "").strip()
            # A handful of characters or a bare "I don't know" isn't a usable
            # takeaway — treat it the same as no response at all rather than
            # passing it through into the final output.
            if len(text) < 5:
                return None
            _low = text.lower()
            if any(_m in _low for _m in ("i don't know", "i'm not sure", "cannot determine",
                                          "no information", "unable to determine")):
                return None
            return text
        except (TimeoutError, socket.timeout, urllib.error.URLError, OSError) as _e:
            # A read/connect timeout can surface as socket.timeout directly,
            # or wrapped inside URLError.reason — check both explicitly
            # rather than leaning on locale-dependent string matching, which
            # is kept only as a last-resort fallback below.
            _is_timeout = (
                isinstance(_e, (TimeoutError, socket.timeout))
                or isinstance(getattr(_e, "reason", None), (TimeoutError, socket.timeout))
                or "timed out" in str(_e).lower()
            )
            _bar = _AI_PROGRESS_BAR[0]
            if _is_timeout and attempt < retries:
                attempt_timeout = min(int(attempt_timeout * 1.5), MAX_ATTEMPT_TIMEOUT)
                if _bar:
                    _bar.set_status(f"{context or 'item'} timed out — retrying ({attempt_timeout}s timeout)")
                else:
                    print(f"  ⚠ Ollama request timed out{' (' + context + ')' if context else ''} "
                          f"— retrying once with a longer timeout ({attempt_timeout}s)...", flush=True)
                continue
            _label = f" ({context})" if context else ""
            if _bar:
                _bar.set_status(f"{context or 'item'} failed — skipping")
            else:
                print(f"  ⚠ Ollama request failed ({_e}){_label} — skipping AI content for this item.", flush=True)
            _OLLAMA_FAILURE_COUNT[0] += 1
            return None
        except Exception as _e:
            _bar = _AI_PROGRESS_BAR[0]
            _label = f" ({context})" if context else ""
            if _bar:
                _bar.set_status(f"{context or 'item'} failed — skipping")
            else:
                print(f"  ⚠ Ollama request failed ({_e}){_label} — skipping AI content for this item.", flush=True)
            _OLLAMA_FAILURE_COUNT[0] += 1
            return None

# Mutable single-element list (not a plain int) so nested functions can bump
# it without needing a global declaration in every call site.
_OLLAMA_FAILURE_COUNT = [0]

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

def extract_pdf_texts(path):
    """Extract text from a PDF (pdfplumber → ghostscript → PyMuPDF)."""
    texts = []
    try:
        import pdfplumber
        with pdfplumber.open(path) as _pdf:
            texts = [(p.extract_text() or "").strip() for p in _pdf.pages]
        if any(texts):
            return texts
        print("  ⚠ pdfplumber returned empty text — trying ghostscript normalisation", flush=True)
    except Exception as _pdf_err:
        print(f"  ⚠ pdfplumber failed ({_pdf_err}), falling back", flush=True)

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
        print(f"  ⚠ ghostscript normalisation failed ({_gs_err})", flush=True)

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
            print(f"  ⚠ PyMuPDF extraction failed ({_fitz_path_err}); mmap fallback also failed ({_fitz_err})", flush=True)
            return []

if USE_SCREENGRABS_ONLY:
    print("  [Step 4b] Screen-grabs only mode — no source slide text to extract.", flush=True)
    slide_texts = [""] * num_slides
else:
    slide_texts = extract_pptx_texts(slides_file) if slides_type == "pptx" else extract_pdf_texts(slides_file)
    _n_source = len(slide_texts)
    if _n_source != num_slides:
        # IMPORTANT: do NOT truncate slide_texts to num_slides (the number of
        # transitions the video diff-scan detected). Video transition
        # detection is exactly the step most likely to under-count when two
        # adjacent slides look almost identical (a build/reveal step, or a
        # template slide that changes only a small detail) — the frame-to-
        # frame difference is weak, so no cut gets registered. If slide_texts
        # were then chopped down to that smaller, wrong count, every source
        # slide past the miss would become permanently unreachable as an
        # alignment candidate, regardless of how good the alignment scoring
        # is. slide_texts is kept at its true, full length (matching the
        # actual number of rendered source-slide images) so the alignment
        # step below always has every real slide available to match against.
        print(f"  ⚠ Slide count mismatch: source file has {_n_source} slides, "
              f"video detection found {num_slides} transitions. Keeping all "
              f"{_n_source} source slides available for alignment (this is "
              f"very likely under-detection on near-duplicate slides, not "
              f"extra slides in the deck).", flush=True)

# ─── Step 4: Render source slides to images ──────────────────────────────────

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
        # Same path-open → mmap-stream fallback as extract_pdf_texts above
        # (handles a locked/permission-restricted file, e.g. mid iCloud
        # sync). PyMuPDF copies the stream into its own buffer on open, so
        # it's safe for the mmap to close right after.
        with open(path, "rb") as _f:
            with mmap.mmap(_f.fileno(), 0, access=mmap.ACCESS_READ) as _mm:
                doc = fitz.open(stream=_mm, filetype="pdf")
    try:
        for i, page in enumerate(doc):
            pix      = page.get_pixmap(dpi=dpi)
            img      = PILImage.frombytes("RGB", [pix.width, pix.height], pix.samples)
            out_path = os.path.join(out_dir, f"{prefix}_source_slide_{i:03d}.png")
            img.save(out_path, format="PNG", optimize=True)
            paths.append(out_path)
    finally:
        doc.close()
    return paths

def render_pptx_to_image_files(pptx_path, out_dir, prefix, dpi=150):
    """Convert PPTX → PDF via LibreOffice, then render to PNG. Returns list of file paths."""
    import subprocess, tempfile, shutil, glob
    tmp_dir     = tempfile.mkdtemp()
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
            print("  [Step 4] LibreOffice: no PDF on first attempt — retrying with fresh profile...")
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

if USE_SCREENGRABS_ONLY:
    print("\n  [Step 4] Screen-grabs only mode — skipping source slide rendering.", flush=True)
    slide_source_imgs = [p for p in screengrab_imgs if p and os.path.exists(p)]
    print(f"  [Step 4] {len(slide_source_imgs)} screengrab image(s) available.", flush=True)
else:
    # Rendered into their own subfolder (mirroring how screengrabs get their
    # own "<name>_screengrabs/" folder below) so the base deck's rendered
    # pixels/colors sit right next to the screengrabs they'll be compared
    # against — easy to eyeball side by side, and each one gets its own
    # logged path rather than just a final count.
    source_slides_dir = os.path.join(output_dir, filename + "_source_slides")
    os.makedirs(source_slides_dir, exist_ok=True)
    print("\n  [Step 4] Rendering source slide images...", flush=True)
    if slides_type == "pdf":
        slide_source_imgs = render_pdf_to_image_files(slides_file, source_slides_dir, filename)
    else:
        slide_source_imgs = render_pptx_to_image_files(slides_file, source_slides_dir, filename)
    for _k, _p in enumerate(slide_source_imgs):
        print(f"  Source slide {_k+1} (base deck): {_p}", flush=True)
    print(f"  [Step 4] {len(slide_source_imgs)} source slide image(s) rendered.", flush=True)
    print(f"  Source slides saved to: {source_slides_dir}", flush=True)

# ─── Step 5: Align screengrabs → source slides ───────────────────────────────

def _load_gray_thumbnail(path, size=(256, 144), mask_webcam=False):
    """Load an image as a grayscale thumbnail.

    When mask_webcam is True the bottom-right corner of the thumbnail is set
    to mid-grey (128) to neutralise the lecturer's webcam/face PIP overlay
    before any comparison is made.  Source slide images should be loaded with
    the default mask_webcam=False because they never contain a webcam overlay.

    Returns None (rather than raising) for any image that can't be loaded or
    decoded — a missing file, a zero-byte/truncated file, or one whose bytes
    cv2 can technically decode into an array but that then blows up on
    resize/color-convert (e.g. a 0-width strip from a corrupted screen
    recording frame). cv2.imread() already returns None for the first case;
    the try/except below covers the second, rarer case so one bad frame can't
    crash the whole alignment run.
    """
    import cv2 as _cv2
    try:
        img = _cv2.imread(path)
        if img is None or img.size == 0:
            return None
        img = _cv2.resize(img, size, interpolation=_cv2.INTER_AREA)
        gray = _cv2.cvtColor(img, _cv2.COLOR_BGR2GRAY)
    except Exception as _load_err:
        print(f"  ⚠ Could not load/decode image, skipping ({path}): {_load_err}", flush=True)
        return None

    # Normalise brightness/contrast (CLAHE) so exposure differences between a
    # screen-recorded frame and a freshly-rendered source slide — dimmer
    # capture, projector glare, codec gamma shifts — don't get read as a
    # content difference by SSIM/NCC/pixel-diff. Applied after masking would
    # let the mid-grey mask patch skew the histogram, so it happens first.
    try:
        _clahe = _cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray = _clahe.apply(gray)
    except Exception:
        pass  # normalisation is best-effort; comparison still works without it

    if mask_webcam:
        _h, _w = gray.shape
        gray[int(_h * (1 - WEBCAM_MASK_FRAC)):, int(_w * (1 - WEBCAM_MASK_FRAC)):] = 128
    return gray

def _compare_with_masks(sg_gray, src_gray):
    """SSIM + NCC + pixel-diff blended score with corner masking for lecturer
    overlay.

    Three signals, each catching something the others miss:
      - SSIM: structural/perceptual similarity over local windows. Robust to
        minor noise/compression, but a single small change (one revealed
        bullet, one changed digit) gets diluted into a whole-frame average —
        the window it falls in scores lower, but the rest of the frame pulls
        the overall number back up.
      - NCC (OpenCV matchTemplate): a normalized correlation over the whole
        frame; fast, similar blind spot to SSIM for small localized changes.
      - Pixel-diff (pixelmatch): counts pixels that differ by more than a
        threshold, with anti-aliasing-aware matching so resized/re-encoded
        text edges aren't counted as differences on their own. Unlike SSIM/
        NCC this isn't diluted by frame size — a small but real content
        change still shows up as its own distinct percentage, which is
        exactly the failure mode SSIM/NCC have on near-duplicate slides.

    Returns early once a mask variant scores above HIGH_CONF_EARLY_EXIT so that
    the remaining (less-likely) mask variants are skipped, keeping the per-pair
    comparison fast when slides are easy to align.

    Note: phase_cross_correlation (FFT-based shift estimation) is intentionally
    omitted because its scipy FFT initialisation can block indefinitely in some
    environments, causing the alignment step to hang on the very first comparison.
    """
    import numpy as _np
    import cv2 as _cv2
    # Blended score above this threshold is considered a confident match;
    # remaining mask variants are skipped to avoid unnecessary computation.
    HIGH_CONF_EARLY_EXIT = 0.85
    h, w = sg_gray.shape
    # Use the same corner fraction as the scene-detection and thumbnail steps
    # so all three stages treat the webcam overlay area consistently.
    _mf = WEBCAM_MASK_FRAC
    masks = [
        ("bottom_right", slice(int(h * (1 - _mf)), h), slice(int(w * (1 - _mf)), w)),
        ("bottom_left",  slice(h * 2 // 3, h),         slice(0, w // 3)),
        ("top_right",    slice(0, h // 3),              slice(w * 2 // 3, w)),
        ("top_left",     slice(0, h // 3),              slice(0, w // 3)),
        ("bottom_third", slice(h * 2 // 3, h),          slice(0, w)),
        ("bottom_half",  slice(h // 2, h),              slice(0, w)),
        ("none",         None,                          None),
    ]
    best_score = -1.0
    best_mask  = "none"

    for name, rslice, cslice in masks:
        sg_m  = sg_gray.copy()
        src_m = src_gray.copy()
        if rslice is not None:
            sg_m[rslice, cslice] = 128

        ssim_score = 0.0
        try:
            from skimage.metrics import structural_similarity as _ssim
            ssim_score = float(_ssim(sg_m, src_m, data_range=255))
        except ImportError:
            sg_f  = sg_m.astype(_np.float32)
            src_f = src_m.astype(_np.float32)
            sg_f  -= sg_f.mean()
            src_f -= src_f.mean()
            denom = float(_np.std(sg_f)) * float(_np.std(src_f))
            ssim_score = float((_np.sum(sg_f * src_f) / sg_f.size) / denom) if denom > 1e-3 else 0.0

        ncc_score = 0.0
        try:
            import cv2 as _cv2b
            _res = _cv2b.matchTemplate(
                sg_m.astype(_np.float32),
                src_m.astype(_np.float32),
                _cv2b.TM_CCOEFF_NORMED
            )
            ncc_score = float(_res.max())
        except Exception:
            ncc_score = ssim_score

        pixel_score = None
        try:
            from pixelmatch import pixelmatch as _pixelmatch
            _rgba1 = _np.dstack([sg_m, sg_m, sg_m, _np.full_like(sg_m, 255)]).flatten().tolist()
            _rgba2 = _np.dstack([src_m, src_m, src_m, _np.full_like(src_m, 255)]).flatten().tolist()
            _mismatched = _pixelmatch(_rgba1, _rgba2, w, h, threshold=0.15)
            pixel_score = 1.0 - (_mismatched / float(w * h))
        except Exception:
            pixel_score = None  # library unavailable or a transient failure — just drop this term

        if pixel_score is not None:
            score = 0.55 * ssim_score + 0.30 * ncc_score + 0.15 * pixel_score
        else:
            score = 0.65 * ssim_score + 0.35 * ncc_score

        if score > best_score:
            best_score = score
            best_mask  = name

        # Early exit: score is already high enough — no need to try remaining masks
        if best_score >= HIGH_CONF_EARLY_EXIT:
            break

    return best_score, best_mask

def _is_near_black(gray, mean_threshold=14.0):
    """True if a grayscale thumbnail is (near-)black — e.g. a fade/transition
    frame or a moment the screen-share dropped — and therefore untrustworthy
    for visual comparison."""
    import numpy as _np
    return bool(_np.mean(gray) < mean_threshold)

_ocr_cache = {}

def _ocr_text_for_image(path):
    """Best-effort OCR of a screengrab, used purely as a *tie-breaker* signal
    for alignment (not for anything user-facing). Whole-frame SSIM/NCC can't
    tell two near-identical slides apart when the only difference is a small
    amount of text (a revealed bullet, an updated number, a highlighted row).
    OCR catches exactly that, since it reads the words instead of the pixels.
    Failures are swallowed — OCR is an enhancement, not a requirement.
    """
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
    return [w for w in _re.findall(r"[a-z0-9]+", text.lower()) if len(w) > 1]

def _text_similarity(a, b):
    """Cheap, dependency-free text similarity in [0, 1], blending exact-token
    overlap (robust to OCR noise/word-order) with a sequence-based ratio
    (catches near-identical phrasing). Returns 0.0 if either side is empty.
    """
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
    """Build a globally-optimal, monotonic (non-decreasing) screengrab→source-
    slide alignment.

    The previous approach searched forward greedily from the last match and
    permanently advanced its search window to whatever it just picked. That
    meant a single bad comparison — most commonly a near-black transition
    frame, which resembles nothing — could push the search window past the
    correct slides forever, so every screengrab after it also came out wrong.

    This version instead scores every screengrab against every source slide
    once, then finds the best-scoring non-decreasing assignment across the
    *entire* sequence with dynamic programming (similar to DTW). A single bad
    frame can no longer derail anything past it, because the DP considers the
    whole path, not just what came immediately before.

    When slide_texts is provided, the per-pair score also blends in an OCR
    text-similarity term. Pure image similarity (SSIM/NCC) treats two
    near-identical slides — the same template with one bullet revealed, or
    one number changed — as almost the same slide, because the vast majority
    of pixels genuinely are unchanged. Reading the words on screen and
    comparing them against each candidate's known text breaks that tie using
    exactly the minor detail that pixels alone wash out.
    """
    n_sg  = len(screengrab_imgs)
    n_src = len(slide_source_imgs)
    if n_sg == 0 or n_src == 0:
        return []

    src_grays = [_load_gray_thumbnail(p) if (p and os.path.exists(p)) else None
                 for p in slide_source_imgs]
    sg_grays  = [_load_gray_thumbnail(p, mask_webcam=True) if (p and os.path.exists(p)) else None
                 for p in screengrab_imgs]

    black_flags = [g is not None and _is_near_black(g) for g in sg_grays]
    if any(black_flags):
        _black_idxs = [i for i, f in enumerate(black_flags) if f]
        print(f"  ⚠ {len(_black_idxs)} screengrab(s) look near-black and will be "
              f"scored cautiously: {[i+1 for i in _black_idxs]}", flush=True)

    # For very large decks, cap total comparisons by only scoring source
    # slides within a band around each screengrab's expected linear position,
    # rather than the full n_sg × n_src matrix. Correctness is unaffected for
    # any deck small enough to fit under the cap (the overwhelming majority).
    MAX_CELLS = 6000
    band = None
    if n_sg * n_src > MAX_CELLS:
        band = max(15, MAX_CELLS // max(n_sg, 1))
        print(f"  Large deck — comparing within a ±{band}-slide band around the "
              f"expected position to keep runtime reasonable.", flush=True)

    NEUTRAL = 0.0  # score used where a comparison wasn't made / isn't possible
    S         = [[NEUTRAL] * n_src for _ in range(n_sg)]
    mask_used = [["none"] * n_src for _ in range(n_sg)]

    # Text similarity is a *secondary* signal used only to break near-ties
    # between visually similar candidates — it never dominates the image
    # score, since OCR on a screen recording is noisy and slide_texts may be
    # sparse (image-only slides, diagrams, etc).
    IMG_WEIGHT, TEXT_WEIGHT = 0.75, 0.25
    have_texts = bool(slide_texts)
    sg_ocr_texts = [None] * n_sg
    if have_texts:
        print("  OCR'ing screengrabs for text-based tie-breaking...", flush=True)
        for i, p in enumerate(screengrab_imgs):
            if p and os.path.exists(p) and not black_flags[i]:
                sg_ocr_texts[i] = _ocr_text_for_image(p)

    # Corpus-wide boilerplate filter for the strong-match rule below: a word
    # that shows up on more than half the source slides (course title, term
    # dates, instructor name, "Lecture N" style footers) is by definition not
    # distinctive — a screengrab sharing only boilerplate words with a source
    # slide tells you nothing about *which* slide it actually is, so those
    # words are excluded before counting how many distinctive words two texts
    # share.
    _BOILERPLATE_WORDS = set()
    if have_texts and n_src > 2:
        _doc_freq = {}
        for _t in slide_texts:
            for _w in set(_normalize_words(_t or "")):
                _doc_freq[_w] = _doc_freq.get(_w, 0) + 1
        _BOILERPLATE_WORDS = {w for w, c in _doc_freq.items() if c > max(2, n_src * 0.5)}

    strong_text_matches = []  # (screengrab_idx, source_idx, distinctive_word_count)

    print(f"  Comparing {n_sg} screengrab(s) against {n_src} source slide(s)...", flush=True)
    for i in range(n_sg):
        print(f"  Scoring screengrab {i+1}/{n_sg}...", end=" ", flush=True)
        if sg_grays[i] is None:
            print("no image available", flush=True)
            continue
        if band is not None:
            _center = int(round(i * (n_src - 1) / max(n_sg - 1, 1)))
            _lo, _hi = max(0, _center - band), min(n_src - 1, _center + band)
            j_range = range(_lo, _hi + 1)
        else:
            j_range = range(n_src)
        n_scored = 0
        # A near-black screengrab carries essentially no visual information —
        # comparing it against slides would produce arbitrary "best" matches,
        # so it's left at NEUTRAL for every candidate and resolved later
        # (Ollama verification pass, or by falling back to its neighbours).
        if black_flags[i]:
            print("near-black — deferring to text/context", flush=True)
            continue
        for j in j_range:
            if src_grays[j] is None:
                continue
            img_score, mask_name = _compare_with_masks(sg_grays[i], src_grays[j])
            score = img_score
            if have_texts and sg_ocr_texts[i] and slide_texts[j].strip():
                txt_score = _text_similarity(sg_ocr_texts[i], slide_texts[j])
                score = IMG_WEIGHT * img_score + TEXT_WEIGHT * txt_score
                # Strong-match rule: 5+ distinctive words shared, plus some
                # non-trivial pixel/color correlation (this is not a text-only
                # override — a screengrab and a source slide that genuinely
                # depict the same content should agree on color/layout too,
                # even if OCR noise or a build/reveal animation keeps the raw
                # SSIM/NCC/pixel-diff score itself modest). When both hold,
                # this pair is treated as effectively confirmed rather than
                # left to quietly lose a close race to a visually-noisier but
                # textually-unrelated competitor.
                _distinctive_overlap = (
                    (set(_normalize_words(sg_ocr_texts[i])) - _BOILERPLATE_WORDS)
                    & (set(_normalize_words(slide_texts[j])) - _BOILERPLATE_WORDS)
                )
                if len(_distinctive_overlap) >= 5 and img_score >= 0.12:
                    score = max(score, 0.92)
                    strong_text_matches.append((i, j, len(_distinctive_overlap)))
            S[i][j] = score
            mask_used[i][j] = mask_name
            n_scored += 1
        print(f"scored against {n_scored}", flush=True)

    if strong_text_matches:
        print(f"  ✓ {len(strong_text_matches)} screengrab/source-slide pair(s) confirmed by a "
              f"strong text match (5+ distinctive shared words + pixel correlation) — "
              f"treated as high-confidence regardless of raw image score:", flush=True)
        for _i, _j, _n in strong_text_matches:
            print(f"      screengrab {_i+1} ↔ source slide {_j+1}  ({_n} distinctive words shared)",
                  flush=True)

    # ── Dynamic programming: best-scoring non-decreasing assignment ─────────
    # dp[j] = best cumulative score for the screengrabs seen so far, ending
    # with the current screengrab assigned to source slide j.
    dp     = list(S[0])
    choice = [[-1] * n_src for _ in range(n_sg)]  # choice[i][j] = slide used by screengrab i-1

    for i in range(1, n_sg):
        running_best_val = float("-inf")
        running_best_idx = 0
        running_max  = [0.0] * n_src
        running_from = [0] * n_src
        for j in range(n_src):
            if dp[j] > running_best_val:
                running_best_val = dp[j]
                running_best_idx = j
            running_max[j]  = running_best_val
            running_from[j] = running_best_idx
        new_dp = [S[i][j] + running_max[j] for j in range(n_src)]
        choice[i] = running_from
        dp = new_dp

    end_j = max(range(n_src), key=lambda j: dp[j])
    path  = [0] * n_sg
    path[n_sg - 1] = end_j
    for i in range(n_sg - 1, 0, -1):
        end_j = choice[i][end_j]
        path[i - 1] = end_j

    alignment = []
    for i in range(n_sg):
        j = path[i]
        score = S[i][j]
        # Runner-up score for this screengrab, regardless of DP path — this is
        # what actually tells us whether the match was clear-cut or a
        # coin-flip between two near-identical slides. A confidently *wrong*
        # match (e.g. picking the wrong one of two build-animation frames)
        # still scores high in absolute terms, so the absolute score alone
        # can't catch it; a small gap to the runner-up can.
        row_sorted = sorted(S[i], reverse=True)
        second_best = row_sorted[1] if len(row_sorted) > 1 else 0.0
        alignment.append({
            "screengrab_index":   i,
            "source_slide_index": j,
            "score":              round(float(score), 4),
            "second_best_score":  round(float(second_best), 4),
            "mask_region":        mask_used[i][j],
            "near_black":         black_flags[i],
        })
        print(f"  Screengrab {i+1}/{n_sg} → src slide {j+1}  score={score:.3f}  "
              f"(runner-up {second_best:.3f})  mask={mask_used[i][j]}", flush=True)

    return alignment

def _find_stuck_runs(alignment, min_len=3):
    """Return index-ranges (start, end inclusive) of consecutive screengrabs
    assigned to the SAME source slide, length >= min_len.

    A run this long is the visible symptom the user is hitting: a handful of
    near-identical slides (e.g. a build/reveal sequence) all confidently
    "win" the match for the same one source slide, because whole-frame image
    similarity can't see past their shared background. The other slides in
    the run then never get picked at all, and the merged output repeats the
    one slide that did win. This is flagged for re-checking independent of
    each entry's individual score, since the individual scores can each look
    perfectly confident on their own.
    """
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

def ollama_verify_alignment(alignment, slide_texts, slide_times, segments, screengrab_imgs=None):
    """Second, semantic pass over ambiguous matches.

    Image similarity alone can't distinguish two slides whenever they share
    almost all of their pixels — a build/reveal animation, a template slide
    where only one number or bullet changed, etc. Critically, that kind of
    ambiguity does NOT show up as a low absolute score: the wrong candidate
    can still score high, because most of the frame really is identical.  So
    this pass no longer relies on absolute score alone. Three independent
    signals can each flag a screengrab for a semantic re-check:

      1. Absolute score is low, or the frame was near-black (original logic).
      2. The margin between the best and second-best candidate is small — the
         visual match was a near-tie, regardless of how high both scores are.
      3. The screengrab sits inside a "stuck run" of >=3 consecutive
         screengrabs all mapped to the same source slide — the tell-tale
         signature of a near-duplicate sequence collapsing onto one winner.

    For flagged screengrabs, the local Ollama model is asked to pick the best
    candidate using: what the lecturer was actually saying (plus a little
    surrounding context so it can reason about narrative progression), what
    text OCR could read off the screengrab itself, and each candidate's known
    slide text. This never overrides a confident, unambiguous visual match.
    """
    if not AI_ENABLED or not alignment:
        return alignment

    LOW_CONF      = 0.42
    MARGIN_THRESH = 0.06  # best vs runner-up closer than this = treat as a tie
    STUCK_RUN_MIN = 3
    WINDOW        = 5  # how many slides either side of the visual guess to offer as candidates
    n_src    = len(slide_texts)
    n_sg     = len(alignment)
    resolved = 0

    stuck_idxs = set()
    for start, end in _find_stuck_runs(alignment, STUCK_RUN_MIN):
        # Keep the first of the run as-is (most likely to be the genuine
        # first appearance); flag the rest for a semantic re-check.
        for k in range(start + 1, end + 1):
            stuck_idxs.add(k)
    if stuck_idxs:
        print(f"  ⚠ {len(stuck_idxs)} screengrab(s) sit inside a repeated-match run "
              f"and will get a semantic re-check regardless of their visual score.", flush=True)

    for i, entry in enumerate(alignment):
        margin = entry["score"] - entry.get("second_best_score", 0.0)
        needs_help = (
            entry["score"] < LOW_CONF
            or entry.get("near_black")
            or margin < MARGIN_THRESH
            or i in stuck_idxs
        )
        if not needs_help or n_src == 0:
            continue

        center = entry["source_slide_index"] if entry["source_slide_index"] is not None else 0
        lo, hi = max(0, center - WINDOW), min(n_src - 1, center + WINDOW)
        candidates = [c for c in range(lo, hi + 1) if slide_texts[c].strip()]
        if len(candidates) <= 1:
            continue

        start_t = slide_times[i]
        end_t   = slide_times[i + 1] if i + 1 < n_sg else float("inf")

        def _spoken_between(a, b):
            return " ".join(
                s["text"].strip() for s in segments if a <= s.get("start", 0) < b
            ).strip()

        spoken = _spoken_between(start_t, end_t)
        if not spoken:
            continue
        # A little surrounding context helps the model reason about
        # narrative progression ("still on the same point" vs "moved on"),
        # which is exactly the cue image similarity is blind to.
        prev_spoken = _spoken_between(max(0.0, start_t - 45), start_t)
        next_spoken = _spoken_between(end_t, end_t + 45) if end_t != float("inf") else ""

        ocr_text = ""
        if screengrab_imgs and i < len(screengrab_imgs) and screengrab_imgs[i]:
            ocr_text = _ocr_text_for_image(screengrab_imgs[i]).strip()

        options_block = "\n".join(
            f"{c+1}) {slide_texts[c].strip()[:300]}" for c in candidates
        )
        context_lines = []
        if prev_spoken:
            context_lines.append(f"(just before) \"{prev_spoken[-400:]}\"")
        context_lines.append(f"(this moment) \"{spoken[:1500]}\"")
        if next_spoken:
            context_lines.append(f"(just after) \"{next_spoken[:400]}\"")
        spoken_block = "\n".join(context_lines)

        ocr_block = f"\nText the system could read directly off the screen at this moment:\n\"{ocr_text[:400]}\"\n" if ocr_text else ""

        prompt = (
            "A lecture recording's automatic slide-detection was ambiguous for one "
            "moment — likely because two or more candidate slides look almost "
            "identical (e.g. a build/reveal animation, or a template slide that "
            "differs only in a small detail). It's also possible the lecturer is on "
            "a slide that genuinely isn't in the provided slide file at all (e.g. an "
            "ad-hoc/annotated slide, or the file is an older/incomplete export).\n\n"
            f"What the lecturer was saying:\n{spoken_block}\n"
            f"{ocr_block}\n"
            f"Candidate slides (number, then their known text):\n{options_block}\n\n"
            "Which candidate slide number is the lecturer most likely on? Weigh "
            "small details — a specific number, label, or bullet mentioned or "
            "read off the screen — over general topic similarity, since that's "
            "usually what distinguishes near-identical candidates. "
            "If NONE of the candidates genuinely match what's being said/shown, "
            "reply with exactly 0. Otherwise reply with ONLY the candidate number, "
            "nothing else."
        )
        result = ollama_generate(prompt, timeout=60, context=f"screengrab {i+1} — alignment check")
        if not result:
            continue
        import re as _re
        m = _re.search(r"\d+", result)
        if not m:
            continue
        picked_raw = int(m.group())
        if picked_raw == 0:
            # The model judged that no candidate genuinely matches — this
            # screengrab is very likely showing something that isn't in the
            # provided slide file at all. Rather than force it onto the
            # least-wrong candidate, flag it to fall back to the actual video
            # frame (see apply_screengrab_fallback / get_source_slide).
            print(f"  🤖 Ollama: screengrab {i+1} doesn't genuinely match any "
                  f"candidate slide — will use the video screengrab instead.", flush=True)
            entry["use_screengrab"] = True
            entry["mask_region"] = f"{entry.get('mask_region', 'none')}+ai_no_match"
            resolved += 1
            continue
        picked = picked_raw - 1
        if picked in candidates and picked != center:
            print(f"  🤖 Ollama re-aligned screengrab {i+1}: "
                  f"src slide {center+1} → {picked+1}", flush=True)
            entry["source_slide_index"] = picked
            entry["score"] = max(entry["score"], 0.5)
            entry["mask_region"] = f"{entry.get('mask_region', 'none')}+ai_verified"
            resolved += 1

    if resolved:
        print(f"  🤖 Ollama alignment verification resolved {resolved} ambiguous match(es).", flush=True)
    return alignment

NO_MATCH_FLOOR = 0.25  # below this, no candidate is a plausible match at all

def apply_screengrab_fallback(alignment, threshold=NO_MATCH_FLOOR):
    """Flag screengrabs with no plausible match anywhere in the slide deck so
    they fall back to the actual video frame instead of a forced, wrong deck
    slide.

    This is deliberately independent of AI/Ollama: even a purely visual score
    that's uniformly terrible against every candidate (not just the winner —
    a near-tie between two bad options isn't the same situation) is itself
    good evidence the lecturer is showing something that plainly isn't in the
    provided PPTX/PDF at all — a hand-drawn aside, an ad-hoc annotation, a
    slide added after the file was last exported, etc. Forcing a match in
    that case is strictly worse than just showing what was actually on
    screen, so it's flagged here regardless of whether Ollama already had a
    chance to weigh in (its explicit "none of these" case is handled inline
    in ollama_verify_alignment; this catches everything else, AI or no AI).
    """
    flagged = 0
    for entry in alignment:
        if entry.get("use_screengrab"):
            continue
        if entry.get("near_black"):
            continue  # near-black is a screen-share/settle artifact, not "missing from deck"
        if entry["score"] < threshold:
            entry["use_screengrab"] = True
            flagged += 1
    if flagged:
        print(f"  ⚠ {flagged} screengrab(s) had no plausible match anywhere in the slide "
              f"deck (score below {threshold}) — these will show the actual video "
              f"screengrab instead of a forced, likely-wrong deck slide.", flush=True)
    return alignment

if USE_SCREENGRABS_ONLY:
    print("\n  [Step 5] Screen-grabs only mode — using 1:1 identity alignment.", flush=True)
    alignment = [
        {"screengrab_index": i, "source_slide_index": i, "score": 1.0, "mask_region": "none"}
        for i in range(len(screengrab_imgs))
    ]
else:
    print("\n  [Step 5] Building slide alignment (screengrab → source slide)...", flush=True)
    alignment = compute_alignment(screengrab_imgs, slide_source_imgs, slide_texts=slide_texts)
    if AI_ENABLED:
        print("\n  [Step 5b] Ollama verification pass on ambiguous matches...", flush=True)
        alignment = ollama_verify_alignment(alignment, slide_texts, slide_times, segments,
                                             screengrab_imgs=screengrab_imgs)
    alignment = apply_screengrab_fallback(alignment)

align_json_path = os.path.join(output_dir, filename + "_slide_alignment.json")
with open(align_json_path, "w") as _f:
    json.dump(alignment, _f, indent=2)

if alignment:
    _scores    = [e["score"] for e in alignment if e["score"] > 0]
    _avg_score = sum(_scores) / len(_scores) if _scores else 0.0
    print(f"  Alignment: {len(alignment)} segments  avg_score={_avg_score:.3f}", flush=True)
    if not USE_SCREENGRABS_ONLY:
        _LOW_CONF = 0.40
        _low_conf = [e["screengrab_index"] for e in alignment
                     if (0 < e["score"] < _LOW_CONF) or e.get("near_black")]
        if _low_conf:
            _hint = " (try enabling AI enhancements for a semantic re-check)" if not AI_ENABLED else ""
            print(f"  ⚠ Low-confidence or near-black segments{_hint}: {_low_conf}", flush=True)

        # Repeated-match runs are the direct cause of duplicated content in the
        # merged output: several screengrabs collapsing onto one source slide
        # means the slides between them never surface anywhere. Surfacing this
        # here — even when AI re-alignment already ran — makes any remaining
        # repetition visible instead of silently showing up as duplicate pages.
        _remaining_runs = _find_stuck_runs(alignment, min_len=3)
        if _remaining_runs:
            _hint = " (enable AI enhancements for automatic semantic re-checking)" if not AI_ENABLED else ""
            for _rs, _re_ in _remaining_runs:
                _src = alignment[_rs]["source_slide_index"]
                print(f"  ⚠ Screengrabs {_rs+1}-{_re_+1} all matched src slide {_src+1} "
                      f"({_re_ - _rs + 1} in a row){_hint}", flush=True)
        _n_source_slides = len(slide_texts)
        _used = {e["source_slide_index"] for e in alignment if e["source_slide_index"] is not None}
        _skipped = [j + 1 for j in range(_n_source_slides) if j not in _used]
        if _skipped:
            print(f"  ⚠ {len(_skipped)} source slide(s) were never matched to any "
                  f"screengrab: {_skipped}", flush=True)
else:
    print("  No alignment computed.", flush=True)

# ─── Helper functions ─────────────────────────────────────────────────────────

def is_screengrab_fallback(i):
    """True if segment i was flagged as having no genuine match anywhere in
    the slide deck (see apply_screengrab_fallback / ollama_verify_alignment's
    explicit "none of these" case) — meaning it's shown using the actual
    video frame rather than a file from the provided PPTX/PDF."""
    return bool(alignment and i < len(alignment) and alignment[i].get("use_screengrab"))

def get_source_slide(i):
    """Return best source slide image path for segment i, using alignment.

    When segment i was flagged as having no genuine match in the deck (its
    content simply isn't in the provided PPTX/PDF — an ad-hoc slide, an
    annotation, a stale export, etc.), the actual video screengrab is used
    instead of forcing the best-scoring-but-still-wrong deck slide. Showing
    the real frame is strictly more useful than showing confidently
    mislabeled content.
    """
    if is_screengrab_fallback(i) and screengrab_imgs and i < len(screengrab_imgs):
        p = screengrab_imgs[i]
        if p and os.path.exists(p):
            return p
    if alignment and i < len(alignment):
        src_idx = alignment[i]["source_slide_index"]
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
    """Return slide text for alignment-corrected source slide index.

    For a screengrab-fallback segment there's no deck slide to pull text
    from by definition, so the best available text is what OCR could read
    directly off the video frame itself (already computed during alignment
    for tie-breaking, so this is free — just re-used here).
    """
    if is_screengrab_fallback(i) and screengrab_imgs and i < len(screengrab_imgs) and screengrab_imgs[i]:
        return _ocr_text_for_image(screengrab_imgs[i]).strip()
    if alignment and i < len(alignment):
        src_idx = alignment[i]["source_slide_index"]
        if src_idx is not None and src_idx < len(slide_texts):
            return slide_texts[src_idx]
    if i < len(slide_texts):
        return slide_texts[i]
    return ""

def fmt_ts(seconds):
    """Format float seconds as MM:SS."""
    mm, ss = int(seconds // 60), int(seconds % 60)
    return f"{mm:02d}:{ss:02d}"

# ─── Step 6: Assign transcript segments to slides ────────────────────────────

def get_transcript_for_slide(idx, with_timestamps=False):
    """Return transcript text for slide idx, with optional MM:SS prefixes.

    A segment belongs to slide idx if its start time falls within the half-open
    interval [slide_times[idx], slide_times[idx+1]).  This is a simple,
    exhaustive assignment: every Whisper segment appears under exactly one slide
    and no segments are ever silently dropped.
    """
    start = slide_times[idx]
    end   = slide_times[idx + 1] if idx + 1 < num_slides else float("inf")

    segs = [s for s in segments if start <= s.get("start", 0) < end]

    if not segs:
        return "(no speech detected)"
    if with_timestamps:
        return "\n".join(f"[{fmt_ts(s['start'])}] {s['text'].strip()}" for s in segs)
    return " ".join(s["text"].strip() for s in segs)

def get_full_transcript(with_timestamps=True):
    """Return the complete verbatim transcript for the whole lecture.

    All segments are included in chronological order — no boundary filtering or
    slide-assignment logic is applied — guaranteeing that no spoken words are
    omitted from the output.
    """
    sorted_segs = sorted(segments, key=lambda s: s.get("start", 0))
    if not sorted_segs:
        return "(no speech detected)"
    if with_timestamps:
        return "\n".join(f"[{fmt_ts(s['start'])}] {s['text'].strip()}" for s in sorted_segs)
    return " ".join(s["text"].strip() for s in sorted_segs)

# ─── AI content generators (local Ollama) ────────────────────────────────────
# ollama_generate() and the AI cache were already set up earlier (before Step
# 4) so the alignment step could use them too; these build on top of that.

def _get_ai_slide_takeaway_direct(cache_key, slide_txt, label=""):
    """Core slide-only-takeaway generator, addressed by an explicit cache key
    and explicit slide text rather than an index. Shared by the segment-
    indexed getter (TXT/PDF/CSV, where 'index' means video segment) and the
    PPTX builder (where the natural index is the deck's own slide order) so
    both go through identical logic instead of duplicating the prompt.

    Only a genuine result (including "no content to summarize") is cached.
    A failed/timed-out request is left uncached so the next call — whether
    later in this same run (a different output format) or a future re-run —
    gets another chance, instead of being locked in as a permanent skip.
    """
    if not AI_ENABLED:
        return None
    if cache_key in _ai_cache:
        return _ai_cache[cache_key] or None

    slide_txt = (slide_txt or "").strip()
    if not slide_txt:
        _ai_cache[cache_key] = ""  # genuinely nothing to summarize — cache permanently
        _save_ai_cache()
        return None

    prompt = (
        "You are summarizing one slide of a recorded lecture, based only on "
        "the text printed on the slide (ignore anything the lecturer may "
        "have said).\n"
        f"Slide text:\n{slide_txt}\n\n"
        "In 1-2 concise sentences, state the key takeaway a student should "
        "remember from what is written on this slide. Reply with only the "
        "takeaway, no preamble."
    )
    result = ollama_generate(prompt, context=f"{label or cache_key} — slide takeaway")
    if result is not None:
        _ai_cache[cache_key] = result
        _save_ai_cache()
    return result

def _get_ai_spoken_takeaway_direct(cache_key, slide_txt, spoken, label=""):
    """Core spoken-takeaway generator — see _get_ai_slide_takeaway_direct for
    why this takes explicit text/keys rather than an index."""
    if not AI_ENABLED:
        return None
    if cache_key in _ai_cache:
        return _ai_cache[cache_key] or None

    slide_txt = (slide_txt or "").strip()
    spoken    = (spoken or "").strip()
    if spoken == "(no speech detected)":
        spoken = ""
    if not spoken:
        _ai_cache[cache_key] = ""  # genuinely nothing to summarize — cache permanently
        _save_ai_cache()
        return None

    # Cap the transcript fed in: a slide the lecturer lingered on for a long
    # time (long Q&A, a worked example) can otherwise produce a prompt large
    # enough that a small local model takes far longer to respond, making a
    # timeout more likely purely from prompt size rather than anything wrong.
    _MAX_SPOKEN_CHARS = 4000
    if len(spoken) > _MAX_SPOKEN_CHARS:
        spoken = spoken[:_MAX_SPOKEN_CHARS] + " ...(truncated)"

    prompt = (
        "You are summarizing what a lecturer said while presenting one slide "
        "of a recorded lecture.\n"
        f"Slide text (for context only):\n{slide_txt or '(none)'}\n\n"
        f"What the lecturer said while on this slide:\n{spoken}\n\n"
        "In 1-2 concise sentences, state the key takeaway from what the "
        "lecturer said in relation to this slide — focus on what was spoken "
        "(explanations, examples, emphasis, additions) rather than what is "
        "already printed on the slide. Reply with only the takeaway, no "
        "preamble."
    )
    result = ollama_generate(prompt, context=f"{label or cache_key} — spoken takeaway")
    if result is not None:
        _ai_cache[cache_key] = result
        _save_ai_cache()
    return result

def get_ai_slide_takeaway(i):
    """1-2 sentence AI 'key takeaway' for VIDEO SEGMENT i, based ONLY on the
    text of its alignment-resolved slide (no transcript). Used by TXT/PDF/CSV,
    which are built segment-by-segment."""
    return _get_ai_slide_takeaway_direct(
        f"slide_{i}_slide_only", get_slide_text_for_index(i), label=f"slide {i+1}")

def get_ai_spoken_takeaway(i):
    """1-2 sentence AI 'key takeaway' for VIDEO SEGMENT i, based on what the
    lecturer said while on it. Used by TXT/PDF/CSV."""
    return _get_ai_spoken_takeaway_direct(
        f"slide_{i}_spoken", get_slide_text_for_index(i),
        get_transcript_for_slide(i, with_timestamps=False), label=f"slide {i+1}")

def get_ai_lecture_summary():
    """Short executive summary + main topics for the whole lecture. Cached."""
    if not AI_ENABLED:
        return None
    if "full_summary" in _ai_cache:
        return _ai_cache["full_summary"] or None

    full_txt = get_full_transcript(with_timestamps=False)
    # Keep the prompt bounded so a small local model on an M1 stays responsive.
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
    result = ollama_generate(prompt, timeout=180, context="lecture overview")
    if result is not None:
        _ai_cache["full_summary"] = result
        _save_ai_cache()
    return result

# ─── AI pre-generation pass (progress bar) ───────────────────────────────────
# Generate every piece of AI content up front, behind a single live progress
# bar with a rolling-average ETA, instead of letting each output format
# (TXT/PDF/PPTX/CSV) trigger Ollama calls on demand — which used to surface
# as a scrolling wall of "Ollama request timed out ... retrying ..." lines.
# Results are cached (_ai_cache / _AI_CACHE_PATH), so the save_*() functions
# below just read from cache and don't re-trigger any Ollama calls.
if AI_ENABLED:
    # "lecture overview" carries by far the largest prompt (up to 12,000
    # chars of transcript) and is therefore the slowest single call on a
    # small local model — often a minute or more. It used to be scheduled
    # FIRST, which meant the bar sat at 0/N with no visible progress for
    # that entire stretch and looked identical to a genuine hang. It's
    # scheduled LAST instead, so the quick per-slide items complete first,
    # visibly moving the bar and confirming Ollama is actually responding
    # before the one slow call is attempted.
    _ai_jobs = []
    for _i in range(num_slides):
        _ai_jobs.append((f"slide {_i+1} — slide takeaway",  (lambda _i=_i: get_ai_slide_takeaway(_i))))
        _ai_jobs.append((f"slide {_i+1} — spoken takeaway", (lambda _i=_i: get_ai_spoken_takeaway(_i))))

    # PPTX output uses its own deck-slide-indexed takeaways (srcslide_*),
    # built from segments mapped onto each *original* pptx slide rather than
    # video segments — same mapping save_pptx() uses. Pre-generate those too
    # when PPTX output was requested, so save_pptx() also just reads cache.
    if fmt_choice in ("3", "4") and not USE_SCREENGRABS_ONLY and slides_type == "pptx":
        _pptx_slide_to_segments = {}
        for _seg_i in range(num_slides):
            if is_screengrab_fallback(_seg_i):
                continue
            _src_idx = _seg_i
            if alignment and _seg_i < len(alignment) and alignment[_seg_i]["source_slide_index"] is not None:
                _src_idx = alignment[_seg_i]["source_slide_index"]
            _pptx_slide_to_segments.setdefault(_src_idx, []).append(_seg_i)

        def _pptx_slide_job(_i):
            _seg_indices = _pptx_slide_to_segments.get(_i, [])
            _spoken_plain = "\n".join(
                get_transcript_for_slide(_si, with_timestamps=False) for _si in _seg_indices
                if get_transcript_for_slide(_si, with_timestamps=False) not in ("", "(no speech detected)")
            )
            _get_ai_slide_takeaway_direct(
                f"srcslide_{_i}_slide_only", slide_texts[_i] if _i < len(slide_texts) else "",
                label=f"deck slide {_i+1}")
            _get_ai_spoken_takeaway_direct(
                f"srcslide_{_i}_spoken", slide_texts[_i] if _i < len(slide_texts) else "",
                _spoken_plain, label=f"deck slide {_i+1}")

        for _i in range(len(slide_texts)):
            _ai_jobs.append((f"deck slide {_i+1} — PPTX takeaway", (lambda _i=_i: _pptx_slide_job(_i))))

    # Lecture overview last — see ordering note above.
    _ai_jobs.append(("lecture overview", get_ai_lecture_summary))

    print(f"\n  Pre-generating AI content for {num_slides} slide(s) "
          f"(model: {OLLAMA_MODEL})...", flush=True)

    # Quick pre-flight ping before committing to the (potentially long)
    # pre-generation pass. The alignment step earlier may have run several
    # minutes of Ollama calls already; if the server crashed, hung, or was
    # killed in the meantime, the very first pre-gen call would otherwise
    # block for the FULL per-call timeout (up to 180s for the lecture
    # overview) with zero feedback, which is indistinguishable from a
    # genuine freeze. Checking /api/tags first (2s timeout) fails fast
    # instead, with a clear diagnosis.
    _ollama_still_up = False
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2) as _r:
            _ollama_still_up = (_r.status == 200)
    except Exception as _e:
        print(f"  ⚠ Ollama server did not respond to a quick health check ({_e}).", flush=True)

    if not _ollama_still_up:
        print("  ⚠ Ollama appears to be down or unresponsive — skipping AI pre-generation.\n"
              "    Common causes: the server crashed or was killed partway through the run\n"
              "    (check /tmp/ollama_serve.log), the machine ran low on memory (a 3B model\n"
              "    plus Whisper plus OpenCV alignment can add up on 8GB RAM — check Activity\n"
              "    Monitor for swapping), or the process was manually stopped. You can verify\n"
              "    directly with 'ollama ps' and 'curl http://localhost:11434/api/tags' in\n"
              "    another terminal. Re-running the script will pick up right where the AI\n"
              "    cache left off — nothing already generated is lost.", flush=True)
        AI_ENABLED = False

if AI_ENABLED:
    _pb = ProgressBar(len(_ai_jobs), label="AI content")
    _AI_PROGRESS_BAR[0] = _pb
    _pb.start_render()
    try:
        for _label, _fn in _ai_jobs:
            _pb.set_status(_label)
            _t0 = time.time()
            try:
                _fn()
            except Exception:
                pass
            _pb.item_done(time.time() - _t0)
    finally:
        _AI_PROGRESS_BAR[0] = None
        _pb.finish()

    if _OLLAMA_FAILURE_COUNT[0]:
        print(f"  ⚠ {_OLLAMA_FAILURE_COUNT[0]} item(s) failed/timed out during AI pre-generation "
              f"and were skipped (see summary at the end of this run).", flush=True)

# ─── Step 7: Generate outputs ────────────────────────────────────────────────

BORDER = "═" * 54

def build_toc():
    toc = []
    for i in range(num_slides):
        text       = get_slide_text_for_index(i)
        first_line = text.split("\n")[0].strip()[:80] if text else "(no text)"
        toc.append((i + 1, first_line, fmt_ts(slide_times[i])))
    return toc

# ── TXT output ────────────────────────────────────────────────────────────────
def save_txt():
    out   = os.path.join(output_dir, filename + "_merged.txt")
    lines = []

    # Table of Contents
    lines += [
        "╔══════════════════════════════════════════════╗",
        "║            TABLE OF CONTENTS                 ║",
        "╚══════════════════════════════════════════════╝",
        ""
    ]
    for num, title, ts in build_toc():
        lines.append(f"  Slide {num:>3}  [{ts}]  {title}")
    lines += ["", "─" * 60, ""]

    if AI_ENABLED:
        _lec_summary = get_ai_lecture_summary()
        if _lec_summary:
            lines += [
                "╔══════════════════════════════════════════════╗",
                "║          🤖 AI LECTURE OVERVIEW               ║",
                "╚══════════════════════════════════════════════╝",
                ""
            ]
            lines += _lec_summary.split("\n")
            lines += ["", "─" * 60, ""]

    for i in range(num_slides):
        ts_str = fmt_ts(slide_times[i])
        # Row 1 — Slide heading with full-width border
        lines += [
            BORDER,
            f"  Slide {i+1}  [{ts_str}]",
            BORDER,
            ""
        ]

        # Row 2 — Slide image
        slide_img = get_source_slide(i)
        if USE_SCREENGRABS_ONLY:
            _img_label = "🖼 SCREENGRAB"
        elif is_screengrab_fallback(i):
            _img_label = "🖼 SCREENGRAB  (not found in slide file — showing video frame instead)"
        else:
            _img_label = "📑 SLIDE IMAGE"
        lines.append(_img_label)
        if slide_img:
            lines.append(f"  {slide_img}")
        else:
            lines.append("  (no slide image available)")
        lines.append("")

        # Row 3 — Slide text content
        if USE_SCREENGRABS_ONLY:
            _content_label = "📋 SLIDE CONTENT  (screen-grabs only — no source text)"
        elif is_screengrab_fallback(i):
            _content_label = "📋 SLIDE CONTENT  (OCR'd from video frame — not in slide file)"
        else:
            _content_label = "📋 SLIDE CONTENT"
        lines.append(_content_label)
        slide_content = get_slide_text_for_index(i)
        if slide_content.strip():
            for content_line in slide_content.split("\n"):
                lines.append(f"  {content_line}")
        else:
            lines.append("  (no text on slide)")
        lines.append("")

        # Row 4 — Spoken (verbatim)
        lines.append("🗣 SPOKEN (VERBATIM)")
        transcript = get_transcript_for_slide(i, with_timestamps=True)
        for spoken_line in transcript.split("\n"):
            lines.append(f"  {spoken_line}")
        lines.append("")

        # Row 5 — AI key takeaways (only when AI enhancements are enabled)
        if AI_ENABLED:
            _slide_sum = get_ai_slide_takeaway(i)
            if _slide_sum:
                lines.append("🤖 AI TAKEAWAY (Slide)")
                for ai_line in _slide_sum.split("\n"):
                    lines.append(f"  {ai_line}")
                lines.append("")

            _spoken_sum = get_ai_spoken_takeaway(i)
            if _spoken_sum:
                lines.append("🤖 AI TAKEAWAY (Spoken)")
                for ai_line in _spoken_sum.split("\n"):
                    lines.append(f"  {ai_line}")
                lines.append("")

        lines.append("")

    # ── Full verbatim transcript (entire lecture, no segment filtering) ────────
    FULL_BORDER = "═" * 54
    lines += [
        "",
        FULL_BORDER,
        "  📝 FULL VERBATIM TRANSCRIPT",
        FULL_BORDER,
        "",
    ]
    for line in get_full_transcript(with_timestamps=True).split("\n"):
        lines.append(f"  {line}")
    lines.append("")

    with open(out, "w") as f:
        f.write("\n".join(lines))
    print(f"  TXT saved: {out}", flush=True)

# ── PDF output ────────────────────────────────────────────────────────────────
def _pdf_escape(text):
    """Escape text for safe use inside a reportlab Paragraph().

    Paragraph() parses its input as a small XML-like markup language (it's
    how the deliberate <font>/<b> tags used for headings in this file work).
    Any dynamic text — transcript lines, OCR'd slide text, or Ollama-
    generated takeaways — can contain a raw '<', '>', or '&' (a spoken
    "x < y", stray HTML-ish text, an AI model emitting something like
    "<think>", etc). Left unescaped, reportlab treats that as a real tag and
    throws "paraparser: syntax error: ... unclosed tags", which aborts PDF
    generation entirely. Escaping every piece of dynamic text before it goes
    into Paragraph() avoids that — only the hand-written heading markup
    below is left unescaped, since those tags are intentional.
    """
    from xml.sax.saxutils import escape as _xml_escape
    return _xml_escape(text or "")

def save_pdf():
    out = os.path.join(output_dir, filename + "_merged.pdf")
    doc = SimpleDocTemplate(out, pagesize=A4,
                            leftMargin=0.75*inch, rightMargin=0.75*inch,
                            topMargin=0.75*inch, bottomMargin=0.75*inch)

    h_sty = ParagraphStyle("H",  fontSize=13, leading=16,
                            textColor=colors.HexColor("#1a1a2e"),
                            spaceAfter=4, fontName="Helvetica-Bold")
    lbl_sty = ParagraphStyle("LBL", fontSize=10, fontName="Helvetica-Bold",
                              textColor=colors.HexColor("#1a1a2e"), spaceAfter=4)
    b_sty = ParagraphStyle("B",  fontSize=10, leading=14,
                            textColor=colors.HexColor("#333333"),
                            spaceAfter=4, fontName="Helvetica")
    sp_lbl_sty = ParagraphStyle("SL", fontSize=10, fontName="Helvetica-Bold",
                                  textColor=colors.HexColor("#1a6b3c"), spaceAfter=4)
    s_sty = ParagraphStyle("S",  fontSize=9,  leading=13,
                            textColor=colors.HexColor("#1a6b3c"),
                            spaceAfter=3, fontName="Helvetica-Oblique")
    toc_h_sty = ParagraphStyle("TOCH", fontSize=15, fontName="Helvetica-Bold",
                                textColor=colors.HexColor("#1a1a2e"), spaceAfter=10)
    toc_sty   = ParagraphStyle("TOC",  fontSize=10, fontName="Helvetica",
                                textColor=colors.HexColor("#333333"), spaceAfter=4,
                                leftIndent=20)
    ai_lbl_sty = ParagraphStyle("AILBL", fontSize=10, fontName="Helvetica-Bold",
                                 textColor=colors.HexColor("#7a3ea1"), spaceAfter=4)
    ai_sty     = ParagraphStyle("AI",  fontSize=9.5, leading=13,
                                 textColor=colors.HexColor("#4a2564"),
                                 spaceAfter=3, fontName="Helvetica-Oblique")

    story  = []
    page_w = A4[0] - 1.5 * inch

    # Table of Contents
    story.append(Paragraph("Table of Contents", toc_h_sty))
    story.append(HRFlowable(width="100%", thickness=1,
                             color=colors.HexColor("#1a1a2e"), spaceAfter=6))
    for num, title, ts in build_toc():
        story.append(Paragraph(
            f"<b>Slide {num}</b>&nbsp;&nbsp;[{ts}]&nbsp;&nbsp;— {_pdf_escape(title)}", toc_sty))
    story.append(Spacer(1, 20))
    story.append(HRFlowable(width="100%", thickness=2,
                             color=colors.HexColor("#1a1a2e"), spaceAfter=20))

    if AI_ENABLED:
        _lec_summary = get_ai_lecture_summary()
        if _lec_summary:
            story.append(Paragraph("🤖 AI Lecture Overview", toc_h_sty))
            story.append(HRFlowable(width="100%", thickness=1,
                                     color=colors.HexColor("#7a3ea1"), spaceAfter=8))
            for _line in _lec_summary.split("\n"):
                if _line.strip():
                    story.append(Paragraph(_pdf_escape(_line.strip()), ai_sty))
            story.append(Spacer(1, 20))
            story.append(HRFlowable(width="100%", thickness=2,
                                     color=colors.HexColor("#1a1a2e"), spaceAfter=20))

    for i in range(num_slides):
        ts_str = fmt_ts(slide_times[i])

        # Row 1 — Bold heading paragraph
        story.append(Paragraph(
            f"Slide {i+1}&nbsp;&nbsp;<font color='#888888' size='10'>[{ts_str}]</font>",
            h_sty))

        # Row 2 — Embedded full-width source slide image
        if USE_SCREENGRABS_ONLY:
            _img_label = "🖼 Screengrab"
        elif is_screengrab_fallback(i):
            _img_label = "🖼 Screengrab (not found in slide file — showing video frame instead)"
        else:
            _img_label = "📑 Source Slide"
        story.append(Paragraph(_img_label, lbl_sty))
        slide_img = get_source_slide(i)
        if slide_img:
            story.append(RLImage(slide_img, width=page_w, height=page_w * 0.56))
            story.append(Spacer(1, 6))

        # Row 3 — Slide text content (omitted in screen-grabs only mode)
        if not USE_SCREENGRABS_ONLY:
            _text_label = "📋 Slide Text (OCR'd from video frame — not in slide file):" \
                if is_screengrab_fallback(i) else "📋 Slide Text:"
            story.append(Paragraph(_text_label, lbl_sty))
            slide_content = get_slide_text_for_index(i)
            if slide_content.strip():
                for content_line in slide_content.split("\n"):
                    if content_line.strip():
                        story.append(Paragraph(_pdf_escape(content_line.strip()), b_sty))
            else:
                story.append(Paragraph("(no text on slide)", b_sty))
            story.append(Spacer(1, 6))

        # Row 4 — Spoken transcript
        story.append(Paragraph("🗣 Spoken:", sp_lbl_sty))
        transcript = get_transcript_for_slide(i, with_timestamps=True)
        for spoken_line in transcript.split("\n"):
            if spoken_line.strip():
                story.append(Paragraph(_pdf_escape(spoken_line.strip()), s_sty))

        # Row 5 — AI key takeaways (only when AI enhancements are enabled)
        if AI_ENABLED:
            _slide_sum = get_ai_slide_takeaway(i)
            if _slide_sum:
                story.append(Spacer(1, 6))
                story.append(Paragraph("🤖 AI Takeaway (Slide):", ai_lbl_sty))
                for _ai_line in _slide_sum.split("\n"):
                    if _ai_line.strip():
                        story.append(Paragraph(_pdf_escape(_ai_line.strip()), ai_sty))

            _spoken_sum = get_ai_spoken_takeaway(i)
            if _spoken_sum:
                story.append(Spacer(1, 6))
                story.append(Paragraph("🤖 AI Takeaway (Spoken):", ai_lbl_sty))
                for _ai_line in _spoken_sum.split("\n"):
                    if _ai_line.strip():
                        story.append(Paragraph(_pdf_escape(_ai_line.strip()), ai_sty))

        story.append(Spacer(1, 14))
        story.append(HRFlowable(width="100%", thickness=0.5,
                                 color=colors.HexColor("#cccccc"), spaceAfter=10))

    # ── Full verbatim transcript (entire lecture, no segment filtering) ────────
    from reportlab.platypus import PageBreak
    story.append(PageBreak())
    full_h_sty = ParagraphStyle("FH", fontSize=15, fontName="Helvetica-Bold",
                                 textColor=colors.HexColor("#1a1a2e"), spaceAfter=10)
    full_s_sty = ParagraphStyle("FS", fontSize=9, leading=13,
                                 textColor=colors.HexColor("#1a6b3c"),
                                 spaceAfter=3, fontName="Helvetica-Oblique")
    story.append(Paragraph("📝 Full Verbatim Transcript", full_h_sty))
    story.append(HRFlowable(width="100%", thickness=1,
                             color=colors.HexColor("#1a1a2e"), spaceAfter=8))
    for line in get_full_transcript(with_timestamps=True).split("\n"):
        if line.strip():
            story.append(Paragraph(_pdf_escape(line.strip()), full_s_sty))

    doc.build(story)
    print(f"  PDF saved: {out}", flush=True)

# ── PPTX output ───────────────────────────────────────────────────────────────
def save_pptx():
    if USE_SCREENGRABS_ONLY:
        print("  ⚠ PPTX output is not available in screen-grabs only mode. Skipping.", flush=True)
        return
    if slides_type != "pptx":
        print("  ⚠ PPTX output requires a .pptx source file. Skipping PPTX output.", flush=True)
        return

    out = os.path.join(output_dir, filename + "_merged.pptx")
    # Open the original source PPTX — all existing shapes are preserved
    prs     = Presentation(slides_file)
    slide_w = prs.slide_width
    slide_h = prs.slide_height

    # Map each ORIGINAL pptx slide to the video segment(s) alignment actually
    # assigned to it. Previously this loop assumed slide i in the deck always
    # corresponds to video segment i and called get_transcript_for_slide(i,
    # ...) directly — which silently ignored alignment entirely. Whenever the
    # video visited a different number of distinct states than the deck has
    # slides (skips, near-duplicate slides collapsing, revisits), that mapping
    # was simply wrong: transcript from segment i could land on an unrelated
    # deck slide i. This mirrors the mapping get_source_slide/
    # get_slide_text_for_index already use for the TXT/PDF outputs, so all
    # three output formats now agree on which video segment(s) go with which
    # deck slide. A deck slide can legitimately map to more than one segment
    # (a slide the lecturer returned to later) — those are concatenated in
    # chronological order rather than only keeping one.
    _slide_to_segments = {}
    _fallback_segments = []
    for seg_i in range(num_slides):
        if is_screengrab_fallback(seg_i):
            _fallback_segments.append(seg_i)
            continue
        src_idx = seg_i
        if alignment and seg_i < len(alignment) and alignment[seg_i]["source_slide_index"] is not None:
            src_idx = alignment[seg_i]["source_slide_index"]
        _slide_to_segments.setdefault(src_idx, []).append(seg_i)

    for i, slide in enumerate(prs.slides):
        if i >= len(slide_texts):
            break

        seg_indices = _slide_to_segments.get(i, [])
        if not seg_indices:
            spoken = "(no speech detected)"
        else:
            _chunks = [get_transcript_for_slide(si, with_timestamps=True) for si in seg_indices]
            _chunks = [c for c in _chunks if c and c != "(no speech detected)"]
            spoken = "\n".join(_chunks) if _chunks else "(no speech detected)"

        # Add transcript text box at the very bottom (never covers existing content)
        box_left = Inches(0.3)
        box_h    = Inches(1.6)
        box_top  = slide_h - Inches(1.7)
        box_w    = slide_w - Inches(0.6)

        txBox        = slide.shapes.add_textbox(box_left, box_top, box_w, box_h)
        tf           = txBox.text_frame
        tf.word_wrap = True

        # Apply solid white background with 85% transparency via XML
        try:
            sp_tree = slide.shapes._spTree
            sp_el   = txBox._element
            spPr    = sp_el.find(qn("p:spPr"))
            if spPr is None:
                spPr = etree.SubElement(sp_el, qn("p:spPr"))
            solidFill = etree.SubElement(spPr, qn("a:solidFill"))
            srgbClr   = etree.SubElement(solidFill, qn("a:srgbClr"))
            srgbClr.set("val", "FFFFFF")
            alpha_el  = etree.SubElement(srgbClr, qn("a:alpha"))
            # OpenXML alpha is expressed in thousandths of a percent (100 000 = fully opaque).
            # 85% transparency = 15% opacity = 15 000 / 100 000.
            BOX_TRANSPARENCY_ALPHA = "15000"
            alpha_el.set("val", BOX_TRANSPARENCY_ALPHA)
        except Exception:
            pass  # background fill is cosmetic; continue without it

        # Row 1 inside the text box: "🗣 Spoken:" label
        lbl           = tf.paragraphs[0]
        lbl.text      = "🗣 Spoken:"
        lbl.font.bold = True
        lbl.font.size = Pt(9)
        lbl.font.color.rgb = RGBColor(26, 107, 60)

        # Subsequent paragraphs: one per transcript segment
        for spoken_line in spoken.split("\n"):
            spoken_line = spoken_line.strip()
            if not spoken_line:
                continue
            body                = tf.add_paragraph()
            body.text           = spoken_line
            body.font.size      = Pt(7.5)
            body.font.color.rgb = RGBColor(51, 51, 51)

        # AI key takeaways (only when AI enhancements are enabled). Addressed
        # by deck slide index i directly (not a video segment index) using
        # the shared _direct generators — see the mapping comment above.
        if AI_ENABLED:
            _spoken_plain = "\n".join(
                get_transcript_for_slide(si, with_timestamps=False) for si in seg_indices
                if get_transcript_for_slide(si, with_timestamps=False) not in ("", "(no speech detected)")
            )
            _slide_sum = _get_ai_slide_takeaway_direct(
                f"srcslide_{i}_slide_only", slide_texts[i] if i < len(slide_texts) else "",
                label=f"deck slide {i+1}")
            if _slide_sum:
                ai_lbl           = tf.add_paragraph()
                ai_lbl.text      = "🤖 AI Takeaway (Slide):"
                ai_lbl.font.bold = True
                ai_lbl.font.size = Pt(9)
                ai_lbl.font.color.rgb = RGBColor(122, 62, 161)
                for ai_line in _slide_sum.split("\n"):
                    ai_line = ai_line.strip()
                    if not ai_line:
                        continue
                    ai_body                = tf.add_paragraph()
                    ai_body.text           = ai_line
                    ai_body.font.size      = Pt(7.5)
                    ai_body.font.italic    = True
                    ai_body.font.color.rgb = RGBColor(74, 37, 100)

            _spoken_sum = _get_ai_spoken_takeaway_direct(
                f"srcslide_{i}_spoken", slide_texts[i] if i < len(slide_texts) else "",
                _spoken_plain, label=f"deck slide {i+1}")
            if _spoken_sum:
                ai_lbl2           = tf.add_paragraph()
                ai_lbl2.text      = "🤖 AI Takeaway (Spoken):"
                ai_lbl2.font.bold = True
                ai_lbl2.font.size = Pt(9)
                ai_lbl2.font.color.rgb = RGBColor(122, 62, 161)
                for ai_line in _spoken_sum.split("\n"):
                    ai_line = ai_line.strip()
                    if not ai_line:
                        continue
                    ai_body2                = tf.add_paragraph()
                    ai_body2.text           = ai_line
                    ai_body2.font.size      = Pt(7.5)
                    ai_body2.font.italic    = True
                    ai_body2.font.color.rgb = RGBColor(74, 37, 100)

    prs.save(out)
    print(f"  PPTX saved: {out}", flush=True)

    # ── Full verbatim transcript appended as extra slide(s) ──────────────────
    # Re-open to add the full transcript slide(s), then save again.
    prs2 = Presentation(out)
    slide_w2 = prs2.slide_width
    slide_h2 = prs2.slide_height
    BLANK_LAYOUT = 6  # "Blank" layout index (standard Office theme)

    # ── Screengrab-fallback slides ────────────────────────────────────────────
    # Segments flagged during alignment as having no genuine match anywhere in
    # the deck (see apply_screengrab_fallback / ollama_verify_alignment) can't
    # be safely overlaid onto any existing pptx slide — there isn't one that
    # actually corresponds to what's on screen. Rather than silently dropping
    # that content, each one gets its own new slide here: the actual video
    # frame, what was said, and (if available) an AI takeaway. These can't be
    # inserted at their correct position in the deck without rebuilding the
    # slide order from scratch, so they're appended here, each clearly labeled
    # with its original timestamp so it's easy to see where it belongs.
    if _fallback_segments:
        print(f"  Adding {len(_fallback_segments)} screengrab-fallback slide(s) "
              f"(content not found in the original slide file)...", flush=True)
    for seg_i in _fallback_segments:
        layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
        fb_slide = prs2.slides.add_slide(layout)
        for ph in list(fb_slide.placeholders):
            sp_el = ph._element
            sp_el.getparent().remove(sp_el)

        title_box = fb_slide.shapes.add_textbox(Inches(0.3), Inches(0.2),
                                                  slide_w2 - Inches(0.6), Inches(0.5))
        title_lbl = title_box.text_frame.paragraphs[0]
        title_lbl.text = (f"🖼 Screengrab — {fmt_ts(slide_times[seg_i])}  "
                           f"(not found in original slide file)")
        title_lbl.font.bold = True
        title_lbl.font.size = Pt(13)
        title_lbl.font.color.rgb = RGBColor(26, 26, 46)

        _fb_img = screengrab_imgs[seg_i] if seg_i < len(screengrab_imgs) else None
        _img_top = Inches(0.8)
        if _fb_img and os.path.exists(_fb_img):
            _img_w = slide_w2 - Inches(0.6)
            _img_h = int(_img_w * 9 // 16)  # keep EMU values as ints; python-pptx rejects floats
            fb_slide.shapes.add_picture(_fb_img, Inches(0.3), _img_top, width=_img_w, height=_img_h)
            _text_top = int(_img_top + _img_h + Inches(0.15))
        else:
            _text_top = int(_img_top)

        body_box = fb_slide.shapes.add_textbox(Inches(0.3), _text_top,
                                                 slide_w2 - Inches(0.6),
                                                 slide_h2 - _text_top - Inches(0.2))
        tf_fb = body_box.text_frame
        tf_fb.word_wrap = True
        fb_lbl           = tf_fb.paragraphs[0]
        fb_lbl.text      = "🗣 Spoken:"
        fb_lbl.font.bold = True
        fb_lbl.font.size = Pt(9)
        fb_lbl.font.color.rgb = RGBColor(26, 107, 60)
        _fb_spoken = get_transcript_for_slide(seg_i, with_timestamps=True)
        for _line in _fb_spoken.split("\n"):
            _line = _line.strip()
            if not _line:
                continue
            _p = tf_fb.add_paragraph()
            _p.text = _line
            _p.font.size = Pt(8)
            _p.font.color.rgb = RGBColor(51, 51, 51)

        if AI_ENABLED:
            _fb_takeaway = get_ai_spoken_takeaway(seg_i)
            if _fb_takeaway:
                _ai_lbl           = tf_fb.add_paragraph()
                _ai_lbl.text      = "🤖 AI Takeaway:"
                _ai_lbl.font.bold = True
                _ai_lbl.font.size = Pt(9)
                _ai_lbl.font.color.rgb = RGBColor(122, 62, 161)
                for _line in _fb_takeaway.split("\n"):
                    _line = _line.strip()
                    if not _line:
                        continue
                    _ai_p = tf_fb.add_paragraph()
                    _ai_p.text = _line
                    _ai_p.font.size = Pt(8)
                    _ai_p.font.italic = True
                    _ai_p.font.color.rgb = RGBColor(74, 37, 100)

    full_lines = [
        ln for ln in get_full_transcript(with_timestamps=True).split("\n") if ln.strip()
    ]
    LINES_PER_SLIDE = 30  # keep each extra slide readable

    for chunk_start in range(0, max(len(full_lines), 1), LINES_PER_SLIDE):
        chunk = full_lines[chunk_start:chunk_start + LINES_PER_SLIDE]
        layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
        new_slide = prs2.slides.add_slide(layout)

        # Remove any placeholder shapes from the blank layout
        for ph in list(new_slide.placeholders):
            sp_el = ph._element
            sp_el.getparent().remove(sp_el)

        # Title box
        title_box = new_slide.shapes.add_textbox(Inches(0.3), Inches(0.2),
                                                  slide_w2 - Inches(0.6), Inches(0.55))
        tf_title = title_box.text_frame
        chunk_idx = chunk_start // LINES_PER_SLIDE + 1
        total_chunks = (len(full_lines) - 1) // LINES_PER_SLIDE + 1 if full_lines else 1
        title_lbl = tf_title.paragraphs[0]
        title_lbl.text = (
            "📝 Full Verbatim Transcript"
            if total_chunks == 1
            else f"📝 Full Verbatim Transcript  ({chunk_idx}/{total_chunks})"
        )
        title_lbl.font.bold = True
        title_lbl.font.size = Pt(14)
        title_lbl.font.color.rgb = RGBColor(26, 26, 46)

        # Body box
        body_box = new_slide.shapes.add_textbox(Inches(0.3), Inches(0.9),
                                                 slide_w2 - Inches(0.6),
                                                 slide_h2 - Inches(1.1))
        tf_body = body_box.text_frame
        tf_body.word_wrap = True
        first = True
        for line in (chunk if chunk else ["(no speech detected)"]):
            para = tf_body.paragraphs[0] if first else tf_body.add_paragraph()
            first = False
            para.text = line.strip()
            para.font.size = Pt(7.5)
            para.font.color.rgb = RGBColor(26, 107, 60)

    # ── AI lecture overview slide (only when AI enhancements are enabled) ────
    if AI_ENABLED:
        _lec_summary = get_ai_lecture_summary()
        if _lec_summary:
            layout = prs2.slide_layouts[min(BLANK_LAYOUT, len(prs2.slide_layouts) - 1)]
            ai_slide = prs2.slides.add_slide(layout)
            for ph in list(ai_slide.placeholders):
                sp_el = ph._element
                sp_el.getparent().remove(sp_el)

            title_box = ai_slide.shapes.add_textbox(Inches(0.3), Inches(0.2),
                                                      slide_w2 - Inches(0.6), Inches(0.55))
            title_lbl = title_box.text_frame.paragraphs[0]
            title_lbl.text = "🤖 AI Lecture Overview"
            title_lbl.font.bold = True
            title_lbl.font.size = Pt(14)
            title_lbl.font.color.rgb = RGBColor(26, 26, 46)

            body_box = ai_slide.shapes.add_textbox(Inches(0.3), Inches(0.9),
                                                     slide_w2 - Inches(0.6),
                                                     slide_h2 - Inches(1.1))
            tf_body = body_box.text_frame
            tf_body.word_wrap = True
            first = True
            for line in _lec_summary.split("\n"):
                if not line.strip():
                    continue
                para = tf_body.paragraphs[0] if first else tf_body.add_paragraph()
                first = False
                para.text = line.strip()
                para.font.size = Pt(11)
                para.font.color.rgb = RGBColor(74, 37, 100)

    prs2.save(out)
    print(f"  PPTX full transcript slide(s) appended.", flush=True)

# ── CSV summary ───────────────────────────────────────────────────────────────
def save_csv():
    import csv
    out_csv = os.path.join(output_dir, filename + "_summary.csv")
    fieldnames = ["slide_number", "timestamp", "timestamp_seconds",
                  "slide_text", "transcript", "source_slide_image",
                  "screengrab_fallback", "ai_takeaway_slide", "ai_takeaway_spoken"]
    rows = []
    for i in range(num_slides):
        _ai_takeaway_slide  = (get_ai_slide_takeaway(i) or "").replace("\n", " ").strip() if AI_ENABLED else ""
        _ai_takeaway_spoken = (get_ai_spoken_takeaway(i) or "").replace("\n", " ").strip() if AI_ENABLED else ""
        rows.append({
            "slide_number":      i + 1,
            "timestamp":         fmt_ts(slide_times[i]),
            "timestamp_seconds": round(float(slide_times[i]), 2),
            "slide_text":        (get_slide_text_for_index(i) or "").replace("\n", " ").strip(),
            "transcript":        get_transcript_for_slide(i),
            "source_slide_image": get_source_slide(i) or "",
            "screengrab_fallback": is_screengrab_fallback(i),
            "ai_takeaway_slide":  _ai_takeaway_slide,
            "ai_takeaway_spoken": _ai_takeaway_spoken,
        })
    with open(out_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"  CSV summary saved: {out_csv}", flush=True)

print(f"\n  Generating output(s) for {num_slides} slides...", flush=True)
if fmt_choice in ("1", "4"): save_txt()
if fmt_choice in ("2", "4"): save_pdf()
if fmt_choice in ("3", "4"): save_pptx()
save_csv()
if AI_ENABLED and _OLLAMA_FAILURE_COUNT[0]:
    print(f"  ⚠ {_OLLAMA_FAILURE_COUNT[0]} Ollama request(s) failed/timed out during this run "
          f"and were skipped. Their AI content is left uncached, so simply re-running will "
          f"retry just those — everything else stays cached and won't be re-queried.",
          flush=True)
print("  Done.", flush=True)
PYEOF

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✔ LectureMerge complete!  Output is in: $FOLDER_C${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"