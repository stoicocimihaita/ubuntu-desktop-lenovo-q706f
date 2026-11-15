#!/usr/bin/env bash
# Security cleanup of an installed q706f Ubuntu tablet (docs/DE-FACUT.md, sections E and F1).
# Runs on the PC, over ssh. Every step is opt-in (a flag) and idempotent. Without --apply
# nothing is changed: the script only reads the current state and prints what it would do.
#
#   scripts/desktop/tools/q706f-secure.sh [--apply] [--host H] [--key FILE.pub] STEP-FLAGS...
#
# Safe steps (no owner preference involved):
#   --apt-pins         install /etc/apt/preferences.d/90-q706f-forbidden and
#                      /etc/apt/apt.conf.d/90-q706f-no-recommends (copies of
#                      scripts/desktop/overlay, already part of new images)
#   --ssh-keys-only    put the PC's public key in authorized_keys (ssh-copy-id), check key
#                      login in a second connection, and only then disable password login
#                      (/etc/ssh/sshd_config.d/10-q706f-keys-only.conf; PermitRootLogin no)
#   --regen-hostkeys   new ssh host keys (old ones kept in /root), prints the new
#                      fingerprints, removes the old known_hosts entries of the q706f aliases
#                      on the PC and records the new key
# Owner-choice steps (DE-FACUT "(P)"; each one only with its own flag):
#   --no-autologin     comment out AutomaticLogin* in /etc/gdm3/custom.conf (next boot)
#   --screen-lock      lock-enabled=true, lock on suspend (user gsettings)
#   --no-unsafe-mode   disable the gnome-shell --unsafe-mode drop-in (next login)
#   --sudo-password    move NOPASSWD rules out of /etc/sudoers.d (sudo asks the password)
#   --keyring-encrypt  ONLY prints the steps: the owner sets the keyring up interactively
# Always printed at the end: how the owner changes the password (passwd, typed by them).
#
# The script never asks for, stores or passes a password. When sudo on the tablet needs a
# password, the remote command runs in "ssh -t" and the owner types it at sudo's prompt.
# Order of execution is fixed (apt, ssh, host keys, unsafe-mode, lock, autologin, sudo), so
# that password-less sudo, if present, is removed last.
# Each step prints how to revert it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OVL="$ROOT/scripts/desktop/overlay"
APPLY=0; HOST=q706f-ubuntu; KEY=""
DO_APT=0; DO_SSH=0; DO_HOSTKEYS=0; DO_AUTOLOGIN=0; DO_LOCK=0; DO_UNSAFE=0; DO_SUDO=0; DO_KEYRING=0
ALIASES=(q706f-ubuntu q706f-wifi q706f-vpn)   # ~/.ssh/config names used for this tablet
TABLET_USB_IP=172.16.42.1
usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
[ $# -gt 0 ] || { usage; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --host) HOST="${2:?}"; shift ;;
    --host=*) HOST="${1#--host=}" ;;
    --key) KEY="${2:?}"; shift ;;
    --key=*) KEY="${1#--key=}" ;;
    --apt-pins) DO_APT=1 ;;
    --ssh-keys-only) DO_SSH=1 ;;
    --regen-hostkeys) DO_HOSTKEYS=1 ;;
    --no-autologin) DO_AUTOLOGIN=1 ;;
    --screen-lock) DO_LOCK=1 ;;
    --no-unsafe-mode) DO_UNSAFE=1 ;;
    --sudo-password) DO_SUDO=1 ;;
    --keyring-encrypt) DO_KEYRING=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

