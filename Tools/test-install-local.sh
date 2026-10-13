#!/bin/bash
set -euo pipefail

if [[ ${1:-} = --help ]]; then
    printf 'Usage: bash Tools/test-install-local.sh <built-ControlKit>\nUses temporary homes only.\n'
    exit 0
fi
[[ $# -eq 1 ]] || { printf 'Expected a built binary; see --help.\n' >&2; exit 2; }
binary=$1
mkdir -p .build
runtime=$(mktemp -d "$PWD/.build/install-local-test.XXXXXX")
trap 'rm -rf "$runtime"' EXIT
unset ZDOTDIR XDG_CONFIG_HOME BASH_ENV ENV

run_install() {
    if ! bash Tools/install-local.sh "$@" > "$runtime/install.log" 2>&1; then
        cat "$runtime/install.log"
        return 1
    fi
    grep -Fq 'Open a new shell' "$runtime/install.log"
}

verify_lookup() {
    local interpreter=$1 profile=$2 bin=$3 actual expected
    if [[ "$interpreter" = */fish ]]; then
        actual=$(PATH=/usr/bin:/bin "$interpreter" --no-config -c \
            'source $argv[1]; source $argv[1]; ControlKit --help >/dev/null; command -v ControlKit
             string join : $PATH' "$profile")
    else
        local flags=()
        case "$interpreter" in */zsh) flags=(-f) ;; *) flags=(--noprofile --norc) ;; esac
        actual=$(PATH=/usr/bin:/bin "$interpreter" "${flags[@]}" -c \
            '. "$1"; . "$1"; ControlKit --help >/dev/null; command -v ControlKit; printf "%s\n" "$PATH"' \
            test "$profile")
    fi
    expected=$(printf '%s/ControlKit\n%s:/usr/bin:/bin' "$bin" "$bin")
    [[ "$actual" = "$expected" ]] || {
        printf 'PATH lookup or duplicate-entry check failed for %s\n' "$interpreter" >&2
        exit 1
    }
}

test_shell() {
    local interpreter=$1 login_file=${2:-.bash_profile} home bin profile
    home="$runtime/home ${interpreter##*/} $login_file café '\$ [x]\\"
    mkdir -p "$home"
    export HOME="$home" SHELL="$interpreter"
    case "$interpreter" in
        */zsh)
            export ZDOTDIR="$home/dotfiles"
            mkdir -p "$ZDOTDIR"
            profile="$ZDOTDIR/.zshrc"
            ;;
        */fish)
            export XDG_CONFIG_HOME="$home/settings"
            profile="$XDG_CONFIG_HOME/fish/conf.d/controlkit.fish"
            mkdir -p "$(dirname "$profile")"
            ;;
        *) profile="$home/$login_file" ;;
    esac
    printf '# Keep existing configuration (no final newline)' > "$profile"
    run_install "$binary"
    grep -Fqx '# Keep existing configuration (no final newline)' "$profile"
    cp "$profile" "$runtime/once"
    run_install "$binary"
    cmp "$profile" "$runtime/once"
    bin=$(cd "$HOME/.local/bin" && pwd -P)
    verify_lookup "$interpreter" "$profile" "$bin"
    if [[ "$interpreter" = */bash ]]; then
        verify_lookup "$interpreter" "$HOME/.bashrc" "$bin"
        [[ "$login_file" = .bash_profile || ! -e "$HOME/.bash_profile" ]]
    fi
    unset ZDOTDIR XDG_CONFIG_HOME
    printf 'Install and PATH checks passed: %s %s\n' "$interpreter" "$login_file"
}

for login_file in .bash_profile .bash_login .profile; do
    test_shell /bin/bash "$login_file"
done
test_shell /bin/zsh
if command -v fish >/dev/null 2>&1; then
    test_shell "$(command -v fish)"
else
    printf 'Fish execution check skipped: fish is not installed.\n'
fi
export HOME="$runtime/new-bash-home" SHELL=/bin/bash
mkdir -p "$HOME"
run_install "$binary"
verify_lookup /bin/bash "$HOME/.bash_profile" "$HOME/.local/bin"
verify_lookup /bin/bash "$HOME/.bashrc" "$HOME/.local/bin"
export HOME="$runtime/custom-home" SHELL=/bin/zsh
mkdir -p "$HOME"
printf '# Keep symlinked configuration\n' > "$HOME/config"
ln -s "$HOME/config" "$HOME/.zshrc"
run_install "$binary" "$runtime/custom prefix"
[[ -L "$HOME/.zshrc" ]]
[[ -f "$runtime/custom prefix/share/ControlKit/Helper/RuntimeTests.swift" ]]
[[ -f "$runtime/custom prefix/share/ControlKit/Sources/ControlKitWire/JSONShape.swift" ]]
[[ -f "$runtime/custom prefix/share/ControlKit/skills/ios-use-controlkit/SKILL.md" ]]
installed_build=$(cat "$runtime/custom prefix/share/ControlKit/build-info")
[[ -n "$installed_build" ]]
[[ $("$runtime/custom prefix/bin/ControlKit" --version) = *"($installed_build)" ]]
grep -Fqx '# Keep symlinked configuration' "$HOME/config"
verify_lookup /bin/zsh "$HOME/.zshrc" "$runtime/custom prefix/bin"
export HOME="$runtime/unsupported-home" SHELL=/bin/unsupported
mkdir -p "$HOME"
if bash Tools/install-local.sh "$binary" >"$runtime/error" 2>&1; then
    printf 'Unsupported shell was incorrectly accepted.\n' >&2
    exit 1
fi
[[ ! -e "$HOME/.local" && ! -e "$HOME/.zshrc" ]]
export SHELL=/bin/zsh
if bash Tools/install-local.sh "$binary" "$runtime/invalid:prefix" >"$runtime/error" 2>&1; then
    printf 'Invalid PATH component was incorrectly accepted.\n' >&2
    exit 1
fi
[[ ! -e "$runtime/invalid:prefix" && ! -e "$HOME/.zshrc" ]]
printf 'New-home, symlink, custom-prefix, and invalid-input checks passed.\n'
