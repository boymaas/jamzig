#!/bin/bash
set -euo pipefail

# JAM Conformance Release Script
# Creates release packages for conformance testing with both tiny and full parameter sets
# Uses GNU parallel for efficient parallel builds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if parallel is installed
if ! command -v parallel &> /dev/null; then
    echo -e "${RED}Error: GNU parallel is not installed${NC}"
    echo "Please install it with:"
    echo "  Ubuntu/Debian: sudo apt-get install parallel"
    echo "  RHEL/CentOS:   sudo yum install parallel"
    echo "  macOS:         brew install parallel"
    exit 1
fi

# Check if git directory is clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${YELLOW}Warning: Git directory is not clean.${NC}"
    exit 1
fi

# Get git SHA
GIT_SHA=$(git rev-parse --short HEAD)
DATE=$(date +%Y%m%d%H%M) # Format: YYYYMMDDHHMM for better release granularity
RELEASE_NAME="${DATE}_${GIT_SHA}"

# Base directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_REPO_DIR="${PROJECT_ROOT}/../jamzig-conformance-releases"
RELEASE_DIR="${RELEASE_REPO_DIR}/releases/${RELEASE_NAME}"

echo -e "${GREEN}Creating JAM Conformance Release: ${RELEASE_NAME}${NC}"

# Create release directory structure
echo "Creating release directory structure..."
mkdir -p "${RELEASE_DIR}"/{tiny,full}

# Create build output directories
BUILD_DIR="${PROJECT_ROOT}/build-outputs"
mkdir -p "${BUILD_DIR}"

# Define platforms and architectures
PLATFORMS=(
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-macos"
)

# Function to build for a specific platform and param set
build_platform() {
    local target=$1
    local params=$2
    local output_dir=$3
    local build_id="${target//[- ]/_}_${params}"  # Replace spaces and dashes with underscores
    local platform_build_dir="${BUILD_DIR}/${build_id}"
    
    echo -e "${YELLOW}[${build_id}] Building for ${target} with ${params} params...${NC}"
    
    cd "${PROJECT_ROOT}"
    
    # Create unique output directory for this build
    mkdir -p "${platform_build_dir}"
    
    # Build conformance fuzzer with unique output directory
    # Use systemd-run to limit memory if available
    if command -v systemd-run &> /dev/null 2>&1; then
        systemd-run --user --scope -p MemoryMax=2G -- \
            zig build conformance_fuzzer \
            -Doptimize=ReleaseFast \
            -Dconformance-params=${params} \
            -Dtarget=${target} \
            --prefix "${platform_build_dir}"
    else
        zig build conformance_fuzzer \
            -Doptimize=ReleaseFast \
            -Dconformance-params=${params} \
            -Dtarget=${target} \
            --prefix "${platform_build_dir}"
    fi
    
    # Build conformance target with unique output directory
    # Use systemd-run to limit memory if available
    if command -v systemd-run &> /dev/null 2>&1; then
        systemd-run --user --scope -p MemoryMax=2G -- \
            zig build conformance_target \
            -Doptimize=ReleaseFast \
            -Dconformance-params=${params} \
            -Dtarget=${target} \
            --prefix "${platform_build_dir}"
    else
        zig build conformance_target \
            -Doptimize=ReleaseFast \
            -Dconformance-params=${params} \
            -Dtarget=${target} \
            --prefix "${platform_build_dir}"
    fi
    
    # Determine OS and arch from target
    local os arch
    case ${target} in
        x86_64-linux)
            os="linux"
            arch="x86_64"
            ;;
        aarch64-linux)
            os="linux"
            arch="aarch64"
            ;;
        aarch64-macos)
            os="macos"
            arch="aarch64"
            ;;
    esac
    
    # Create output directory
    mkdir -p "${output_dir}/${os}/${arch}"
    
    # Copy binaries from the platform-specific build directory
    cp "${platform_build_dir}/bin/jam_conformance_fuzzer" "${output_dir}/${os}/${arch}/"
    cp "${platform_build_dir}/bin/jam_conformance_target" "${output_dir}/${os}/${arch}/"
    
    # Create symlink to run script
    ln -sf ../../run_conformance_test.sh "${output_dir}/${os}/${arch}/run_conformance_test.sh"
    
    echo -e "${GREEN}[${build_id}] Completed build for ${target} with ${params} params${NC}"
}

# Export the function so parallel can use it
export -f build_platform
export PROJECT_ROOT BUILD_DIR RELEASE_DIR RED GREEN YELLOW NC

# Create all build job combinations
build_jobs=()
for platform in "${PLATFORMS[@]}"; do
    build_jobs+=("${platform} tiny ${RELEASE_DIR}/tiny")
    build_jobs+=("${platform} full ${RELEASE_DIR}/full")
done

echo "Starting parallel builds for ${#build_jobs[@]} configurations..."

