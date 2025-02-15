#!/bin/bash

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE}" )" && pwd )"
SOURCE_DIR="${SCRIPT_DIR}/src"  # Source files are in./src
BUILD_DIR="${SCRIPT_DIR}/build"
VENV_DIR="${BUILD_DIR}/.venv"   # Keep venv in a hidden directory
REQUIREMENTS_FILE="${SOURCE_DIR}/requirements.txt"
PACKAGE_NAME="workmail-lambda"

# Enhanced logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if S3 bucket exists
check_s3_bucket_exists() {
    local bucket_name=$1
    if aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get S3 bucket name
get_s3_bucket_name() {
    local bucket_name
    local account_id
    
    account_id=$(aws sts get-caller-identity --query Account --output text)
    if [ $? -ne 0 ]; then
        log "Error: Could not get AWS account ID" >&2
        return 1
    fi
    
    bucket_name="[sanitized]-api-${account_id}"
    
    # Check if bucket exists - silently redirect any JSON output
    if aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
        log "S3 bucket found: ${bucket_name}" >&2
        echo "${bucket_name}"
        return 0
    fi
    
    # If bucket doesn't exist, check if we're in deployment mode
    if [ "$SKIP_UPLOAD" = false ]; then
        log "S3 bucket ${bucket_name} does not exist. Will be created during deployment." >&2
        echo "${bucket_name}"
        return 0
    else
        log "Error: S3 bucket ${bucket_name} does not exist" >&2
        return 1
    fi
}

# Function to check/create virtual environment
setup_virtual_env() {
    log "Setting up virtual environment..."
    # Create venv only if it doesn't exist
    if [! -d "$VENV_DIR" ]; then
        log "Creating new virtual environment at: $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    else
        log "Using existing virtual environment at: $VENV_DIR"
    fi
    
    # Show Python version before activation
    log "System Python version:"
    python3 --version
    
    source "${VENV_DIR}/bin/activate"
    
    # Show Python version after activation
    log "Virtual env Python version:"
    python3 --version
    
    # Always update pip
    log "Upgrading pip..."
    python3 -m pip install --upgrade pip
}

# Function for smart cleanup
cleanup() {
    log "Starting cleanup process..."
    deactivate 2>/dev/null || true
    
    # Remove Python packages but keep the venv
    if [ -d "${BUILD_DIR}/python" ]; then
        log "Cleaning up Python packages in: ${BUILD_DIR}/python"
        rm -rf "${BUILD_DIR}/python"
    fi
    
    # Remove copied source files but keep the directory structure
    log "Cleaning up source files in build directory..."
    rm -f "${BUILD_DIR}"/*.py
    
    # Keep the build directory and venv for future builds
    log "Build environment preserved for future builds"
}

# --- AWS Configuration ---
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-my-region}"

# --- Display help message ---
display_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Package WorkMail Lambda function for deployment"
    echo ""
    echo "Options:"
    echo "  --help        Display this help message"
    echo "  --clean       Clean build directory before packaging"
    echo "  --region      AWS region (default: my-region)"
    echo "  --no-upload   Skip S3 upload"
    echo "  --list-env    List information about virtual environment"
    echo "  --verbose     Enable verbose output"
    echo ""
    echo "Note: The S3 bucket will be automatically used or created during deployment"
    echo "      using the format: [sanitized]-api-<account-id>"
}

# --- Parse command line arguments ---
CLEAN=false
SKIP_UPLOAD=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            display_help
            exit 0
          ;;
        --clean)
            CLEAN=true
            shift
          ;;
        --region)
            AWS_DEFAULT_REGION="$2"
            shift 2
          ;;
        --no-upload)
            SKIP_UPLOAD=true
            shift
          ;;
        --verbose)
            VERBOSE=true
            shift
          ;;
        --list-env)
            if [ -d "$BUILD_DIR" ]; then
                log "Build directory: $BUILD_DIR"
                if [ -d "$VENV_DIR" ]; then
                    echo -e "\nVirtual environment:"
                    echo "  Location: $VENV_DIR"
                    echo "  Python version:"
                    "${VENV_DIR}/bin/python" --version
                    echo -e "\n  Installed packages:"
                    "${VENV_DIR}/bin/pip" list
                    echo -e "\n  Venv created on:"
                    stat -f "%Sm" "$VENV_DIR" 2>/dev/null || stat -c "%y" "$VENV_DIR"
                else
                    log "No virtual environment found at: $VENV_DIR"
                fi
                
                echo -e "\nBuild artifacts:"
                if [ -d "${BUILD_DIR}/python" ]; then
                    echo "  Python packages directory exists"
                    echo "  Size: $(du -sh "${BUILD_DIR}/python" | cut -f1)"
                fi
                
                if [ -f "${SCRIPT_DIR}/${PACKAGE_NAME}.zip" ]; then
                    echo "  Lambda package exists:"
                    echo "  Size: $(du -h "${SCRIPT_DIR}/${PACKAGE_NAME}.zip" | cut -f1)"
                    echo "  Modified: $(stat -f "%Sm" "${SCRIPT_DIR}/${PACKAGE_NAME}.zip" 2>/dev/null || stat -c "%y" "${SCRIPT_DIR}/${PACKAGE_NAME}.zip")"
                    echo -e "\nPackage contents:"
                    unzip -l "${SCRIPT_DIR}/${PACKAGE_NAME}.zip" | grep "\.py"
                fi
            else
                log "No build directory found at: $BUILD_DIR"
            fi
            exit 0
          ;;
        *)
            echo "Unknown option: $1"
            display_help
            exit 1
          ;;
    esac
done

# --- Utility functions ---
check_command() {
    if! command -v "$1" &> /dev/null; then
        log "Error: $1 is required but not installed."
        exit 1
    fi
}

# --- Check required commands ---
log "Checking required commands..."
check_command python3
check_command pip
check_command zip
if [ "$SKIP_UPLOAD" = false ]; then
    check_command aws
fi

# --- Verify AWS credentials and get bucket if uploading ---
if [ "$SKIP_UPLOAD" = false ]; then
    log "Verifying AWS credentials..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ $? -ne 0 ]; then
        log "Error: Could not get AWS account ID. Please check your AWS credentials."
        exit 1
    fi
    log "Using AWS Account ID: ${AWS_ACCOUNT_ID}"

    # Get bucket name
    log "Determining S3 bucket name..."
    BUCKET_NAME=$(get_s3_bucket_name)
    if [ $? -ne 0 ] || [ -z "$BUCKET_NAME" ]; then
        log "Error: Failed to determine bucket name"
        exit 1
    fi

    # Note: We don't verify bucket exists here as it will be created during stack deployment if needed
    log "Will use S3 bucket: ${BUCKET_NAME}"
fi

# --- Prepare build environment ---
if [ "$CLEAN" = true ]; then
    log "Performing clean build..."
    rm -rf "$BUILD_DIR"
fi

# Create necessary directories
log "Creating build directory structure..."
mkdir -p "$BUILD_DIR"

# Set up virtual environment
setup_virtual_env

# --- Install dependencies ---
log "Installing dependencies..."
mkdir -p "${BUILD_DIR}/python"
if [ -f "$REQUIREMENTS_FILE" ]; then
    log "Installing from requirements.txt..."
    if [ "$VERBOSE" = true ]; then
        log "Requirements file contents:"
        cat "$REQUIREMENTS_FILE"
    fi
    pip install -r "$REQUIREMENTS_FILE" --target "${BUILD_DIR}/python"
else
    log "No requirements.txt found, skipping dependencies (using Lambda runtime built-ins)..."
    # Lambda runtime already includes:
    # - boto3/botocore
    # - urllib3
    # - dateutil
    # - json
    # - yaml
fi

# --- Set source file permissions ---
log "Setting source file permissions..."
if! chmod 644 "${SOURCE_DIR}"/*.py; then
    log "Error: Failed to set permissions on source files"
    exit 1
fi

# --- Copy source files ---
log "Preparing to copy source files..."
log "Source directory contents:"
ls -la "${SOURCE_DIR}"

if! ls "${SOURCE_DIR}"/*.py >/dev/null 2>&1; then
    log "Error: No Python files found in ${SOURCE_DIR}!"
    cleanup
    exit 1
fi

# Copy all Python files from source
log "Copying Python files to build directory..."
cp -v "${SOURCE_DIR}"/*.py "${BUILD_DIR}/"

# Verify files were copied
log "Verifying copied files..."
if! ls "${BUILD_DIR}"/*.py >/dev/null 2>&1; then
    log "Error: Failed to copy Python files to build directory!"
    cleanup
    exit 1
fi

# List copied files for verification
log "Files in build directory:"
ls -la "${BUILD_DIR}"/*.py

# --- Create ZIP package ---
log "Creating deployment package..."
cd "$BUILD_DIR" || exit

# Remove existing package if it exists
PACKAGE_FILE="${SCRIPT_DIR}/${PACKAGE_NAME}.zip"
if [ -f "$PACKAGE_FILE" ]; then
    log "Removing existing package: $PACKAGE_FILE"
    rm -f "$PACKAGE_FILE"
fi

# Create fresh package
if [ -d "${BUILD_DIR}/python" ]; then
    log "Adding dependencies to package..."
    cd "${BUILD_DIR}/python" || exit
    zip -r9 "$PACKAGE_FILE"./*
    cd "$BUILD_DIR" || exit
fi

log "Adding Lambda function code to package..."
# First verify we have Python files to add
PY_FILES=(*.py)
if [ -e "${PY_FILES}" ]; then
    if [ "$VERBOSE" = true ]; then
        log "Python files to be added:"
        ls -la "${PY_FILES[@]}"
    fi
    zip -g "$PACKAGE_FILE" "${PY_FILES[@]}"
else
    log "Error: No Python files found in build directory!"
    exit 1
fi

# Show package contents if verbose
if [ "$VERBOSE" = true ]; then
    log "Package contents:"
    unzip -l "$PACKAGE_FILE" | grep "\.py"
fi

# --- Upload to S3 if requested ---
if [ "$SKIP_UPLOAD" = false ]; then
    log "Checking S3 bucket status..."
    if! check_s3_bucket_exists "${BUCKET_NAME}"; then
        log "Warning: S3 bucket ${BUCKET_NAME} does not exist yet"
        log "Please deploy the WorkMail stack first using:"
        log "./deploy-v2.sh --deploy --[sanitized]-workmail-v2"
        exit 1
    fi

    log "Uploading to S3..."
    for i in {1..3}; do
        if aws s3 cp "$PACKAGE_FILE" "s3://${BUCKET_NAME}/lambda/${PACKAGE_NAME}.zip" --no-progress; then
            log "Upload successful on attempt $i"
            break
        fi
        if [ $i -eq 3 ]; then
            log "Error: Failed to upload after 3 attempts"
            exit 1
        fi
        log "Upload failed, retrying in 10 seconds..."
        sleep 10
    done

    # Verify upload
    if aws s3 ls "s3://${BUCKET_NAME}/lambda/${PACKAGE_NAME}.zip" > /dev/null 2>&1; then
        log "Upload verification successful"
    else
        log "Error: Could not verify file upload"
        exit 1
    fi

    # Provide update command hint
    log "To update the Lambda function, run:"
    log "./deploy-v2.sh --update --[sanitized]-workmail-v2"
fi

# Call cleanup at the end
cleanup

log "Package created successfully: ${PACKAGE_FILE}"
if [ "$SKIP_UPLOAD" = false ]; then
    log "Lambda package location: s3://${BUCKET_NAME}/lambda/${PACKAGE_NAME}.zip"
    log "Region: ${AWS_DEFAULT_REGION}"
fi
