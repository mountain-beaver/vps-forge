# shellcheck shell=bash
# /etc/profile.d/vps-forge.sh: shell niceties (vps-forge). Interactive bash only.
# Debian/Ubuntu ~/.bashrc sets its own PS1 after profile.d runs, so also add this line
# at the END of the admin user's ~/.bashrc:  [ -r /etc/profile.d/vps-forge.sh ] && . /etc/profile.d/vps-forge.sh
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

HISTSIZE=50000
HISTFILESIZE=100000
HISTTIMEFORMAT='%F %T  '
HISTCONTROL=ignoreboth
shopt -s histappend checkwinsize

# Host in red when the hostname contains "prod", green otherwise; user red when root.
case "$(hostname)" in *prod*) __vf_h='\[\e[1;31m\]' ;; *) __vf_h='\[\e[1;32m\]' ;; esac
if [ "$(id -u)" -eq 0 ]; then __vf_u='\[\e[1;31m\]'; else __vf_u='\[\e[1;36m\]'; fi
PS1="${__vf_u}\u\[\e[0m\]@${__vf_h}\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\\$ "
unset __vf_h __vf_u

alias ll='ls -alh --color=auto'
alias ports='sudo ss -tulpn'
alias fw='sudo ufw status numbered'
alias logs='journalctl -e'
alias failed='systemctl --failed'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