# Run all builds in parallel using GNU parallel
# --will-cite suppresses the citation notice
# --jobs -2 uses all CPUs minus 2 (leaves 2 cores free)
# --nice 19 runs at lowest priority
# --load 80% pauses if system load is above 80%
# --halt soon,fail=1 stops on first failure
# --line-buffer ensures clean output per job
# --colsep ' ' tells parallel to split on spaces
printf '%s\n' "${build_jobs[@]}" | \
    parallel --will-cite --jobs 50% --delay 0.5 --nice 19 --load 80% --memfree 2G --halt soon,fail=1 --line-buffer --colsep ' ' \
    build_platform {1} {2} {3}

if [ $? -ne 0 ]; then
    echo -e "${RED}One or more builds failed. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}All parallel builds completed successfully!${NC}"

# Export parameters using the built binaries (build for host platform)
echo "Exporting parameters..."
cd "${PROJECT_ROOT}"

# Determine host platform for parameter export
HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')


case "${HOST_ARCH}" in
    x86_64)
        case "${HOST_OS}" in
            linux) HOST_TARGET="x86_64_linux" ;;
            darwin) HOST_TARGET="x86_64_macos" ;;
            *)
                echo -e "${RED}Error: Unsupported OS '${HOST_OS}' for architecture '${HOST_ARCH}'${NC}"
                exit 1
                ;;
        esac
        ;;
    arm64|aarch64)
        case "${HOST_OS}" in
            linux) HOST_TARGET="aarch64_linux" ;;
            darwin) HOST_TARGET="aarch64_macos" ;;
            *)
                echo -e "${RED}Error: Unsupported OS '${HOST_OS}' for architecture '${HOST_ARCH}'${NC}"
                exit 1
                ;;
        esac
        ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '${HOST_ARCH}'${NC}"
        exit 1
        ;;
esac

echo "Using host target: ${HOST_TARGET}"

# Use the already built binaries for parameter export
TINY_BUILD_DIR="${BUILD_DIR}/${HOST_TARGET}_tiny"
FULL_BUILD_DIR="${BUILD_DIR}/${HOST_TARGET}_full"

# Export tiny params
if [ -f "${TINY_BUILD_DIR}/bin/jam_conformance_target" ]; then
    "${TINY_BUILD_DIR}/bin/jam_conformance_target" --dump-params --format json > "${RELEASE_DIR}/tiny/params.json"
else
    echo -e "${RED}Error: Could not find tiny params binary for host platform${NC}"
    exit 1
fi

# Export full params
if [ -f "${FULL_BUILD_DIR}/bin/jam_conformance_target" ]; then
    "${FULL_BUILD_DIR}/bin/jam_conformance_target" --dump-params --format json > "${RELEASE_DIR}/full/params.json"
else
    echo -e "${RED}Error: Could not find full params binary for host platform${NC}"
    exit 1
fi

# Copy existing run script
echo "Copying run script..."
cp "${SCRIPT_DIR}/run_conformance_test.sh" "${RELEASE_DIR}/"
chmod +x "${RELEASE_DIR}/run_conformance_test.sh"

# Create symlinks in param directories
ln -sf ../run_conformance_test.sh "${RELEASE_DIR}/tiny/run_conformance_test.sh"
ln -sf ../run_conformance_test.sh "${RELEASE_DIR}/full/run_conformance_test.sh"

# Create release info
echo "Creating release info..."
cat > "${RELEASE_DIR}/RELEASE_INFO.json" <<EOF
{
    "release_name": "${RELEASE_NAME}",
    "date": "${DATE}",
    "git_sha": "${GIT_SHA}",
    "git_branch": "$(git rev-parse --abbrev-ref HEAD)",
    "build_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "build_host": "$(hostname)",
    "build_host_target": "${HOST_TARGET}",
    "zig_version": "$(zig version)",
    "parallel_version": "$(parallel --version | head -n1)",
    "platforms": [
        "linux/x86_64",
        "linux/aarch64",
        "macos/aarch64"
    ],
    "param_sets": ["tiny", "full"],
    "parallel_builds": true,
    "total_configurations": ${#build_jobs[@]}
}
EOF

# Copy and process README
echo "Processing README..."
sed -e "s/\${RELEASE_NAME}/${RELEASE_NAME}/g" \
    -e "s/\${GIT_SHA}/${GIT_SHA}/g" \
    -e "s/\${BUILD_DATE}/$(date -u +%Y-%m-%dT%H:%M:%SZ)/g" \
    "${SCRIPT_DIR}/release_conformance/README.md" > "${RELEASE_DIR}/README.md"

# Create latest symlink
echo "Creating latest symlink..."
cd "${RELEASE_REPO_DIR}/releases"
ln -sfn "${RELEASE_NAME}" latest

# Clean up build directories (optional)
echo "Cleaning up temporary build directories..."
rm -rf "${BUILD_DIR}"

echo -e "${GREEN}Release created successfully at: ${RELEASE_DIR}${NC}"
echo ""
echo "Next steps:"
echo "1. cd ${RELEASE_REPO_DIR}"
echo "2. git add releases/${RELEASE_NAME}"
echo "3. git commit -m \"Add conformance release ${RELEASE_NAME}\""
echo "4. git push origin main"
echo ""
echo -e "${GREEN}Built ${#PLATFORMS[@]} platforms × 2 param sets = ${#build_jobs[@]} total configurations using GNU parallel${NC}"
