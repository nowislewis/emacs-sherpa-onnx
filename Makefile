# emacs-sherpa-onnx — streaming ASR for Emacs (sherpa-onnx ONNX, CPU-only)
#
#   make install      # venv + download streaming model (~120 MB)
#   make test-stream  # test streaming with a test wav
#   make clean        # remove models
#   make uninstall    # remove venv + models

VENV      := .venv
PYTHON    := $(VENV)/bin/python3
MODEL_DIR := models

# Streaming Zipformer2-CTC (ONNX, int8, Chinese, ~122 MB).
# For the larger/more-accurate build, add `xlarge-` before `int8`.
STREAM_MODEL := sherpa-onnx-streaming-zipformer-ctc-zh-int8-2025-06-30
STREAM_URL   := https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$(STREAM_MODEL).tar.bz2
STREAM_FILE  := model.int8.onnx

DL := $(shell command -v axel >/dev/null 2>&1 && echo "axel -n 16 -o" || echo "curl -SL -C - -o")

.PHONY: all install venv stream-model test-stream clean uninstall

all: install

install: venv stream-model
	@echo ""
	@echo "Done. Emacs config:"
	@echo "  (add-to-list 'load-path \"$(CURDIR)\")"
	@echo "  (require 'emacs-sherpa)"
	@echo "  (global-set-key (kbd \"C-c d\") #'emacs-sherpa-dictate)"

venv:
	@command -v uv >/dev/null 2>&1 || { echo "error: uv not found (https://docs.astral.sh/uv/)"; exit 1; }
	uv venv $(VENV)
	uv pip install --python $(PYTHON) sherpa-onnx

stream-model: $(MODEL_DIR)/$(STREAM_MODEL)/$(STREAM_FILE)

$(MODEL_DIR)/$(STREAM_MODEL)/$(STREAM_FILE):
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && $(DL) stream.tar.bz2 "$(STREAM_URL)" && tar xjf stream.tar.bz2 && rm stream.tar.bz2

test-stream: stream-model
	$(PYTHON) ./asr-sherpa-stream --wav $(MODEL_DIR)/$(STREAM_MODEL)/test_wavs/0.wav

clean:
	rm -rf $(MODEL_DIR)

uninstall: clean
	rm -rf $(VENV)
