#!/usr/bin/env bash
# lib/crypto.sh — opt-in AES-256-CBC encryption for sensitive config files
set -euo pipefail

# Files encrypted relative to CLAUDE_HOME (plaintext local, .enc in git)
readonly KITSYNC_ENCRYPT_FILES=("settings.json")

# ---------------------------------------------------------------------------
# _crypto_openssl — find a working openssl binary
# ---------------------------------------------------------------------------
_crypto_openssl() {
  local bin
  for bin in \
    "/opt/homebrew/bin/openssl" \
    "/usr/local/bin/openssl" \
    "openssl"; do
    if command -v "$bin" &>/dev/null 2>&1; then
      printf '%s' "$bin"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# _crypto_is_enabled — true when KITSYNC_ENCRYPT=true in config
# ---------------------------------------------------------------------------
_crypto_is_enabled() {
  local cfg="$CLAUDE_HOME/.kitsync/config"
  grep -q '^KITSYNC_ENCRYPT=true' "$cfg" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _crypto_key_path — path to the local encryption key file
# ---------------------------------------------------------------------------
_crypto_key_path() {
  printf '%s/.kitsync/encryption.key' "$CLAUDE_HOME"
}

# ---------------------------------------------------------------------------
# _crypto_set_enabled <true|false> — write KITSYNC_ENCRYPT into config
# ---------------------------------------------------------------------------
_crypto_set_enabled() {
  local val="$1"
  local cfg="$CLAUDE_HOME/.kitsync/config"
  mkdir -p "$(dirname "$cfg")" 2>/dev/null || true
  if grep -q '^KITSYNC_ENCRYPT=' "$cfg" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v '^KITSYNC_ENCRYPT=' "$cfg" > "$tmp" 2>/dev/null || true
    printf 'KITSYNC_ENCRYPT=%s\n' "$val" >> "$tmp"
    mv "$tmp" "$cfg"
  else
    printf 'KITSYNC_ENCRYPT=%s\n' "$val" >> "$cfg"
  fi
}

# ---------------------------------------------------------------------------
# _crypto_ensure_key — generate key if missing, chmod 600
# ---------------------------------------------------------------------------
_crypto_ensure_key() {
  local key_file
  key_file="$(_crypto_key_path)"
  mkdir -p "$(dirname "$key_file")" 2>/dev/null || true

  if [[ -f "$key_file" ]]; then
    chmod 600 "$key_file"
    return 0
  fi

  local openssl_bin
  if ! openssl_bin="$(_crypto_openssl)"; then
    log_error "openssl not found — cannot generate encryption key."
    return 1
  fi

  "$openssl_bin" rand -base64 32 > "$key_file"
  chmod 600 "$key_file"
  log_success "Encryption key generated: $key_file"
  log_warn "Back up this key — without it you cannot decrypt your config on a new machine."
  log_warn "Store it somewhere safe (password manager, separate secure location)."
}

# ---------------------------------------------------------------------------
# _crypto_encrypt_file <src> <dst> — atomically encrypt src → dst
# ---------------------------------------------------------------------------
_crypto_encrypt_file() {
  local src="$1" dst="$2"
  local key_file openssl_bin tmp

  key_file="$(_crypto_key_path)"
  if [[ ! -f "$key_file" ]]; then
    log_error "Encryption key not found: $key_file — run: claude-kitsync encrypt enable"
    return 1
  fi

  if ! openssl_bin="$(_crypto_openssl)"; then
    log_error "openssl not found."
    return 1
  fi

  tmp="${dst}.tmp.$$"
  touch "$tmp" && chmod 600 "$tmp"

  if ! "$openssl_bin" enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "file:${key_file}" \
      -in "$src" -out "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log_error "Encryption failed: $src"
    return 1
  fi

  mv "$tmp" "$dst"
}

# ---------------------------------------------------------------------------
# _crypto_decrypt_file <src> <dst> — atomically decrypt src → dst
# ---------------------------------------------------------------------------
_crypto_decrypt_file() {
  local src="$1" dst="$2"
  local key_file openssl_bin tmp

  key_file="$(_crypto_key_path)"
  if [[ ! -f "$key_file" ]]; then
    log_warn "Encryption key not found: $key_file — cannot decrypt $src"
    log_warn "Copy your key to $key_file then run: claude-kitsync pull"
    return 1
  fi

  if ! openssl_bin="$(_crypto_openssl)"; then
    log_error "openssl not found."
    return 1
  fi

  tmp="${dst}.tmp.$$"
  touch "$tmp" && chmod 600 "$tmp"

  if ! "$openssl_bin" enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "file:${key_file}" \
      -in "$src" -out "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log_error "Decryption failed: $src — wrong key or corrupted file?"
    return 1
  fi

  mv "$tmp" "$dst"
}

# ---------------------------------------------------------------------------
# crypto_encrypt_all — encrypt all KITSYNC_ENCRYPT_FILES before push
# Returns list of .enc files that were created (one per line).
# ---------------------------------------------------------------------------
crypto_encrypt_all() {
  _crypto_is_enabled || return 0

  local file enc_file
  for file in "${KITSYNC_ENCRYPT_FILES[@]}"; do
    local src="$CLAUDE_HOME/$file"
    enc_file="$CLAUDE_HOME/${file}.enc"
    if [[ ! -f "$src" ]]; then
      continue
    fi
    log_step "Encrypting $file..."
    if _crypto_encrypt_file "$src" "$enc_file"; then
      printf '%s\n' "$enc_file"
    fi
  done
}

# ---------------------------------------------------------------------------
# crypto_decrypt_all — decrypt all .enc files after pull
# ---------------------------------------------------------------------------
crypto_decrypt_all() {
  _crypto_is_enabled || return 0

  local file enc_file
  for file in "${KITSYNC_ENCRYPT_FILES[@]}"; do
    enc_file="$CLAUDE_HOME/${file}.enc"
    local dst="$CLAUDE_HOME/$file"
    if [[ ! -f "$enc_file" ]]; then
      continue
    fi
    _crypto_decrypt_file "$enc_file" "$dst" || true
  done
}

# ---------------------------------------------------------------------------
# cmd_encrypt — top-level dispatcher: enable / disable / rotate / status
# ---------------------------------------------------------------------------
cmd_encrypt() {
  local subcmd="${1:-}"

  case "$subcmd" in
    enable)
      _crypto_ensure_key || return 1
      _crypto_set_enabled "true"
      log_success "Encryption enabled."
      log_info "Run 'claude-kitsync push' — settings.json will be committed as settings.json.enc"
      ;;

    disable)
      if ! _crypto_is_enabled; then
        log_info "Encryption is already disabled."
        return 0
      fi
      _crypto_set_enabled "false"
      log_success "Encryption disabled."
      log_warn "Your settings.json.enc in git still exists — push a plaintext settings.json to replace it."
      ;;

    rotate)
      if ! _crypto_is_enabled; then
        log_warn "Encryption is not enabled. Run: claude-kitsync encrypt enable"
        return 1
      fi
      local key_file; key_file="$(_crypto_key_path)"
      local backup="${key_file}.bak.$(date '+%Y%m%dT%H%M%S')"
      [[ -f "$key_file" ]] && cp "$key_file" "$backup" && log_info "Old key backed up: $backup"

      local openssl_bin; openssl_bin="$(_crypto_openssl)" || { log_error "openssl not found."; return 1; }
      "$openssl_bin" rand -base64 32 > "$key_file"
      chmod 600 "$key_file"
      log_success "New key generated: $key_file"
      log_warn "Re-encrypt and push now: claude-kitsync push"
      log_warn "Update the key on all other machines before they pull."
      ;;

    status)
      printf "\n" >&2
      if _crypto_is_enabled; then
        log_success "Encryption: enabled  (AES-256-CBC)"
        local key_file; key_file="$(_crypto_key_path)"
        if [[ -f "$key_file" ]]; then
          log_info  "Key file:   $key_file  ($(stat -f '%z' "$key_file" 2>/dev/null || stat -c '%s' "$key_file" 2>/dev/null || echo '?') bytes)"
        else
          log_warn  "Key file:   MISSING — run: claude-kitsync encrypt enable"
        fi
        log_info  "Encrypts:   ${KITSYNC_ENCRYPT_FILES[*]}"
      else
        log_info "Encryption: disabled"
      fi
      printf "\n" >&2
      ;;

    "")
      local choice
      choice="$(_select_menu "Encryption" \
        "Enable  — encrypt settings.json before push" \
        "Disable — commit settings.json in plaintext" \
        "Rotate key — generate a new encryption key" \
        "Status" \
        "Back")"
      case "$choice" in
        1) cmd_encrypt enable ;;
        2) cmd_encrypt disable ;;
        3) cmd_encrypt rotate ;;
        4) cmd_encrypt status ;;
        5) return 0 ;;
      esac
      ;;

    *)
      log_error "Unknown subcommand: $subcmd"
      log_info "Usage: claude-kitsync encrypt [enable|disable|rotate|status]"
      return 1
      ;;
  esac
}
