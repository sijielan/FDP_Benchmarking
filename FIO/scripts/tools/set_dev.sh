#!/bin/bash

set -e

# ========== Configuration Section ==========
# NSZE and NCAP are auto-detected from the device via:
#   nvme id-ctrl <dev> | grep nvmcap  →  first non-zero value / 4096
# They can be overridden via environment variables:
#   NSZE=937684566 NCAP=937684566 ./set_dev.sh -d /dev/nvme1 -f 1

BS="${BS:-4096}"           # Block size in bytes
ENDGID="${ENDGID:-1}"      # Endurance group ID
# CTRLID is auto-detected from the device (can be overridden via env: CTRLID=7 ./set_dev.sh ...)

# FDP parameters – auto-detected from device model (can be overridden via env)
# PHNDLS="${PHNDLS:-0,1,2,3,4,5,6,7}"
# NPHNDLS="${NPHNDLS:-8}"

DEV=""
USE_FDP=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)
      DEV="$2"
      shift 2
      ;;
    -f|--fdp)
      USE_FDP="$2"
      shift 2
      ;;
    --nsze)
      NSZE="$2"
      shift 2
      ;;
    --ncap)
      NCAP="$2"
      shift 2
      ;;
    --block-size)
      BS="$2"
      shift 2
      ;;
    --controller-id)
      CTRLID="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 -d <device> -f <0|1> [OPTIONS]"
      echo ""
      echo "Required arguments:"
      echo "  -d, --device <path>        NVMe device (e.g., /dev/nvme1)"
      echo "  -f, --fdp <0|1>            FDP mode: 0=disable, 1=enable"
      echo ""
      echo "Optional arguments:"
      echo "  --nsze <blocks>            Namespace size in 4096-byte blocks (auto-detected if omitted)"
      echo "  --ncap <blocks>            Namespace capacity (defaults to NSZE)"
      echo "  --block-size <bytes>       Block size (default: 4096)"
      echo "  --controller-id <id>       Controller ID (default: 7)"
      echo "  -h, --help                 Show this help message"
      echo ""
      echo "Environment variables: NSZE, NCAP, BS, CTRLID, ENDGID, PHNDLS, NPHNDLS"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 -d <device> -f <USE_FDP: 0 or 1>"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$DEV" || -z "$USE_FDP" ]]; then
  echo "Error: Both --device and --fdp options are required."
  exit 1
fi

if [[ ! "$DEV" =~ ^/dev/nvme[0-9]+$ ]]; then
  echo "Error: Invalid device name '$DEV'. Expected format: /dev/nvmeX"
  exit 1
fi

if [[ "$USE_FDP" != "0" && "$USE_FDP" != "1" ]]; then
  echo "Error: --fdp must be either 0 (disable) or 1 (enable)."
  exit 1
fi

# ── Auto-detect NSZE from device (unless overridden via env/arg) ──────────────
# Command: nvme id-ctrl <dev> | grep nvmcap | sed "s/,//g" | awk '{print $3/4096}'
# Output has two lines; take the first non-zero value.
if [[ -z "$NSZE" ]]; then
  echo "[*] Auto-detecting namespace size from $DEV ..."
  NSZE=$(sudo nvme id-ctrl "$DEV" \
         | grep nvmcap \
         | sed "s/,//g" \
         | awk '{v=int($3/4096); if(v>0){print v; exit}}')

  if [[ -z "$NSZE" || "$NSZE" -le 0 ]]; then
    echo "Error: could not determine NSZE from 'nvme id-ctrl $DEV'." >&2
    echo "       Check that the device exists and nvme-cli has permission." >&2
    exit 1
  fi
  echo "    Detected NSZE: $NSZE blocks  ($(awk "BEGIN{printf \"%.2f\", $NSZE*4096/1e12}") TB)"
fi

NCAP="${NCAP:-$NSZE}"

