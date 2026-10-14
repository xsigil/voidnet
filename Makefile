SHELL := /bin/bash
BIN_PATH := ./_build/default/bin/main.exe
CONFIG ?= config.example.yaml
JAIL_LIB_DIR := ./jail_libs

# 抽出対象の依存バイナリ一覧
REQUIRED_BINS := /usr/bin/openvpn /usr/bin/tor /usr/bin/wg

.PHONY: all build prepare run test clean clean-netns fmt help

all: build

# Dune を用いた通常ビルド
build:
	@dune build
	@echo "[+] ビルド完了: $(BIN_PATH)"

# void ldd を使用した jail_libs の自動生成
prepare:
	@echo "[+] jail_libs を準備しています..."
	@mkdir -p $(JAIL_LIB_DIR)
	@for bin in $(REQUIRED_BINS); do \
		if [ -f "$$bin" ]; then \
			echo " -> 依存ライブラリ抽出: $$bin"; \
			sudo void ldd "$$bin" $(JAIL_LIB_DIR) || exit 1; \
		else \
			echo "[-] 警告: $$bin が見つかりません"; \
		fi \
	done
	@echo "[+] jail_libs の準備が完了しました。"

# 実行（jail_libs が存在しない場合は自動で prepare を実行）
run: build
	@if [ ! -d "$(JAIL_LIB_DIR)" ]; then \
		$(MAKE) prepare; \
	fi
	@echo "[+] voidnet を起動します (Config: $(CONFIG))..."
	@sudo $(BIN_PATH) $(CONFIG)

# 残存した network namespace の一括削除
clean-netns:
	@echo "[+] 残存 network namespace をクリーンアップ中..."
	@for ns in $$(ip netns list | awk '{print $$1}'); do \
		if [[ $$ns == ns-* ]]; then \
			echo " -> 削除: $$ns"; \
			sudo ip netns delete "$$ns" 2>/dev/null || true; \
		fi \
	done
	@echo "[+] netns のクリーンアップ完了。"

# ビルド成果物および一時ライブラリの削除
clean: clean-netns
	@dune clean
	@sudo rm -rf $(JAIL_LIB_DIR)
	@echo "[+] クリーンアップ完了。"

test:
	@dune runtest

fmt:
	@dune build @fmt --auto-promote

help:
	@echo "利用可能なコマンド:"
	@echo "  make build         - バイナリをビルド"
	@echo "  make prepare       - void ldd を実行して jail_libs を生成"
	@echo "  make run [CONFIG=] - voidnet を実行 (例: make run CONFIG=~/.config/voidnet/config.yaml)"
	@echo "  make clean-netns   - 異常終了時に残った ns-* を削除"
	@echo "  make clean         - ビルド成果物と jail_libs、netns を全削除"