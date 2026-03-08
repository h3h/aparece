# zshrc - Bradford Fults

# zsh shell options
setopt AUTO_CD
setopt NO_CASE_GLOB
set -o emacs

# Functions & autocompletions paths
[[ -d "$HOME/.zshfuncs" ]] && fpath+="~/.zshfuncs"

# Load custom aliases
[[ -f $HOME/.aliases ]] && source "$HOME/.aliases"

# Zinit
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
[[ ! -d $ZINIT_HOME ]] && mkdir -p "$(dirname $ZINIT_HOME)"
[[ ! -d $ZINIT_HOME/.git ]] && git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
source "${ZINIT_HOME}/zinit.zsh"

# Zinit plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions
autoload -Uz compinit && compinit

# Prompt & theme from oh-my-posh
if [[ -x $(which oh-my-posh) ]]; then
  eval "$(oh-my-posh init zsh --config ~/.posh.toml)"
fi

# Replaced cd command with zoxide
[[ -x $(which zoxide) ]] && eval "$(zoxide init --cmd cd zsh)"

# Editors
export EDITOR="vim"
export GIT_EDITOR=$EDITOR
export BUNDLER_EDITOR=$EDITOR

# Keybindings
bindkey $'^[[A' up-line-or-search
bindkey $'^[[B' down-line-or-search
bindkey $'^[b'  backward-word
bindkey $'^[f'  forward-word

# Change zsh's idea of what chars constitute a word
# specifically, remove: -=/;{} so forward/backward-word stop on them
export WORDCHARS="*?_.[]~&!#$%^()<>"

# Attach gpg to current tty
export GPG_TTY=$(tty)

# Direnv
if [[ -x $(which direnv) ]]; then
  direnv_color="$(printf "\033[38;5;8m")"
  direnv_reset="$(printf "\033[0m")"
  export DIRENV_LOG_FORMAT="${direnv_color}direnv: %s${direnv_reset}"
  eval "$(direnv hook zsh)"
fi