# ── Auto-detect CTRLID from device (unless overridden via env) ───────────────
if [[ -z "$CTRLID" ]]; then
  echo "[*] Auto-detecting Controller ID from $DEV ..."
  CTRLID=$(sudo nvme id-ctrl "$DEV" --output-format=json 2>/dev/null \
           | python3 -c "import sys,json; print(json.load(sys.stdin)['cntlid'])" 2>/dev/null)

  if [[ -z "$CTRLID" || "$CTRLID" -le 0 ]]; then
    echo "Error: could not detect CTRLID from 'nvme id-ctrl $DEV'" >&2
    exit 1
  fi
  echo "    Detected CTRLID: $CTRLID"
fi

# ── Auto-detect PHNDLS / NPHNDLS from device model ───────────────────────────
# Model lookup table:
#   8 PIDs (0-7): MZWL63T8HFLT-00AAZ  MZOL67T6HBLC-01AFB
#   7 PIDs (0-6): MZOL63T8HDLT-00AFB  MZOL61T9HDLT-00AFB
# Override via env: PHNDLS="0,1,2,3,4,5,6" NPHNDLS=7 ./set_dev.sh ...
if [[ -z "$NPHNDLS" ]]; then
  echo "[*] Auto-detecting PID count from $DEV model ..."
  MODEL=$(sudo nvme id-ctrl "$DEV" --output-format=json 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('mn','').strip())" \
          2>/dev/null || true)

  if [[ -z "$MODEL" ]]; then
    echo "Error: could not read device model from 'nvme id-ctrl $DEV'" >&2
    exit 1
  fi

  # Extract last token of model string, e.g. "SAMSUNG MZWL63T8HFLT-00AAZ" → "MZWL63T8HFLT-00AAZ"
  MODEL_KEY="${MODEL##* }"

  case "$MODEL_KEY" in
    MZWL63T8HFLT-00AAZ | MZOL67T6HBLC-01AFB)
      NPHNDLS=8
      PHNDLS="0,1,2,3,4,5,6,7"
      ;;
    MZOL63T8HDLT-00AFB | MZOL61T9HDLT-00AFB)
      NPHNDLS=7
      PHNDLS="0,1,2,3,4,5,6"
      ;;
    *)
      echo "Error: unknown model '$MODEL' – cannot determine PID count." >&2
      echo "       Add it to the lookup table in set_dev.sh, or set PHNDLS/NPHNDLS manually." >&2
      exit 1
      ;;
  esac

  echo "    Model:   $MODEL"
  echo "    PIDs:    $NPHNDLS  ($PHNDLS)"
fi

# If PHNDLS was set by env but NPHNDLS wasn't, derive NPHNDLS from PHNDLS
if [[ -z "$NPHNDLS" ]]; then
  NPHNDLS=$(echo "$PHNDLS" | tr ',' '\n' | wc -l)
fi

# ── Display configuration ─────────────────────────────────────────────────────
echo "[*] Configuration:"
echo "    Device:       $DEV"
echo "    FDP enabled:  $USE_FDP"
echo "    NSZE:         $NSZE blocks"
echo "    NCAP:         $NCAP blocks"
echo "    Block size:   $BS bytes"
echo "    Controller:   $CTRLID"
echo "    Endgr ID:     $ENDGID"
if [[ "$USE_FDP" == "1" ]]; then
    echo "    Handles:      $PHNDLS"
    echo "    Num handles:  $NPHNDLS"
fi
echo ""

# ── Detach and delete existing namespaces ─────────────────────────────────────
# Failures here are tolerated (namespace may already be detached/deleted).
echo "[*] Detaching and deleting all existing namespaces..."
NSIDS=$(sudo nvme list-ns "$DEV" \
        | awk -F':' '/\[/{gsub(/0x/,"",$2); printf("%d\n", strtonum("0x"$2))}')

if [[ -z "$NSIDS" ]]; then
  echo " - No existing namespaces found."
else
  for nsid in $NSIDS; do
    echo " - Removing NSID $nsid"
    sudo nvme detach-ns "$DEV" --namespace-id="$nsid" --controllers="$CTRLID" \
      || echo "  [!] Detach skipped (may already be detached)"
    sudo nvme delete-ns  "$DEV" --namespace-id="$nsid" \
      || { echo "Error: failed to delete namespace $nsid" >&2; exit 1; }
  done
fi

