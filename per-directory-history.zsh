#!/usr/bin/env zsh
#
# This is a implementation of per directory history for zsh, some
# implementations of which exist in bash[1,2].  It also implements
# a per-directory-history-toggle-history function to change from using the
# directory history to using the global history.  In both cases the history is
# always saved to both the global history and the directory history, so the
# toggle state will not effect the saved histories.  Being able to switch
# between global and directory histories on the fly is a novel feature as far
# as I am aware.
#
#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
#
# HISTORY_BASE a global variable that defines the base directory in which the
# directory histories are stored
#
#-------------------------------------------------------------------------------
# History
#-------------------------------------------------------------------------------
#
# The idea/inspiration for a per directory history is from Stewart MacArthur[1]
# and Dieter[2], the implementation idea is from Bart Schaefer on the the zsh
# mailing list[3].  The implementation is by Jim Hester in September 2012.
#
# [1]: http://www.compbiome.com/2010/07/bash-per-directory-bash-history.html
# [2]: http://dieter.plaetinck.be/per_directory_bash
# [3]: http://www.zsh.org/mla/users/1997/msg00226.html
#
################################################################################
#
# Copyright (c) 2014 Jim Hester
#
# This software is provided 'as-is', without any express or implied warranty.
# In no event will the authors be held liable for any damages arising from the
# use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions:
#
# 1. The origin of this software must not be misrepresented; you must not claim
# that you wrote the original software. If you use this software in a product,
# an acknowledgment in the product documentation would be appreciated but is
# not required.
#
# 2. Altered source versions must be plainly marked as such, and must not be
# misrepresented as being the original software.
#
# 3. This notice may not be removed or altered from any source distribution..
#
################################################################################

#-------------------------------------------------------------------------------
# configuration, the base under which the directory histories are stored
#-------------------------------------------------------------------------------

[[ -z $HISTORY_BASE ]] && HISTORY_BASE="$HOME/.directory_history"
[[ -z $HISTORY_START_WITH_GLOBAL ]] && HISTORY_START_WITH_GLOBAL=false
[[ -z $PER_DIRECTORY_HISTORY_TOGGLE ]] && PER_DIRECTORY_HISTORY_TOGGLE='^G'

#-------------------------------------------------------------------------------
# toggle global/directory history used for searching - ctrl-G by default
#-------------------------------------------------------------------------------

function per-directory-history-toggle-history() {
  if [[ $_per_directory_history_is_global == true ]]; then
    _per-directory-history-set-directory-history
    _per_directory_history_is_global=false
    zle -I
    echo "using local history"
  else
    _per-directory-history-set-global-history
    _per_directory_history_is_global=true
    zle -I
    echo "using global history"
  fi
}

autoload per-directory-history-toggle-history
zle -N per-directory-history-toggle-history
bindkey -M emacs "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history
bindkey -M viins "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history
bindkey -M vicmd "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history
bindkey "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history

#-------------------------------------------------------------------------------
# implementation details
#-------------------------------------------------------------------------------