SSHO=(-o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
ENVP='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
STAMP="$(date +%Y%m%d-%H%M%S)"
say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
revert() { printf '   revert: %s\n' "$*"; }
# Read-only command as the user (batch mode: key login only).
ru() { timeout --foreground "${2:-20}" ssh "${SSHO[@]}" -o BatchMode=yes "$HOST" "$ENVP $1"; }
confirm() {  # $1 exact word the owner has to type; only in --apply mode
  local a; printf '%s\n   Type "%s" to continue (anything else skips this step): ' "$2" "$1" >&2
  IFS= read -r a </dev/tty || return 1
  [ "$a" = "$1" ]
}
SUDO_N=0
# Run a shell script as root on the tablet. $1 = script text, $2 = optional short text shown
# instead of the script in a dry run. Without a password-less sudo the command runs in a
# terminal (ssh -t) and sudo asks the owner for the password there.
rroot() {
  local b64; b64="$(printf '%s' "$1" | base64 -w0)"
  if [ "$APPLY" = 0 ]; then
    printf '   [dry-run] would run as root on %s:\n' "$HOST"; printf '%s\n' "${2:-$1}" | sed 's/^/     | /'
    return 0
  fi
  if [ "$SUDO_N" = 1 ]; then
    timeout --foreground 120 ssh "${SSHO[@]}" "$HOST" "sudo -n sh -euc \"\$(printf %s $b64 | base64 -d)\""
  else
    ssh -t "${SSHO[@]}" "$HOST" "sudo sh -euc \"\$(printf %s $b64 | base64 -d)\""
  fi
}

[ "$APPLY" = 1 ] && echo "MODE: --apply (changes will be made on $HOST)" || echo "MODE: dry run (nothing is changed; add --apply)"
REACH=1
if ! RUSER="$(ru 'id -un' 15)"; then
  REACH=0
  warn "$HOST is not reachable with key login (BatchMode). Hint: q706f-vpn without USB."
  [ "$DO_SSH" = 1 ] || [ "$APPLY" = 0 ] || die "steps other than --ssh-keys-only need key login first"
  RUSER=ubuntu
else
  ru 'sudo -n true' 10 2>/dev/null && SUDO_N=1
  info "tablet user: $RUSER; password-less sudo: $([ "$SUDO_N" = 1 ] && echo yes || echo no)"
fi

# ------------------------------------------------------------------------ --apt-pins
step_apt() {
  say "apt pins (F1): forbidden packages + no Recommends"
  local p=etc/apt/preferences.d/90-q706f-forbidden c=etc/apt/apt.conf.d/90-q706f-no-recommends
  [ -f "$OVL/$p" ] && [ -f "$OVL/$c" ] || die "missing $OVL/$p or $OVL/$c"
  local want; want="$(cat "$OVL/$p" "$OVL/$c" | sha256sum | cut -d' ' -f1)"
  local have; have="$(ru "cat /$p /$c 2>/dev/null | sha256sum | cut -d' ' -f1" || true)"
  local inst; inst="$(ru "dpkg-query -W -f '\${Package} \${db:Status-Abbrev}\n' qbootctl droid-juicer qcom-phone-utils flash-kernel fwupd 'linux-image-*' 'grub-*' 2>/dev/null | awk '\$2 ~ /^i/ {print \$1}' | tr '\n' ' '" || true)"
  [ -z "$inst" ] || warn "forbidden packages ALREADY installed on the tablet: $inst (pins do not remove them; decide separately)"
  if [ "$have" = "$want" ]; then info "already installed and identical to the overlay"; return 0; fi
  info "files differ or are missing: will install them"
  rroot "
umask 022
printf %s $(base64 -w0 < "$OVL/$p") | base64 -d > /$p.q706f-new && mv -f /$p.q706f-new /$p
printf %s $(base64 -w0 < "$OVL/$c") | base64 -d > /$c.q706f-new && mv -f /$c.q706f-new /$c
chmod 0644 /$p /$c
apt-cache policy qbootctl | grep -q 'Candidate: (none)' && echo '   check: qbootctl candidate (none)'
apt-config dump APT::Install-Recommends | grep -q '\"false\"' && echo '   check: Install-Recommends false'" \
    "install -m 0644 scripts/desktop/overlay/$p -> /$p
install -m 0644 scripts/desktop/overlay/$c -> /$c
then check: apt-cache policy qbootctl (Candidate: none), apt-config dump APT::Install-Recommends"
  revert "sudo rm /$p /$c"
}

# -------------------------------------------------------------------- --ssh-keys-only
DROPIN=/etc/ssh/sshd_config.d/10-q706f-keys-only.conf
key_login() {  # a fresh connection that may only use the given key
  timeout --foreground 20 ssh "${SSHO[@]}" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none \
    -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o IdentitiesOnly=yes -i "${KEY%.pub}" "$HOST" true 2>/dev/null
}
step_ssh() {
  say "ssh: key login only (E2)"
  if [ -z "$KEY" ]; then
    local f
    for f in $(ssh -G "$HOST" 2>/dev/null | awk '$1=="identityfile"{print $2}' | sed "s|^~|$HOME|"); do
      [ -f "$f.pub" ] && { KEY="$f.pub"; break; }
    done
  fi
  [ -n "$KEY" ] && [ -f "$KEY" ] || die "no public key found: create one (ssh-keygen -t ed25519) or pass --key FILE.pub"
  [ -f "${KEY%.pub}" ] || die "private key ${KEY%.pub} not found next to $KEY"
  info "PC key: $KEY ($(ssh-keygen -lf "$KEY" | awk '{print $1, $2, $NF}'))"
  local ok=0; key_login && ok=1
  if [ "$ok" = 0 ]; then
    info "key login does not work yet: ssh-copy-id will install the key (the tablet password is typed by you at ssh's prompt)"
    if [ "$APPLY" = 1 ]; then
      ssh-copy-id -i "$KEY" "${SSHO[@]}" "$HOST" || die "ssh-copy-id failed; nothing else changed"
      key_login || die "key login still fails in a new connection; sshd NOT changed"
    else
      info "[dry-run] would run: ssh-copy-id -i $KEY $HOST"
    fi
  fi
  [ "$APPLY" = 0 ] || info "verified: a separate connection logs in with $KEY only"
  local cur; cur="$(ru "test -f $DROPIN && cat $DROPIN" 10 || true)"
  if printf '%s' "$cur" | grep -q '^PasswordAuthentication no'; then info "drop-in already present"; fi
  [ "$APPLY" = 1 ] || [ "$ok" = 1 ] || info "(sshd would be changed only after the key login check passes)"
  rroot "
cat > $DROPIN.q706f-new <<'EOF'
# q706f-secure.sh --ssh-keys-only: key login only. First match wins in sshd, and
# sshd_config includes sshd_config.d/*.conf at its top, so 10- precedes other drop-ins.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
chmod 0644 $DROPIN.q706f-new && mv -f $DROPIN.q706f-new $DROPIN
if ! sshd -t; then rm -f $DROPIN; echo 'sshd -t failed: drop-in removed, nothing changed'; exit 1; fi
sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' | sed 's/^/   effective: /'
if systemctl is-active -q ssh.service; then systemctl reload ssh.service; fi"
  if [ "$APPLY" = 1 ]; then
    key_login && info "after the change: key login works in a new connection" \
      || warn "key login FAILED after the change: keep this session open; revert below (or at the tablet's terminal)"
    local methods; methods="$(timeout 20 ssh "${SSHO[@]}" -o BatchMode=yes -o ControlPath=none -o PubkeyAuthentication=no \
      -o PreferredAuthentications=password,keyboard-interactive "$HOST" true 2>&1 | grep -o 'Permission denied ([^)]*)' || true)"
    info "server answer without a key: ${methods:-?} (expected: publickey only)"
    case "$methods" in *password*|*keyboard*) warn "password methods are still offered: check other sshd_config.d files" ;; esac
  fi
  revert "ssh $HOST 'sudo rm $DROPIN && sudo systemctl reload ssh' (or the same at the tablet's terminal)"
}

