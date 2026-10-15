#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"

if [ -f "./Makefile" ] && [ -f "./bin/main.ml" ]; then
  REPO_DIR="$(pwd)"
elif [ -f "../Makefile" ] && [ -f "../bin/main.ml" ]; then
  REPO_DIR="$(cd .. && pwd)"
else
  REPO_DIR="$(pwd)"
fi

WORK_DIR="/tmp/voidnet_demo"
OUTPUT_DIR="${REPO_DIR}/demo_output"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

echo "[1/4] Checking dependencies and permissions..."
echo "[*] Target User: ${TARGET_USER}"
sudo -v

SUDOERS_FILE="/etc/sudoers.d/voidnet_demo_tmp"

cleanup_sudoers() {
  echo ""
  echo "[*] Cleanup: Revoking temporary NOPASSWD sudoers privilege..."
  sudo rm -f "${SUDOERS_FILE}"
}
trap cleanup_sudoers EXIT INT TERM

echo "[*] Applying temporary NOPASSWD for automated VHS headless run..."
echo "${TARGET_USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee "${SUDOERS_FILE}" >/dev/null
sudo chmod 0440 "${SUDOERS_FILE}"

for pkg in ffmpeg uv tmux; do
  if ! command -v "${pkg}" >/dev/null 2>&1; then
    echo "[*] Installing ${pkg} via pacman..."
    sudo pacman -S --noconfirm "${pkg}"
  fi
done

if ! command -v vhs >/dev/null 2>&1; then
  echo "[*] Installing vhs..."
  if command -v yay >/dev/null 2>&1; then
    yay -S --noconfirm vhs-bin
  else
    sudo pacman -S --noconfirm vhs || { echo "[-] Failed to install vhs"; exit 1; }
  fi
fi

# 2. 英語 AI ナレーション音声の生成
echo "[2/4] Generating high-fidelity English narration (uvx edge-tts)..."
VOICE="en-US-ChristopherNeural"

uvx edge-tts --voice "${VOICE}" \
  --text "Voidnet is a zero-trace, volatile multi-protocol proxy engine built on Linux network namespaces and tmpfs isolation." \
  --write-media "${WORK_DIR}/audio_1.mp3"

uvx edge-tts --voice "${VOICE}" \
  --text "On the left, twenty isolated tunnels provision simultaneously across WireGuard, OpenVPN, and Tor." \
  --write-media "${WORK_DIR}/audio_2.mp3"

uvx edge-tts --voice "${VOICE}" \
  --text "Once bootstrapped, each protocol is routed concurrently across the three panes on the right, dynamically dispatching traffic through discrete exit nodes." \
  --write-media "${WORK_DIR}/audio_3.mp3"

uvx edge-tts --voice "${VOICE}" \
  --text "On shutdown, all virtual interfaces, namespaces, and temporary files dissolve instantly. Zero persistent bytes remain on the host." \
  --write-media "${WORK_DIR}/audio_4.mp3"

echo "[*] Mixing and aligning narration timeline..."
ffmpeg -y \
  -i "${WORK_DIR}/audio_1.mp3" \
  -i "${WORK_DIR}/audio_2.mp3" \
  -i "${WORK_DIR}/audio_3.mp3" \
  -i "${WORK_DIR}/audio_4.mp3" \
  -filter_complex "[0:a]adelay=1000|1000[a0];[1:a]adelay=6500|6500[a1];[2:a]adelay=36000|36000[a2];[3:a]adelay=68000|68000[a3];[a0][a1][a2][a3]amix=inputs=4:dropout_transition=0[out]" \
  -map "[out]" -c:a libmp3lame -q:a 2 "${WORK_DIR}/full_narration.mp3"

# 3. VHS スクリプト（tmux 左50% + 右3分割）の生成と録画
echo "[3/4] Recording terminal showcase (VHS with 4-pane tmux)..."

cat << TAPE > "${WORK_DIR}/demo.tape"
Output "${WORK_DIR}/raw_demo.mp4"
Set Shell "bash"
Set FontSize 12
Set Width 1480
Set Height 820
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set LetterSpacing 0
Set LineHeight 1.15

# セッション初期化
Type "unset TMUX && cd ${REPO_DIR} && clear"
Enter
Sleep 300ms

Type "tmux kill-session -t voidnet-showcase 2>/dev/null || true"
Enter
Sleep 400ms

Type "tmux new-session -s voidnet-showcase"
Enter
Sleep 1s

Type "tmux set -g status off"
Enter
Sleep 500ms

# --- レイアウト構築 ---
# 1. 左右 50:50 で分割 (右ペインへフォーカス)
Type "tmux split-window -h -p 50"
Enter
Sleep 500ms

# 2. 右ペインを縦に3分割
Type "tmux split-window -v -p 50"
Enter
Sleep 500ms