# Return the history file for a directory in REPLY.
#
# The original layout put a file named "history" below the directory-shaped
# representation of PWD.  That means that a real directory named "history"
# can collide with the history file for its parent.  Keep using the old path
# when it is usable (and, in particular, when it already contains history),
# but use an injective encoded path whenever that layout would collide.  The
# percent sign is escaped first, so the encoding cannot introduce an
# ambiguity; spaces and other characters are consequently safe as well.
function _per-directory-history-file() {
  local directory=${1:A}
  local legacy="$HISTORY_BASE${directory}/history"
  local encoded=${directory//\%/%25}
  encoded=${encoded//\//%2F}
  local encoded_file="$HISTORY_BASE/.history/$encoded"
  local existing_parent=${legacy:h}

  # If an old history file is an ancestor of the legacy parent, mkdir cannot
  # create the legacy path.  Walk to the nearest existing ancestor so this
  # also works for nested paths below a directory named history.
  while [[ ! -e $existing_parent && $existing_parent != ${existing_parent:h} ]]; do
    existing_parent=${existing_parent:h}
  done

  # Once a directory has used the encoded layout, keep using it even if the
  # physical collision later disappears.  If both layouts exist, the encoded
  # file wins so history cannot silently switch locations and orphan data.
  if [[ -f $encoded_file ]]; then
    REPLY=$encoded_file
    return
  fi

  # Existing legacy files are preferred when no encoded history exists.  This
  # avoids silently abandoning a user's existing history on upgrade.
  if [[ -f $legacy && -d ${legacy:h} ]]; then
    REPLY=$legacy
    return
  fi

  # A directory named history needs the encoded layout.  Its parent may have
  # an old history file at exactly the path needed as the child's directory;
  # checking the legacy parent also handles arbitrary nesting of such paths.
  if [[ ${directory:t} == history || -d "$directory/history" ||
        ( -e $existing_parent && ! -d $existing_parent ) ]]; then
    REPLY=$encoded_file
  else
    REPLY=$legacy
  fi
}

_per-directory-history-file "$PWD"
_per_directory_history_directory=$REPLY
_per_directory_history_global_history="$HISTFILE"
_per_directory_history_context_active=false
_per_directory_history_active_history="$HISTFILE"
typeset -ga _per_directory_history_pending_commands

function _per-directory-history-append-pending() {
  local target=$1
  local line

  (( $#_per_directory_history_pending_commands )) || return 0

  # Build a temporary history context so only the pending commands are marked
  # as new for this append.  Clearing HISTFILE afterwards prevents the
  # automatic pop from rewriting the destination.
  fc -pa "$target" "$HISTSIZE" "$SAVEHIST"
  for line in "${_per_directory_history_pending_commands[@]}"; do
    print -Sr -- "$line"
  done
  fc -AI "$target"
  HISTFILE=
  SAVEHIST=0
}

function _per-directory-history-switch-context() {
  local target=$1
  local original_histsize=$HISTSIZE
  local original_savehist=$SAVEHIST

  if [[ $_per_directory_history_context_active == true ]]; then
    # Only append entries created in this context.  Suppress fc -P's normal
    # save so switching histories never rewrites a file another shell may be
    # appending to.
    fc -AI "$_per_directory_history_active_history"
    if (( $#_per_directory_history_pending_commands )); then
      local inactive_history=$target
      if [[ $_per_directory_history_active_history != $_per_directory_history_global_history &&
            $target != $_per_directory_history_global_history ]]; then
        inactive_history=$_per_directory_history_global_history
      fi
      _per-directory-history-append-pending "$inactive_history"
      _per_directory_history_pending_commands=()
    fi
    HISTFILE=
    SAVEHIST=0
    fc -P
  else
    fc -AI "$_per_directory_history_global_history"
    # The original context is retained only as a stable base for future
    # switches.  It must never overwrite the active history on exit.
    SAVEHIST=0
  fi

  # A new context reads only the selected file, replacing the active ring
  # without rewriting either history file.
  fc -p "$target" "$original_histsize" "$original_savehist"
  _per_directory_history_active_history=$target
  _per_directory_history_context_active=true
}

function _per-directory-history-change-directory() {
  _per-directory-history-file "$PWD"
  _per_directory_history_directory=$REPLY
  mkdir -p "${_per_directory_history_directory:h}"
  if [[ $_per_directory_history_is_global == false ]]; then
    _per-directory-history-switch-context "$_per_directory_history_directory"
  fi
}

function _per-directory-history-addhistory() {
  # respect hist_ignore_space
  if [[ -o hist_ignore_space ]] && [[ "$1" == \ * ]]; then
      true
  else
      print -Sr -- "${1%%$'\n'}"
      local inactive_history
      if [[ $_per_directory_history_is_global == true ]]; then
        inactive_history=$_per_directory_history_directory
      else
        inactive_history=$_per_directory_history_global_history
      fi
      # instantly write history if set options require it.
      if [[ -o append_history &&
            ! -o share_history &&
            ! -o inc_append_history &&
            ! -o inc_append_history_time ]]; then
        _per_directory_history_pending_commands+=("${1%%$'\n'}")
      elif [[ -o share_history ]] || \
         [[ -o inc_append_history ]] || \
         [[ -o inc_append_history_time ]]; then
          fc -AI "$HISTFILE"
      fi
      fc -p "$inactive_history"
  fi
}

function _per-directory-history-exit() {
  if [[ $_per_directory_history_context_active == true ]]; then
    fc -AI "$_per_directory_history_active_history"
    if (( $#_per_directory_history_pending_commands )); then
      if [[ $_per_directory_history_is_global == true ]]; then
        _per-directory-history-append-pending "$_per_directory_history_directory"
      else
        _per-directory-history-append-pending "$_per_directory_history_global_history"
      fi
      _per_directory_history_pending_commands=()
    fi
  fi
}

function _per-directory-history-precmd() {
  if [[ $_per_directory_history_initialized == false ]]; then
    _per_directory_history_initialized=true

    if [[ $HISTORY_START_WITH_GLOBAL == true ]]; then
      _per-directory-history-set-global-history
      _per_directory_history_is_global=true
    else
      _per-directory-history-set-directory-history
      _per_directory_history_is_global=false
    fi
  fi
}

function _per-directory-history-set-directory-history() {
  _per-directory-history-switch-context "$_per_directory_history_directory"
}

function _per-directory-history-set-global-history() {
  _per-directory-history-switch-context "$_per_directory_history_global_history"
}

mkdir -p "${_per_directory_history_directory:h}"

#add functions to the exec list for chpwd and zshaddhistory
autoload -U add-zsh-hook
add-zsh-hook chpwd _per-directory-history-change-directory
add-zsh-hook zshaddhistory _per-directory-history-addhistory
add-zsh-hook precmd _per-directory-history-precmd
add-zsh-hook zshexit _per-directory-history-exit

# set initialized flag to false
_per_directory_history_initialized=false
