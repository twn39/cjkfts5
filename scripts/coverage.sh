#!/usr/bin/env bash
set -euo pipefail

# Scripts for running Swift unit tests with code coverage enabled
# and generating coverage reports (terminal summary, HTML, LCOV, or threshold check).

USAGE="Usage: $0 [--summary | --html | --lcov | --json] [--skip-test] [--check-threshold <percent>]"

MODE="summary"
SKIP_TEST=false
THRESHOLD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --html)
            MODE="html"
            shift
            ;;
        --lcov)
            MODE="lcov"
            shift
            ;;
        --json)
            MODE="json"
            shift
            ;;
        --summary)
            MODE="summary"
            shift
            ;;
        --skip-test)
            SKIP_TEST=true
            shift
            ;;
        --check-threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "$USAGE"
            exit 1
            ;;
    esac
done

if [ "$SKIP_TEST" = false ]; then
    echo "Running tests with code coverage..."
    swift test --enable-code-coverage
fi

BIN_PATH=$(swift build --show-bin-path)
CODECOV_JSON=$(swift test --show-codecov-path)
CODECOV_DIR=$(dirname "$CODECOV_JSON")
PROFDATA="$CODECOV_DIR/default.profdata"

# Locating test binary
TEST_BINARY=$(find "$BIN_PATH" -name "cjkfts5PackageTests" -type f | head -n 1)

if [ -z "$TEST_BINARY" ] || [ ! -f "$TEST_BINARY" ]; then
    echo "Error: Test binary not found in $BIN_PATH"
    exit 1
fi

if [ ! -f "$PROFDATA" ]; then
    echo "Error: Coverage profile data not found at $PROFDATA"
    exit 1
fi

IGNORE_REGEX="\.build|Tests"

case "$MODE" in
    summary)
        echo ""
        echo "=== Code Coverage Report ==="
        xcrun llvm-cov report "$TEST_BINARY" -instr-profile="$PROFDATA" --ignore-filename-regex="$IGNORE_REGEX"
        ;;
    html)
        OUTPUT_DIR="coverage/html"
        mkdir -p "$OUTPUT_DIR"
        xcrun llvm-cov show "$TEST_BINARY" -instr-profile="$PROFDATA" --ignore-filename-regex="$IGNORE_REGEX" --format=html -output-dir="$OUTPUT_DIR"
        echo ""
        echo "HTML coverage report generated at: file://$(pwd)/$OUTPUT_DIR/index.html"
        ;;
    lcov)
        mkdir -p coverage
        xcrun llvm-cov export "$TEST_BINARY" -instr-profile="$PROFDATA" --ignore-filename-regex="$IGNORE_REGEX" -format=lcov > coverage/lcov.info
        echo ""
        echo "LCOV coverage report exported to: coverage/lcov.info"
        ;;
    json)
        mkdir -p coverage
        xcrun llvm-cov export "$TEST_BINARY" -instr-profile="$PROFDATA" --ignore-filename-regex="$IGNORE_REGEX" -format=text > coverage/coverage.json
        echo ""
        echo "JSON coverage summary exported to: coverage/coverage.json"
        ;;
esac

if [ "$THRESHOLD" -gt 0 ]; then
    TOTAL_LINE=$(xcrun llvm-cov report "$TEST_BINARY" -instr-profile="$PROFDATA" --ignore-filename-regex="$IGNORE_REGEX" | grep "TOTAL" || true)
    LINE_COVER=$(echo "$TOTAL_LINE" | awk '{print $(NF-3)}' | sed 's/%//')
    echo ""
    echo "Current Line Coverage: ${LINE_COVER}% (Target Threshold: ${THRESHOLD}%)"
    
    python3 -c "
import sys
cur = float('$LINE_COVER')
tgt = float('$THRESHOLD')
if cur < tgt:
    print(f'❌ Coverage check failed: {cur}% is below threshold {tgt}%')
    sys.exit(1)
else:
    print(f'✅ Coverage threshold check passed ({cur}% >= {tgt}%)')
"
fi
