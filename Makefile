PY = .venv/bin/python

up:       ; docker compose up -d
down:     ; docker compose down
lint:     ; $(PY) tools/lint_rules.py
test:     ; $(PY) -m pytest -q tests
load:     ; $(PY) tools/load_datasets.py
eval:     ; $(PY) tools/evaluate.py --out results/metrics.json
layer:    ; $(PY) tools/coverage.py results/metrics.json --out results/coverage_layer.json
convert:  ; $(PY) tools/convert.py --out results/converted
deploy:   ; $(PY) tools/deploy.py
all: lint test load eval layer convert
