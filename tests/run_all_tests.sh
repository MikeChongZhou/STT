#!/bin/bash
# STT Integration Test Runner
# Runs all automated tests and reports results
#
# Usage: ./tests/run_all_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { ((PASS++)); echo -e "${GREEN}  ✅ $1${NC}"; }
log_fail() { ((FAIL++)); echo -e "${RED}  ❌ $1${NC}"; }
log_skip() { ((SKIP++)); echo -e "${YELLOW}  ⏭️  $1${NC}"; }
log_section() { echo -e "\n━━━ $1 ━━━"; }

# ============================================================
# T0: Build verification
# ============================================================

log_section "T0: Build verification"

echo "Building macOS app..."
if ./build_macos.sh > /dev/null 2>&1; then
    log_pass "macOS build succeeded"
    if [ -f "dist/ScreenTimeGuardian.app/Contents/MacOS/ScreenTimeGuardian" ]; then
        log_pass "macOS binary exists"
        # Check version
        VERSION=$(grep -o 'version.*"[0-9.]*"' macos/Info.plist 2>/dev/null | head -1 || echo "")
        if [ -n "$VERSION" ]; then
            log_pass "Version found in Info.plist: $VERSION"
        else
            log_fail "Version not found in Info.plist"
        fi
    else
        log_fail "macOS binary not found"
    fi
else
    log_fail "macOS build failed"
fi

# ============================================================
# T-UNIT: Unit tests
# ============================================================

log_section "T-UNIT: Swift unit tests"

if command -v swift &> /dev/null; then
    echo "Running IntegrationTests.swift..."
    if swift tests/IntegrationTests.swift 2>&1; then
        log_pass "All unit tests passed"
    else
        log_fail "Some unit tests failed"
    fi
else
    log_skip "Swift not available, skipping unit tests"
fi

# ============================================================
# T-JSON: JSON schema validation
# ============================================================

log_section "T-JSON: Data format validation"

# Check sync snapshot schema exists
if [ -f "shared/sync/sync-snapshot.schema.json" ]; then
    log_pass "sync-snapshot.schema.json exists"
else
    log_fail "sync-snapshot.schema.json missing"
fi

if [ -f "shared/sync/screen-session.schema.json" ]; then
    log_pass "screen-session.schema.json exists"
else
    log_fail "screen-session.schema.json missing"
fi

if [ -f "shared/sync/encrypted-envelope.schema.json" ]; then
    log_pass "encrypted-envelope.schema.json exists"
else
    log_fail "encrypted-envelope.schema.json missing"
fi

# ============================================================
# T-CONFIG: Configuration consistency
# ============================================================

log_section "T-CONFIG: Configuration consistency"

# Check service type consistency
MACOS_ST=$(grep -o '"_stg-sync\._tcp"' Sources/main.swift 2>/dev/null | head -1 || echo "")
IOS_ST=$(grep -o '"_stg-sync\._tcp"' iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOSApp.swift 2>/dev/null | head -1 || echo "")
ANDROID_ST=$(grep -o '"_stg-sync\._tcp' android/app/src/main/java/com/timbertrail/screentimeguardian/P2PTransport.kt 2>/dev/null | head -1 || echo "")

if [ -n "$MACOS_ST" ] && [ -n "$IOS_ST" ] && [ -n "$ANDROID_ST" ]; then
    log_pass "Bonjour service type consistent across platforms (_stg-sync._tcp)"
else
    log_fail "Bonjour service type mismatch: macOS='$MACOS_ST' iOS='$IOS_ST' Android='$ANDROID_ST'"
fi

# Check version consistency
MACOS_VER=$(grep -o 'appVersion.*"[0-9.]*"' Sources/main.swift 2>/dev/null | head -1 || echo "")
IOS_VER=$(grep -o 'appVersion.*"[0-9.]*"' iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOSApp.swift 2>/dev/null | head -1 || echo "")
ANDROID_VER=$(grep -o 'versionName.*"[0-9.]*"' android/app/build.gradle.kts 2>/dev/null | head -1 || echo "")

echo "  macOS version: $MACOS_VER"
echo "  iOS version: $IOS_VER"
echo "  Android version: $ANDROID_VER"

# Check capabilities
MACOS_CAPS=$(grep -c "delta_sync\|gzip\|history_compaction" Sources/main.swift 2>/dev/null || echo "0")
IOS_CAPS=$(grep -c "delta_sync\|gzip\|history_compaction" iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOSApp.swift 2>/dev/null || echo "0")