# ------------------------------------------------------------------- --regen-hostkeys
step_hostkeys() {
  say "ssh host keys: regenerate (E2)"
  info "current fingerprints on the tablet:"
  ru 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done' 10 | sed 's/^/     /' || true
  # Old image trees on the PC contained host keys: a tablet installed from one shares them.
  local cur shared=""; cur="$(ru 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done' 10 | awk '{print $2}' || true)"
  local f
  for f in "$ROOT"/out/desktop/*/etc/ssh/ssh_host_*_key.pub; do
    [ -r "$f" ] || continue
    printf '%s\n' "$cur" | grep -qxF "$(ssh-keygen -lf "$f" | awk '{print $2}')" && shared="$shared ${f#"$ROOT"/}"
  done
  [ -z "$shared" ] && info "no key shared with a build tree under out/desktop" || warn "keys shared with:$shared"
  rroot "
T=\$(mktemp -d /etc/ssh/q706f-new.XXXXXX)
mkdir -p \"\$T/etc/ssh\"
ssh-keygen -A -f \"\$T\"
test -s \"\$T/etc/ssh/ssh_host_ed25519_key\"
B=/root/q706f-old-hostkeys-$STAMP
mkdir -p -m 700 \"\$B\"
cp -a /etc/ssh/ssh_host_* \"\$B\"/ 2>/dev/null || true
# Any failure from here on puts the old keys back, so sshd is never left without keys.
keys_ok=0
trap '[ \$keys_ok = 1 ] || { cp -a \"\$B\"/ssh_host_* /etc/ssh/ 2>/dev/null; rm -rf \"\$T\"; echo \"   FAILED: old host keys restored\"; }' EXIT
for f in \"\$T\"/etc/ssh/ssh_host_*; do mv -f \"\$f\" /etc/ssh/; done
rm -f /etc/ssh/ssh_host_dsa_key /etc/ssh/ssh_host_dsa_key.pub
rm -rf \"\$T\"
sshd -t
if systemctl is-active -q ssh.service; then systemctl reload ssh.service; fi
echo '   NEW fingerprints:'
for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"\$f\" | sed 's/^/     /'; done
echo \"   old keys kept in \$B (root only)\"
keys_ok=1"
  # PC side: forget the old key under every name this tablet is reached by.
  local names=() a h
  for a in "$HOST" "${ALIASES[@]}"; do
    names+=("$a")
    h="$(ssh -G "$a" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"
    [ -n "$h" ] && names+=("$h")
  done
  names+=("$TABLET_USB_IP")
  for a in $(printf '%s\n' "${names[@]}" | sort -u); do
    if ssh-keygen -F "$a" >/dev/null 2>&1; then
      if [ "$APPLY" = 1 ]; then ssh-keygen -R "$a" >/dev/null 2>&1 && info "known_hosts: removed $a (backup ~/.ssh/known_hosts.old)"
      else info "[dry-run] would run: ssh-keygen -R $a"; fi
    fi
  done
  if [ "$APPLY" = 1 ]; then
    timeout 20 ssh "${SSHO[@]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
      -o ControlPath=none "$HOST" true && info "new host key recorded in ~/.ssh/known_hosts for $HOST; compare with the NEW fingerprints above:"
    ssh-keygen -lF "$(ssh -G "$HOST" | awk '$1=="hostname"{print $2; exit}')" 2>/dev/null | grep -v '^#' | sed 's/^/     /' || true
  fi
  info "~/.ssh/config: the q706f aliases use StrictHostKeyChecking no / UserKnownHostsFile /dev/null;"
  info "consider StrictHostKeyChecking accept-new and a real known_hosts (not changed by this script)."
  revert "on the tablet: sudo cp -a /root/q706f-old-hostkeys-$STAMP/ssh_host_* /etc/ssh/ && sudo systemctl reload ssh"
}

# ------------------------------------------------------------------- --no-unsafe-mode
UNSAFE='$HOME/.config/systemd/user/org.gnome.Shell@.service.d/unsafe.conf'
step_unsafe() {
  say "gnome-shell --unsafe-mode off (E6, owner choice)"
  local st; st="$(ru "test -f $UNSAFE && echo present || echo absent; grep -rls -- --unsafe-mode \$HOME/.config/systemd/user /etc/systemd/user 2>/dev/null | grep -v '\\.disabled\$' || true" 10 || true)"
  info "state: $(printf '%s' "$st" | tr '\n' ' ')"
  [ "$REACH" = 0 ] && st="present (tablet not reachable: plan only)"
  case "$st" in present*) ;; *) info "nothing to do"; return 0 ;; esac
  info "effect: at the next login; gnome-screenshot over ssh stops working (debugging only)"
  if [ "$APPLY" = 1 ]; then
    ru "mv -f $UNSAFE $UNSAFE.disabled && systemctl --user daemon-reload && echo '   disabled (renamed to unsafe.conf.disabled)'" 15
  else info "[dry-run] would rename $UNSAFE to unsafe.conf.disabled"; fi
  revert "ssh $HOST 'mv $UNSAFE.disabled $UNSAFE && systemctl --user daemon-reload', then log in again"
}

# ---------------------------------------------------------------------- --screen-lock
step_lock() {
  say "screen lock on (E4, owner choice)"
  local st; st="$(ru 'gsettings get org.gnome.desktop.screensaver lock-enabled; gsettings get org.gnome.desktop.screensaver ubuntu-lock-on-suspend 2>/dev/null' 10 | tr '\n' ' ' || true)"
  info "now: lock-enabled ubuntu-lock-on-suspend = ${st:-?}"
  case "$st" in "true true"*) info "nothing to do"; return 0 ;; esac
  [ "$REACH" = 1 ] || info "(tablet not reachable: plan only)"
  warn "unlocking needs the account password and a working on-screen keyboard on the lock screen:"
  warn "test it with the pogo keyboard detached (DE-FACUT E3) before relying on it."
  if [ "$APPLY" = 1 ]; then
    confirm lock "Screen lock: the owner knows the password and the OSK on the lock screen was checked." || { info "skipped"; return 0; }
    ru 'gsettings set org.gnome.desktop.screensaver lock-enabled true
        gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend true 2>/dev/null || true
        gsettings set org.gnome.desktop.screensaver lock-delay "uint32 0"
        echo "   lock-enabled=$(gsettings get org.gnome.desktop.screensaver lock-enabled)"' 15
  else info "[dry-run] would set lock-enabled=true, ubuntu-lock-on-suspend=true, lock-delay=0 (user gsettings)"; fi
  revert "ssh $HOST 'gsettings reset org.gnome.desktop.screensaver lock-enabled; gsettings reset org.gnome.desktop.screensaver ubuntu-lock-on-suspend; gsettings reset org.gnome.desktop.screensaver lock-delay'"
}

# --------------------------------------------------------------------- --no-autologin
step_autologin() {
  say "GDM autologin off (E4, owner choice)"
  local st; st="$(ru "grep -E '^[[:space:]]*(AutomaticLogin|TimedLogin)' /etc/gdm3/custom.conf 2>/dev/null" 10 || true)"
  info "now: ${st:-no active AutomaticLogin/TimedLogin lines}"
  [ "$REACH" = 0 ] && { st="AutomaticLoginEnable=true"; info "(tablet not reachable: plan only)"; }
  printf '%s' "$st" | grep -qiE 'AutomaticLoginEnable[[:space:]]*=[[:space:]]*true|TimedLoginEnable[[:space:]]*=[[:space:]]*true' \
    || { info "nothing to do"; return 0; }
  warn "after this the tablet stops at the GDM login screen. Precondition (DE-FACUT E3): the on-screen"
  warn "keyboard on the login screen was tested with the pogo keyboard DETACHED. ssh stays available."
  if [ "$APPLY" = 1 ]; then
    confirm tested "Autologin: the GDM on-screen keyboard was tested and the owner knows the password." || { info "skipped"; return 0; }
  fi
  rroot "
cp -a /etc/gdm3/custom.conf /etc/gdm3/custom.conf.q706f-$STAMP
sed -i -E 's/^([[:space:]]*(AutomaticLogin|AutomaticLoginEnable|TimedLogin|TimedLoginEnable|TimedLoginDelay)[[:space:]]*=.*)\$/#\\1/' /etc/gdm3/custom.conf
grep -nE 'AutomaticLogin|TimedLogin' /etc/gdm3/custom.conf | sed 's/^/   now: /'
echo '   effective at the next boot (GDM is not restarted: that would end the session)'"
  revert "on the tablet: sudo cp -a /etc/gdm3/custom.conf.q706f-$STAMP /etc/gdm3/custom.conf"
}

# --------------------------------------------------------------------- --sudo-password
step_sudo() {
  say "sudo asks for the password (E7, owner choice)"
  if [ "$REACH" = 0 ]; then info "(tablet not reachable: plan only)"; SUDO_N=1; fi
  if [ "$SUDO_N" = 0 ]; then info "sudo already asks for a password (no NOPASSWD rule reaches $RUSER)"; return 0; fi
  ru 'sudo -n -l 2>/dev/null | grep -i nopasswd | sed "s/^/   now: /"' 10 || true
  warn "afterwards kernel-cycle.sh, setup-sensors.sh, install.sh post"
  warn "and q706f-backup-rootimg.sh (full mode) no longer run unattended; the owner types the password."
  if [ "$APPLY" = 1 ]; then
    confirm sudo "sudo: the owner has set and knows the password of $RUSER (passwd)." || { info "skipped"; return 0; }
  fi
  rroot "
id -nG $RUSER | tr ' ' '\n' | grep -qx sudo || { echo '$RUSER is not in group sudo: refusing (would lose root)'; exit 1; }
grep -qE '^%sudo[[:space:]]+ALL=\\(ALL(:ALL)?\\)[[:space:]]+ALL' /etc/sudoers || { echo 'no %sudo rule in /etc/sudoers: refusing'; exit 1; }
D=/root/q706f-sudoers-disabled-$STAMP
for f in /etc/sudoers.d/*; do
  [ -f \"\$f\" ] || continue
  if grep -vE '^[[:space:]]*#' \"\$f\" | grep -q NOPASSWD; then mkdir -p -m 700 \"\$D\"; mv \"\$f\" \"\$D\"/; echo \"   moved \$f -> \$D/\"; fi
done
visudo -c >/dev/null && echo '   visudo -c: OK'
if grep -vE '^[[:space:]]*#' /etc/sudoers | grep -q NOPASSWD; then echo '   NOTE: /etc/sudoers itself has a NOPASSWD line: not changed, edit with visudo'; fi"
  if [ "$APPLY" = 1 ]; then
    ru 'sudo -n true' 10 2>/dev/null && warn "sudo -n still works: another rule remains" || info "checked: sudo now asks for a password"
  fi
  revert "at the tablet: sudo mv /root/q706f-sudoers-disabled-$STAMP/* /etc/sudoers.d/ (with the password)"
}

# ------------------------------------------------------------------ --keyring-encrypt
step_keyring() {
  say "keyring (E5, owner choice) - instructions only, nothing is changed"
  cat <<EOF
   The bring-up tablet has an UNENCRYPTED default keyring (~/.local/share/keyrings/
   Default_keyring.keyring) holding the RDP user/password of the PC. To move to an
   encrypted keyring unlocked at login by PAM (needs autologin OFF, see --no-autologin):
   1. Reboot, log in at GDM with the password. GNOME creates/unlocks the "login" keyring.
   2. In a terminal ON THE TABLET, note what is stored (do not paste it anywhere):
        secret-tool lookup service q706f-pc-rdp field user
   3. Remove the plaintext keyring and its default marker, then log out and in again:
        rm ~/.local/share/keyrings/Default_keyring.keyring ~/.local/share/keyrings/default
   4. Store the two secrets again; secret-tool asks for the value, you type it:
        secret-tool store --label='PC remote desktop user' service q706f-pc-rdp field user
        secret-tool store --label='PC remote desktop password' service q706f-pc-rdp field password
   5. Set FINGERPRINT=... in ~/.config/q706f-remote-pc.conf (from 'grdctl status' on the PC),
      so the RDP client stops trusting on first use.
   With autologin left ON, a login keyring cannot be unlocked automatically; then the
   alternatives are: no stored RDP password (typed each time) or a low-privilege RDP account.
EOF
}

[ "$DO_APT" = 1 ] && step_apt
[ "$DO_SSH" = 1 ] && step_ssh
[ "$DO_HOSTKEYS" = 1 ] && step_hostkeys
[ "$DO_UNSAFE" = 1 ] && step_unsafe
[ "$DO_LOCK" = 1 ] && step_lock
[ "$DO_AUTOLOGIN" = 1 ] && step_autologin
[ "$DO_KEYRING" = 1 ] && step_keyring
[ "$DO_SUDO" = 1 ] && step_sudo

say "password of '$RUSER' (E1) - done by the owner only"
info "the default password is public. The owner changes it, typing it himself:"
info "  at the tablet: open a terminal and run  passwd"
info "  or from the PC:  ssh -t $HOST passwd"
info "(the login keyring follows the new password when it is changed while logged in)"
[ "$APPLY" = 1 ] || printf '\nDry run finished: nothing was changed. Re-run with --apply to make the changes.\n'