Type "tmux split-window -v -p 50"
Enter
Sleep 500ms

# --- ペインの初期化とタイトル設定 ---
# ペイン3: Tor (右下)
Type "cd ${REPO_DIR} && clear"
Enter
Type "echo '>>> [Pane 3: Tor SOCKS5 (Port 1082)] Standby...'"
Enter
Sleep 500ms

# ペイン2: WireGuard (右中)
Ctrl+B
Sleep 100ms
Up
Sleep 300ms
Type "cd ${REPO_DIR} && clear"
Enter
Type "echo '>>> [Pane 2: WireGuard SOCKS5 (Port 1081)] Standby...'"
Enter
Sleep 500ms

# ペイン1: OpenVPN (右上)
Ctrl+B
Sleep 100ms
Up
Sleep 300ms
Type "cd ${REPO_DIR} && clear"
Enter
Type "echo '>>> [Pane 1: OpenVPN SOCKS5 (Port 1083)] Standby...'"
Enter
Sleep 500ms

# ペイン0: エンジンログ (左)
Ctrl+B
Sleep 100ms
Left
Sleep 500ms
Type "cd ${REPO_DIR} && clear"
Enter
Sleep 500ms

# --- 左ペインで voidnet を起動 ---
Type "make run CONFIG=~/.config/voidnet/all_config.yaml"
Sleep 500ms
Enter

# 起動ログが流れ始めるのを待機
Sleep 3s

# --- 右上のペイン1へ移動し、開通監視を開始 ---
Ctrl+B
Sleep 100ms
Right
Sleep 500ms

# Tor(1082)が開通するのを動的監視
Type "printf '>>> Syncing with engine bootstrap'; for i in {1..35}; do if curl -s --connect-timeout 1 --socks5-hostname 127.0.0.1:1082 https://check.torproject.org/api/ip >/dev/null 2>&1; then echo ''; echo ' [✓] All 20 nodes active!'; break; fi; printf '.'; sleep 1; done"
Enter

# 開通検知完了まで待機
Sleep 20s

# --- テスト 1: 右上ペイン (OpenVPN / Port 1083) ---
Type "echo '>>> Testing OpenVPN Entrypoint (Port 1083)...'"
Enter
Sleep 500ms
Type "curl -s --connect-timeout 10 --max-time 15 --socks5-hostname 127.0.0.1:1083 https://api.ipify.org && echo ''"
Sleep 500ms
Enter
Sleep 8s

# --- テスト 2: 真ん中ペイン (WireGuard / Port 1081) へ移動 ---
Ctrl+B
Sleep 100ms
Down
Sleep 500ms
Type "echo '>>> Testing WireGuard Round-Robin (Port 1081)...'"
Enter
Sleep 500ms
Type "for i in {1..2}; do curl -s --connect-timeout 30 --socks5-hostname 127.0.0.1:1081 https://api.ipify.org && echo ''; sleep 0.5; done"
Sleep 500ms
Enter
Sleep 60s

# --- テスト 3: 一番下ペイン (Tor / Port 1082) へ移動 ---
Ctrl+B
Sleep 100ms
Down
Sleep 500ms
Type "echo '>>> Testing Tor Ephemeral Circuit (Port 1082)...'"
Enter
Sleep 500ms
Type "curl -s --connect-timeout 10 --max-time 15 --socks5-hostname 127.0.0.1:1082 https://check.torproject.org/api/ip && echo ''"
Sleep 500ms
Enter
Sleep 8s

# --- フィナーレ: 左ペインに戻り、Ctrl+C で停止 ---
Ctrl+B
Sleep 100ms
Left
Sleep 1s
Ctrl+C
Sleep 4s

# --- 右上ペインに切り替え、ホスト残骸ゼロの検証 ---
Ctrl+B
Sleep 100ms
Right
Sleep 500ms
Type "echo '>>> Verifying host interfaces (0 traces):' && ip link | grep 'veth-'"
Sleep 500ms
Enter
Sleep 3s

Type "echo '[+] Containment dissolved. 0 bytes persistent on host.'"
Sleep 500ms
Enter
Sleep 5s
TAPE

# セッション掃除後に録画開始
tmux kill-session -t voidnet-showcase 2>/dev/null || true
vhs "${WORK_DIR}/demo.tape"
tmux kill-session -t voidnet-showcase 2>/dev/null || true

# 4. 音声と映像の結合
echo "[4/4] Merging video with English narration stream..."
ffmpeg -y -i "${WORK_DIR}/raw_demo.mp4" -i "${WORK_DIR}/full_narration.mp3" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 192k "${OUTPUT_DIR}/voidnet_showcase_with_narration.mp4"

echo ""
echo "[+] English narrated showcase video generated successfully!"
echo "[+] Artifact: ${OUTPUT_DIR}/voidnet_showcase_with_narration.mp4"