if [ "$MACOS_CAPS" -gt 0 ] && [ "$IOS_CAPS" -gt 0 ]; then
    log_pass "Sync capabilities declared on macOS and iOS"
else
    log_fail "Sync capabilities missing"
fi

# ============================================================
# T-P2P: P2P protocol checks
# ============================================================

log_section "T-P2P: P2P protocol verification"

# Check 4-byte big-endian frame format
MACOS_FRAME=$(grep -c "UInt32.*bigEndian" Sources/main.swift 2>/dev/null || echo "0")
if [ "$MACOS_FRAME" -gt 0 ]; then
    log_pass "macOS: 4-byte big-endian frame format found"
else
    log_fail "macOS: 4-byte big-endian frame format NOT found"
fi

# Check device approval logic
MACOS_TRUST=$(grep -c "isTrusted\|trustStatus\|approvePeer" Sources/main.swift 2>/dev/null || echo "0")
ANDROID_TRUST=$(grep -c "isTrusted\|trustStatus\|approvePeer\|trustPeer" android/app/src/main/java/com/timbertrail/screentimeguardian/SessionStore.kt 2>/dev/null || echo "0")

if [ "$MACOS_TRUST" -gt 0 ] && [ "$ANDROID_TRUST" -gt 0 ]; then
    log_pass "Device approval logic present on macOS and Android"
else
    log_fail "Device approval logic missing"
fi

# ============================================================
# T-REMIND: Reminder logic checks
# ============================================================

log_section "T-REMIND: Reminder logic verification"

# Check absolute time countdown
MACOS_ABS=$(grep -c "canCloseAt\|canCloseAtMillis" Sources/main.swift 2>/dev/null || echo "0")
ANDROID_ABS=$(grep -c "canCloseAtMillis" android/app/src/main/java/com/timbertrail/screentimeguardian/RestPromptActivity.kt 2>/dev/null || echo "0")

if [ "$MACOS_ABS" -gt 0 ]; then
    log_pass "macOS: absolute time countdown (canCloseAt)"
else
    log_fail "macOS: absolute time countdown NOT found"
fi

if [ "$ANDROID_ABS" -gt 0 ]; then
    log_pass "Android: absolute time countdown (canCloseAtMillis)"
else
    log_fail "Android: absolute time countdown NOT found"
fi

# Check meeting mode
MACOS_MEETING=$(grep -c "meetingMode\|meetingCheckbox\|会议模式" Sources/main.swift 2>/dev/null || echo "0")
if [ "$MACOS_MEETING" -gt 0 ]; then
    log_pass "macOS: meeting mode implemented"
else
    log_fail "macOS: meeting mode NOT found"
fi

# ============================================================
# T-DEDUP: Deduplication logic checks
# ============================================================

log_section "T-DEDUP: Deduplication verification"

MACOS_UNION=$(grep -c "func unionSeconds" Sources/main.swift 2>/dev/null || echo "0")
ANDROID_UNION=$(grep -c "fun unionSeconds" android/app/src/main/java/com/timbertrail/screentimeguardian/SessionStore.kt 2>/dev/null || echo "0")

if [ "$MACOS_UNION" -gt 0 ] && [ "$ANDROID_UNION" -gt 0 ]; then
    log_pass "unionSeconds present on macOS and Android"
else
    log_fail "unionSeconds missing"
fi

# ============================================================
# T-IOS: iOS ScreenTime alignment checks
# ============================================================

log_section "T-IOS: iOS ScreenTime alignment"

IOS_THRESHOLD=$(grep -c "last_checkpoint_threshold_minutes\|lastCheckpointThreshold" iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianMonitorExtension/ScreenTimeGuardianMonitorExtension.swift 2>/dev/null || echo "0")
if [ "$IOS_THRESHOLD" -gt 0 ]; then
    log_pass "iOS: threshold-based alignment implemented"
else
    log_fail "iOS: threshold-based alignment NOT found"
fi

IOS_CHECKPOINT=$(grep -c "isCheckpointEvent" iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianMonitorExtension/ScreenTimeGuardianMonitorExtension.swift 2>/dev/null || echo "0")
if [ "$IOS_CHECKPOINT" -gt 0 ]; then
    log_pass "iOS: checkpoint event detection"
else
    log_fail "iOS: checkpoint event detection NOT found"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC} / $TOTAL total"

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}⚠️  $FAIL TESTS FAILED${NC}"
    exit 1
fi
