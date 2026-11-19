#!/usr/bin/env bash
#
# claude-desktop-up.sh - installa e tiene aggiornato Claude Desktop su Fedora, senza COPR.
#
# Usa build-official.sh (stessa cartella) per generare l'RPM dal .deb ufficiale di Anthropic,
# verificato contro l'indice apt firmato. Niente viene ridistribuito: ogni PC costruisce il suo RPM.
#
#   sudo ./claude-desktop-up.sh --install     # prima volta su ogni PC: dipendenze, timer giornaliero, primo build
#   sudo claude-desktop-up                    # aggiorna adesso se c'è una versione nuova
#   sudo claude-desktop-up --check            # dice solo se c'è una versione nuova (exit 2 = update disponibile)
#   sudo claude-desktop-up --force            # ricostruisce e reinstalla anche se è già aggiornato
#   sudo claude-desktop-up --uninstall        # toglie script e timer, Claude Desktop resta installato
#
set -euo pipefail

NAME="claude-desktop-up"
SBIN="/usr/local/sbin/$NAME"                       # copia dello script usata dal timer
LIBEXEC="/usr/local/libexec/$NAME"                 # copia di build-official.sh usata dal timer
UNIT_DIR="/etc/systemd/system"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BUILD_DEPS=(rpm-build binutils file xz curl gnupg2) # quello che serve a build-official.sh

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "va lanciato come root (installa un RPM): sudo $0 $*"

# Preferisce build-official.sh accanto allo script (clone del fork), altrimenti la copia installata.
if [ -x "$HERE/build-official.sh" ]; then BUILDER="$HERE/build-official.sh"
else BUILDER="$LIBEXEC/build-official.sh"; fi

export HOME="${HOME:-/root}"                       # rpmbuild vuole una HOME, systemd non sempre la dà
export TMPDIR=/var/tmp                             # il payload scompattato è ~700 MB: /tmp spesso è tmpfs e non basta
OUT=""                                             # cartella temporanea del build
trap '[ -n "$OUT" ] && rm -rf "$OUT"' EXIT         # EXIT e non RETURN: die() esce dallo script e va pulito lo stesso

# ------------------------------------------------------------------ update ---
update() {                                         # $1 = check | normal | force
    [ -x "$BUILDER" ] || die "manca build-official.sh ($BUILDER)"

    local latest version sha file installed
    latest="$("$BUILDER" --print-latest)" || die "indice apt firmato di Anthropic non leggibile o non verificato"
    read -r version sha file <<<"$latest"
    [ -n "${sha:-}" ] || die "output inatteso da --print-latest: $latest"
    version="${version//-/.}"                      # build-official.sh mappa '-' in '.' (RPM non ammette '-' nella Version)
    installed=""                                   # rpm -q stampa "not installed" su stdout: non usarlo come versione
    rpm -q claude-desktop >/dev/null 2>&1 && installed="$(rpm -q --qf '%{VERSION}' claude-desktop)"

    if [ "$installed" = "$version" ] && [ "$1" != force ]; then
        log "aggiornato: claude-desktop $installed è l'ultima versione"
        return 0
    fi
    if [ "$1" = check ]; then
        log "update disponibile: installata ${installed:-nessuna}, upstream $version"
        return 2
    fi

    log "build di $version (installata: ${installed:-nessuna}), scarica ~175 MB"
    OUT="$(mktemp -d /var/tmp/$NAME.XXXXXX)"
    # --expect-sha256: costruisce esattamente il .deb appena verificato; se l'indice cambia nel frattempo si ferma.
    "$BUILDER" --outdir "$OUT" --expect-sha256 "$sha" || die "build-official.sh fallito"

    local rpm_file; rpm_file="$(find "$OUT" -maxdepth 1 -name 'claude-desktop-*.rpm' -print -quit)"
    [ -n "$rpm_file" ] || die "build riuscito ma nessun RPM prodotto"
    if [ "$installed" = "$version" ]; then dnf reinstall -y "$rpm_file"   # stessa versione (--force): install sarebbe un no-op
    else dnf install -y "$rpm_file"; fi                                   # Obsoletes nello spec sostituisce la vecchia
    log "installato $(rpm -q claude-desktop) (se Claude è aperto, riavvialo)"
}

# ----------------------------------------------------------------- install ---
install_self() {
    [ -x "$HERE/build-official.sh" ] || die "lancia --install dal clone del repo (serve build-official.sh accanto)"

    # Vecchio setup COPR di dewzor, PRIMA di qualsiasi dnf: su F45 il suo .repo dà 404 e fa fallire dnf install.
    rm -fv /etc/yum.repos.d/_copr:*:dewzor:claude-desktop.repo
    if rpm -q claude-desktop-builder >/dev/null 2>&1; then  # ha un suo timer che farebbe lo stesso lavoro
        log "rimuovo claude-desktop-builder (COPR)"; dnf remove -y claude-desktop-builder
    fi

    log "dipendenze di build"
    dnf install -y "${BUILD_DEPS[@]}"

    log "copio script in $SBIN e $LIBEXEC"
    install -Dm0755 "$HERE/claude-desktop-up.sh" "$SBIN"
    install -Dm0755 "$HERE/build-official.sh" "$LIBEXEC/build-official.sh"

    cat > "$UNIT_DIR/$NAME.service" <<EOF
[Unit]
Description=Aggiorna Claude Desktop dal .deb ufficiale di Anthropic
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SBIN
TimeoutStartSec=3600
# Gira in background mentre lavori: priorità CPU e I/O minime.
Nice=19
CPUSchedulingPolicy=batch
IOSchedulingClass=idle
EOF
    cat > "$UNIT_DIR/$NAME.timer" <<EOF
[Unit]
Description=Controllo giornaliero nuova versione di Claude Desktop

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true    # in un container senza systemd fallisce: non è un errore
    systemctl enable --now "$NAME.timer" 2>/dev/null \
        || systemctl enable "$NAME.timer" 2>/dev/null \
        || log "attenzione: timer non attivato (systemd non disponibile?)"
    log "timer attivo: systemctl list-timers $NAME.timer | log: journalctl -u $NAME"

    BUILDER="$LIBEXEC/build-official.sh"           # da qui in poi usa la copia installata, come farà il timer
    update normal
}

uninstall_self() {
    systemctl disable --now "$NAME.timer" 2>/dev/null || true
    rm -fv "$UNIT_DIR/$NAME.service" "$UNIT_DIR/$NAME.timer" "$SBIN"
    rm -rfv "$LIBEXEC"
    systemctl daemon-reload 2>/dev/null || true
    log "rimosso; Claude Desktop resta installato (sudo dnf remove claude-desktop per toglierlo)"
}

case "${1:-}" in
    "")          update normal ;;
    --check)     update check ;;
    --force)     update force ;;
    --install)   install_self ;;
    --uninstall) uninstall_self ;;
    -h|--help)   sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)           die "opzione sconosciuta: $1 (prova --help)" ;;
esac
