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
# Plaintext is tokenized first (portable paths), and an existing .enc is kept
# as-is when its content is unchanged — AES-CBC uses a random salt, so
# re-encrypting identical content would create a spurious commit every push.
# Returns list of .enc files (one per line).
# ---------------------------------------------------------------------------
crypto_encrypt_all() {
  _crypto_is_enabled || return 0

  local file enc_file src plain_tmp prev_tmp
  for file in "${KITSYNC_ENCRYPT_FILES[@]}"; do
    src="$CLAUDE_HOME/$file"
    enc_file="$CLAUDE_HOME/${file}.enc"
    if [[ ! -f "$src" ]]; then
      continue
    fi

    plain_tmp="$CLAUDE_HOME/.kitsync/.plain.tmp.$$"
    prev_tmp="$CLAUDE_HOME/.kitsync/.prev.tmp.$$"
    mkdir -p "$CLAUDE_HOME/.kitsync" 2>/dev/null || true
    ( umask 077; paths_tokenize_stream < "$src" > "$plain_tmp" )

    if [[ -f "$enc_file" ]] && \
       _crypto_decrypt_file "$enc_file" "$prev_tmp" 2>/dev/null && \
       cmp -s "$plain_tmp" "$prev_tmp"; then
      rm -f "$plain_tmp" "$prev_tmp"
      printf '%s\n' "$enc_file"
      continue
    fi
    rm -f "$prev_tmp"

    log_step "Encrypting $file..."
    if _crypto_encrypt_file "$plain_tmp" "$enc_file"; then
      printf '%s\n' "$enc_file"
    fi
    rm -f "$plain_tmp"
  done
}

# ---------------------------------------------------------------------------
# _crypto_restore_from_history <file> — recreate a plaintext file that a pull
# removed from the index (another machine enabled encryption) when it cannot
# be decrypted locally. Uses the last committed plaintext version.
# ---------------------------------------------------------------------------
_crypto_restore_from_history() {
  local file="$1" dst="$CLAUDE_HOME/$1" last
  [[ -f "$dst" ]] && return 0
  last="$(git -C "$CLAUDE_HOME" rev-list -1 HEAD -- "$file" 2>/dev/null || true)"
  [[ -n "$last" ]] || return 0
  # $last is the commit that removed (or last touched) the file — try it, then its parent
  if git -C "$CLAUDE_HOME" show "$last:$file" > "$dst" 2>/dev/null || \
     git -C "$CLAUDE_HOME" show "$last^:$file" > "$dst" 2>/dev/null; then
    chmod 600 "$dst" 2>/dev/null || true
    log_warn "Restored $file from git history (could not decrypt ${file}.enc)."
  else
    rm -f "$dst"
  fi
}

# ---------------------------------------------------------------------------
# crypto_decrypt_all — decrypt all .enc files after pull, then resolve path
# tokens (decrypted content bypasses the git smudge filter).
# ---------------------------------------------------------------------------
crypto_decrypt_all() {
  _crypto_is_enabled || return 0

  local file enc_file
  for file in "${KITSYNC_ENCRYPT_FILES[@]}"; do
    enc_file="$CLAUDE_HOME/${file}.enc"
    if [[ -f "$enc_file" ]]; then
      _crypto_decrypt_file "$enc_file" "$CLAUDE_HOME/$file" || true
    fi
    _crypto_restore_from_history "$file"
  done
  paths_detokenize 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _crypto_gitignore_block <add|remove> — when encryption is on, plaintext
# settings files must be ignored so they are never staged again.
# .gitignore is synced, which matches KITSYNC_ENCRYPT being synced in config.
# ---------------------------------------------------------------------------
_crypto_gitignore_block() {
  local gi="$CLAUDE_HOME/.gitignore"
  local begin="# kitsync-encrypt-start" end="# kitsync-encrypt-end"
  local tmp; tmp="$(mktemp)"
  if [[ -f "$gi" ]]; then
    awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$gi" > "$tmp"
  fi
  if [[ "$1" == "add" ]]; then
    printf '%s\n# Encryption enabled — plaintext never synced\nsettings.json\nsettings.template.json\n%s\n' \
      "$begin" "$end" >> "$tmp"
  fi
  mv "$tmp" "$gi"
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
      _crypto_gitignore_block add
      # Stop tracking plaintext copies — the removal is committed on next push
      git -C "$CLAUDE_HOME" rm --cached -q --ignore-unmatch \
        settings.json settings.template.json 2>/dev/null || true
      log_success "Encryption enabled."
      log_info "Run 'claude-kitsync push' — settings.json will be committed as settings.json.enc"
      if [[ -n "$(git -C "$CLAUDE_HOME" log -1 --format=%h -- settings.json 2>/dev/null)" ]]; then
        log_warn "Earlier plaintext versions of settings.json remain in git history."
        log_warn "Rotate any secret they contained, or rewrite history (git filter-repo)."
      fi
      ;;

    disable)
      if ! _crypto_is_enabled; then
        log_info "Encryption is already disabled."
        return 0
      fi
      _crypto_set_enabled "false"
      _crypto_gitignore_block remove
      git -C "$CLAUDE_HOME" rm --cached -q --ignore-unmatch settings.json.enc 2>/dev/null || true
      log_success "Encryption disabled."
      log_info "Next 'claude-kitsync push' commits settings.json in plaintext and drops settings.json.enc."
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
      log_warn "The old key ($backup) still decrypts earlier .enc versions in git history — keep it private."
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
