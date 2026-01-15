

# ---------------------------------------------
# colors for reference
# ---------------------------------------------
BLUE='\[\033[0;34m\]'
CYAN='\[\033[0;36m\]'
GREEN='\[\033[0;32m\]'
RESET='\[\033[0m\]'

# ---------------------------------------------
# customized prompt
# ---------------------------------------------
PS1="${BLUE}\u@\h${RESET} \w \$ "


# ---------------------------------------------
# ls customization
# ---------------------------------------------
LS_OPTIONS='--color=auto --group-directories-first'
alias ls="ls -lh $LS_OPTIONS"
alias ll="ls -lah $LS_OPTIONS"
alias la="ls -A $LS_OPTIONS"

# ---------------------------------------------
# uv shell completion
# ---------------------------------------------
eval "$(uv generate-shell-completion bash)"
eval "$(uvx --generate-shell-completion bash)"