# ── Create and attach namespace ───────────────────────────────────────────────
# Any failure below exits immediately.
if [[ "$USE_FDP" == "1" ]]; then
  echo "[*] Enabling FDP..."
  sudo nvme fdp configs "$DEV" --endgrp-id="$ENDGID" \
    || { echo "Error: nvme fdp configs failed" >&2; exit 1; }
  sudo nvme admin-passthru "$DEV" --opcode=0x9 --cdw10=0x8000001D --cdw11=0x1 --cdw12=0x1 \
    || { echo "Error: admin-passthru (enable FDP) failed" >&2; exit 1; }

  echo "[*] Creating namespace with FDP enabled..."
  CREATE_OUT=$(sudo nvme create-ns "$DEV" \
    --nsze="$NSZE" --ncap="$NCAP" --block-size="$BS" \
    --phndls="$PHNDLS" --nphndls="$NPHNDLS" --endg-id="$ENDGID") \
    || { echo "Error: nvme create-ns failed" >&2; exit 1; }
  echo "$CREATE_OUT"

  NSID=$(echo "$CREATE_OUT" | grep -oP 'nsid:\K[0-9]+')
  if [[ -z "$NSID" ]]; then
    echo "Error: could not extract NSID from create-ns output" >&2
    exit 1
  fi

  echo "[*] Attaching namespace $NSID to controller $CTRLID..."
  sudo nvme attach-ns "$DEV" --namespace-id="$NSID" --controllers="$CTRLID" \
    || { echo "Error: nvme attach-ns failed" >&2; exit 1; }

  sudo nvme admin-passthru "$DEV" --namespace-id=0x1 --opcode=0x19 --cdw11=0x1 --cdw12=0x201 \
    || { echo "Error: admin-passthru (post-attach) failed" >&2; exit 1; }

else
  echo "[*] Disabling FDP..."
  sudo nvme admin-passthru "$DEV" --opcode=0x9 --cdw10=0x8000001D --cdw11=0x1 --cdw12=0x0 \
    || { echo "Error: admin-passthru (disable FDP) failed" >&2; exit 1; }

  echo "[*] Creating namespace without FDP..."
  CREATE_OUT=$(sudo nvme create-ns "$DEV" \
    --nsze="$NSZE" --ncap="$NCAP" --block-size="$BS" --endg-id="$ENDGID") \
    || { echo "Error: nvme create-ns failed" >&2; exit 1; }
  echo "$CREATE_OUT"

  NSID=$(echo "$CREATE_OUT" | grep -oP 'nsid:\K[0-9]+')
  if [[ -z "$NSID" ]]; then
    echo "Error: could not extract NSID from create-ns output" >&2
    exit 1
  fi

  echo "[*] Attaching namespace $NSID to controller $CTRLID..."
  sudo nvme attach-ns "$DEV" --namespace-id="$NSID" --controllers="$CTRLID" \
    || { echo "Error: nvme attach-ns failed" >&2; exit 1; }
fi

# ── Wait for namespace device to appear ───────────────────────────────────────
NS_DEV="${DEV}n${NSID}"
sleep 1
if [[ ! -e "$NS_DEV" ]]; then
    echo "[!] Waiting 2 more seconds for $NS_DEV to appear..."
    sleep 2
    if [[ ! -e "$NS_DEV" ]]; then
        echo "Error: namespace device $NS_DEV not found after attach" >&2
        ls -la "${DEV}n"* 2>/dev/null || true
        exit 1
    fi
fi

sudo nvme dsm "$NS_DEV" -n 1 -b "$NCAP" \
  || { echo "Error: nvme dsm failed" >&2; exit 1; }

echo "[*] Using namespace device: $NS_DEV"
echo "[*] Checking FDP status (if supported)..."
sudo nvme fdp-status "$NS_DEV" || echo "Note: fdp-status may fail if FDP is not enabled."

echo ""
echo "[✓] Namespace setup completed successfully!"
echo "    Device:     $DEV"
echo "    Namespace:  $NS_DEV"
echo "    NSID:       $NSID"
echo "    FDP mode:   $USE_FDP"
echo "    NSZE:       $NSZE blocks"
echo ""
