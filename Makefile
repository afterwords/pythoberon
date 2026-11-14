# Makefile for AMD BC-250 PXE Provisioning Repository

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.PHONY: help fetch fetch-ipxe fetch-iso stage up up-pxe down down-pxe logs logs-pxe up-ai down-ai logs-ai status check lint wgp-probe wgp-report wgp-apply wgp-status wgp-force-disable wgp-resume

help:
	@echo "Available targets:"
	@echo "  make fetch     - Download x86_64 UEFI ipxe.efi and Arch Linux ISO"
	@echo "  make stage     - Extract Arch ISO into www/arch/ for HTTP serving"
	@echo "  make up        - Start PXE services (tftp + web) in background"
	@echo "  make down      - Stop and remove PXE containers"
	@echo "  make logs      - Follow live logs from PXE containers"
	@echo "  make up-ai     - Start AI stack (Open WebUI + SearXNG) in background"
	@echo "  make down-ai   - Stop AI stack containers"
	@echo "  make logs-ai   - Follow live logs from AI stack containers"
	@echo "  make status    - Show container and staged file status"
	@echo "  make check     - Test TFTP and HTTP endpoints (curl + tftp test)"
	@echo "  make lint      - Run shellcheck on all repository shell scripts"
	@echo ""
	@echo "WGP Probe Wizard:"
	@echo "  make wgp-probe        Run full WGP probe cycle from stock state"
	@echo "  make wgp-resume       Resume an interrupted probe"
	@echo "  make wgp-report       Show probe results summary"
	@echo "  make wgp-apply        Apply verified masks to boot service"
	@echo "  make wgp-force-disable  Force-disable a specific WGP (ARGS='SE.SH.WGP')"
	@echo "  make wgp-status       Show current live-manager status"

fetch: fetch-ipxe fetch-iso

fetch-ipxe:
	@./scripts/fetch-ipxe.sh

fetch-iso:
	@./scripts/fetch-arch-iso.sh

stage:
	@./scripts/stage-iso.sh

up: up-pxe

up-pxe:
	@echo "==> Starting PXE services (tftp + web)..."
	docker compose -f docker-compose.pxe.yml up -d

down: down-pxe

down-pxe:
	@echo "==> Stopping PXE services..."
	docker compose -f docker-compose.pxe.yml down

logs: logs-pxe

logs-pxe:
	@echo "==> Streaming PXE logs (Ctrl+C to stop)..."
	docker compose -f docker-compose.pxe.yml logs -f

up-ai:
	@echo "==> Starting AI services (Open WebUI + SearXNG)..."
	@if [ -f config.env ]; then \
		docker compose -f docker-compose.ai.yml --env-file config.env up -d; \
	else \
		docker compose -f docker-compose.ai.yml up -d; \
	fi

down-ai:
	@echo "==> Stopping AI services..."
	docker compose -f docker-compose.ai.yml down

logs-ai:
	@echo "==> Streaming AI logs (Ctrl+C to stop)..."
	docker compose -f docker-compose.ai.yml logs -f

status:
	@echo "==> PXE Stack status:"
	@docker compose -f docker-compose.pxe.yml ps || true
	@echo ""
	@echo "==> AI Stack status:"
	@docker compose -f docker-compose.ai.yml ps || true
	@echo ""
	@echo "==> Bootloader:"
	@ls -lh tftp/ipxe.efi 2>/dev/null || echo "  tftp/ipxe.efi missing (run 'make fetch')"
	@echo ""
	@echo "==> Staged Arch ISO assets:"
	@ls -lh www/arch/arch/boot/x86_64/ 2>/dev/null || echo "  Kernel/initramfs missing (run 'make stage')"
	@ls -lh www/arch/arch/x86_64/airootfs.* 2>/dev/null || echo "  airootfs missing (run 'make stage')"

check:
	@./scripts/check.sh

lint:
	@echo "==> Running script validation..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck on all scripts..."; \
		shellcheck scripts/*.sh www/provision/*.sh; \
		echo "==> All scripts passed shellcheck."; \
	else \
		echo "NOTE: 'shellcheck' not found in PATH; running bash -n syntax checks instead..."; \
		for f in scripts/*.sh www/provision/*.sh; do \
			bash -n "$$f" || exit 1; \
			echo "  [OK] $$f"; \
		done; \
		echo "==> All scripts passed syntax validation. (Install 'shellcheck' for full static analysis)."; \
	fi

# ==============================================================================
# WGP Probe Wizard targets
# ==============================================================================
WGP_WIZARD := scripts/wgp-wizard.sh

wgp-probe:
	@echo "==> Running WGP probe wizard (requires sudo)..."
	sudo $(WGP_WIZARD) probe

wgp-resume:
	@echo "==> Resuming interrupted WGP probe (requires sudo)..."
	sudo $(WGP_WIZARD) resume

wgp-report:
	@$(WGP_WIZARD) report

wgp-apply:
	@echo "==> Applying verified WGP masks to boot service (requires sudo)..."
	sudo $(WGP_WIZARD) apply

wgp-force-disable:
	@echo "==> Force-disabling WGP ${ARGS} (requires sudo)..."
	[ -n "${ARGS}" ] || { echo "ERROR: ARGS='SE.SH.WGP' required. E.g.: make wgp-force-disable ARGS=1.0.3"; exit 1; }
	sudo $(WGP_WIZARD) force-disable ${ARGS}

wgp-status:
	@$(WGP_WIZARD) status

