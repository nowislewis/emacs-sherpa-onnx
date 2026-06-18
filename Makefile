# emacs-sherpa-onnx — sherpa-onnx ASR for Emacs (FireRedASR2-CTC + VAD + punctuation)
#
#   make install     # venv + sherpa-onnx + download model, VAD & punctuation
#   make test        # transcribe a bundled test wav
#   make clean       # remove the downloaded models
#   make uninstall   # remove the venv too

VENV      := .venv
PYTHON    := $(VENV)/bin/python3
MODEL_DIR := models
MODEL     := sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25
PUNCT     := sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8
REL       := https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models
PUNCT_REL := https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models
MODEL_URL := $(REL)/$(MODEL).tar.bz2
VAD_URL   := $(REL)/silero_vad.onnx
PUNCT_URL := $(PUNCT_REL)/$(PUNCT).tar.bz2

# axel (multi-connection) is faster for the ~520 MB model; fall back to curl.
DL := $(shell command -v axel >/dev/null 2>&1 && echo "axel -n 16 -o" || echo "curl -SL -C - -o")

.PHONY: all install venv model vad punct test clean uninstall

all: install

install: venv model vad punct
	@echo "Done. Emacs config:"
	@echo "  (add-to-list 'load-path \"$(CURDIR)\")"
	@echo "  (require 'emacs-sherpa)"
	@echo "  (global-set-key (kbd \"C-c d\") #'emacs-sherpa-dictate)"

venv:
	@command -v uv >/dev/null 2>&1 || { echo "error: uv not found (https://docs.astral.sh/uv/)"; exit 1; }
	uv venv $(VENV)
	uv pip install --python $(PYTHON) sherpa-onnx

model: $(MODEL_DIR)/$(MODEL)/model.int8.onnx
vad:   $(MODEL_DIR)/silero_vad.onnx
punct: $(MODEL_DIR)/$(PUNCT)/model.int8.onnx

$(MODEL_DIR)/$(MODEL)/model.int8.onnx:
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && $(DL) m.tar.bz2 "$(MODEL_URL)" && tar xjf m.tar.bz2 && rm m.tar.bz2

$(MODEL_DIR)/silero_vad.onnx:
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && $(DL) silero_vad.onnx "$(VAD_URL)"

$(MODEL_DIR)/$(PUNCT)/model.int8.onnx:
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && $(DL) p.tar.bz2 "$(PUNCT_URL)" && tar xjf p.tar.bz2 && rm p.tar.bz2

test: model vad
	$(PYTHON) ./asr-sherpa $(MODEL_DIR)/$(MODEL)/test_wavs/0.wav

clean:
	rm -rf $(MODEL_DIR)

uninstall: clean
	rm -rf $(VENV)
