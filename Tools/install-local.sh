#!/bin/bash
# Development installation only; never source user configuration in this process.
set -euo pipefail
export LC_ALL=C

fail() {
    printf 'install-local: %s\n' "$1" >&2
    exit 1
}

validate_path() {
    [[ "$1" = /* ]] || fail "Expected an absolute path: $1"
    [[ ${#1} -le 1024 ]] || fail 'Path exceeds 1024 bytes.'
    case "$1" in
        *:*|*[[:cntrl:]]*) fail 'Paths cannot contain colons or control characters.' ;;
    esac
}

quote_path() {
    local value=$1
    if [[ "$shell" = fish ]]; then
        value=${value//\\/\\\\}
        value=${value//\'/\\\'}
    else
        value=${value//\'/\'\\\'\'}
    fi
    printf "'%s'" "$value"
}

bash_login_profile() {
    local file
    # Creating .bash_profile would hide an existing .bash_login or .profile.
    for file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [[ -e "$file" || -L "$file" ]]; then
            printf '%s' "$file"
            return
        fi
    done
    printf '%s' "$HOME/.bash_profile"
}

check_profile() {
    validate_path "$1"
    if [[ -e "$1" || -L "$1" ]]; then
        [[ -f "$1" && -r "$1" && -w "$1" ]] || fail "Not a writable regular profile: $1"
        [[ $(wc -c < "$1") -le 1048576 ]] || fail "Profile exceeds 1 MiB: $1"
    fi
}

append_path() {
    local profile=$1 current_bytes=0 added_bytes
    if [[ -f "$profile" ]] && grep -Fqx -- "$path_line" "$profile"; then
        return
    fi
    [[ ! -f "$profile" ]] || current_bytes=$(wc -c < "$profile")
    added_bytes=$(printf '\n# ControlKit local development binary\n%s\n' "$path_line" | wc -c)
    [[ $((current_bytes + added_bytes)) -le 1048576 ]] ||
        fail "Profile would exceed 1 MiB: $profile"
    install -d "$(dirname "$profile")"
    # A leading newline also handles a user's file without a final newline. Append, never replace.
    printf '\n# ControlKit local development binary\n%s\n' "$path_line" >> "$profile"
    printf 'Configured PATH in %s\n' "$profile"
}

main() {
    if [[ ${1:-} = --help || ${2:-} = --help ]]; then
        printf '%s\n' \
            'Usage: bash Tools/install-local.sh <built-ControlKit> [prefix]' \
            'Default prefix: $HOME/.local. Installs bin/ControlKit, helper sources, and PATH setup.' \
            'SHELL selects zsh, bash, or fish 3.2+. Honors ZDOTDIR and XDG_CONFIG_HOME.' \
            'Existing profile content is preserved. Open a new shell afterward.' \
            'A child process cannot update the PATH of the shell that invoked it.'
        return
    fi
    [[ $# -ge 1 && $# -le 2 ]] || fail 'Expected a built binary and optional prefix; see --help.'
    [[ -f "$1" && -x "$1" ]] || fail "Not an executable file: $1"
    [[ -n ${HOME:-} ]] || fail 'HOME must be set.'
    validate_path "$HOME"
    local binary=$1 prefix=${2:-"$HOME/.local"} bin quoted share
    local profiles=()
    shell=${SHELL:-}
    shell=${shell##*/}
    case "$shell" in
        zsh) profiles=("${ZDOTDIR:-$HOME}/.zshrc") ;;
        bash) profiles=("$HOME/.bashrc" "$(bash_login_profile)") ;;
        fish) profiles=("${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/controlkit.fish") ;;
        *) fail 'Set SHELL to your zsh, bash, or fish executable before installing.' ;;
    esac
    [[ "$prefix" = /* ]] || prefix="$PWD/$prefix"
    validate_path "$prefix"
    local profile
    for profile in "${profiles[@]}"; do check_profile "$profile"; done
    umask 077
    install -d "$prefix/bin"
    bin=$(cd "$prefix/bin" && pwd -P)
    validate_path "$bin"
    [[ ! -L "$bin/ControlKit" ]] || fail "Refusing to overwrite a symlink: $bin/ControlKit"
    share="$prefix/share/ControlKit"
    [[ ! -L "$share" ]] || fail "Refusing to replace a symlink: $share"
    if [[ -e "$share" ]]; then
        [[ -d "$share" ]] || fail "Not a helper-source directory: $share"
        [[ -z $(find "$share" -type l -print -quit) ]] ||
            fail "Helper-source tree contains a symlink: $share"
    fi
    bash "$(dirname "${BASH_SOURCE[0]}")/package-release.sh" "$binary" "$prefix"
    quoted=$(quote_path "$bin")
    if [[ "$shell" = fish ]]; then
        path_line="fish_add_path --path --prepend $quoted"
    else
        printf -v path_line \
            'case ":${PATH-}:" in *:%s:*) ;; *) export PATH=%s"${PATH:+:$PATH}" ;; esac' \
            "$quoted" "$quoted"
    fi
    for profile in "${profiles[@]}"; do append_path "$profile"; done
    printf 'Installed %s/ControlKit\nOpen a new shell, or run this in the current shell:\n' "$bin"
    printf '  %s\n' "$path_line"
}

shell=''
path_line=''
main "$@"
