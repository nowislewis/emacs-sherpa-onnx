# emacs-sherpa-onnx — sherpa-onnx ASR for Emacs (Qwen3-ASR)
#
#   make install     # venv + sherpa-onnx + download model
#   make test        # transcribe a bundled test wav
#   make clean       # remove the model
#   make uninstall   # remove the venv too

VENV      := .venv
PYTHON    := $(VENV)/bin/python3
MODEL_DIR := models
MODEL     := sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25
MODEL_URL := https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$(MODEL).tar.bz2

# axel (multi-connection) is faster for the ~840 MB model; fall back to curl.
DL := $(shell command -v axel >/dev/null 2>&1 && echo "axel -n 16 -o" || echo "curl -SL -C - -o")

.PHONY: all install venv model test clean uninstall

all: install

install: venv model
	@echo "Done. Emacs config:"
	@echo "  (add-to-list 'load-path \"$(CURDIR)\")"
	@echo "  (require 'emacs-sherpa)"
	@echo "  (global-set-key (kbd \"C-c d\") #'emacs-sherpa-dictate)"

venv:
	@command -v uv >/dev/null 2>&1 || { echo "error: uv not found (https://docs.astral.sh/uv/)"; exit 1; }
	uv venv $(VENV)
	uv pip install --python $(PYTHON) sherpa-onnx

model: $(MODEL_DIR)/$(MODEL)/encoder.int8.onnx

$(MODEL_DIR)/$(MODEL)/encoder.int8.onnx:
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && $(DL) m.tar.bz2 "$(MODEL_URL)" && tar xjf m.tar.bz2 && rm m.tar.bz2

test: model
	$(PYTHON) ./asr-sherpa $(MODEL_DIR)/$(MODEL)/test_wavs/codeswitch.wav

clean:
	rm -rf $(MODEL_DIR)

uninstall: clean
	rm -rf $(VENV)
