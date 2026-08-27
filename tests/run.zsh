#!/usr/bin/env zsh

emulate -L zsh
setopt NO_UNSET PIPE_FAIL

typeset -gr TEST_DIR=${0:A:h}
typeset -gr REPOSITORY_ROOT=${TEST_DIR:h}
typeset -gr PLUGIN=${REPOSITORY_ROOT}/per-directory-history.zsh
typeset -gr PLUGIN_ENTRYPOINT=${REPOSITORY_ROOT}/per-directory-history.plugin.zsh
typeset -gr TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/per-directory-history-tests.XXXXXX")

typeset -gi tests_passed=0
typeset -gi tests_failed=0
typeset -gi tests_xfailed=0
typeset -gi tests_xpassed=0

function cleanup() {
  [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

function fail() {
  print -u2 -r -- "$*"
  return 1
}

function assert_file_exists() {
  local file=$1
  [[ -f $file ]] || fail "expected file to exist: $file"
}

function file_contains_text() {
  local file=$1
  local expected=$2
  local line

  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ $line == *${expected}* ]] && return 0
  done < "$file"
  return 1
}

function assert_file_contains_text() {
  local file=$1
  local expected=$2
  file_contains_text "$file" "$expected" ||
    fail "expected $file to contain: $expected"
}

function assert_file_not_contains_text() {
  local file=$1
  local unexpected=$2
  if file_contains_text "$file" "$unexpected"; then
    fail "expected $file not to contain: $unexpected"
  fi
}

function file_contains_exact_line() {
  local file=$1
  local expected=$2
  local line

  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ $line == "$expected" ]] && return 0
  done < "$file"
  return 1
}

function assert_file_contains_exact_line() {
  local file=$1
  local expected=$2
  file_contains_exact_line "$file" "$expected" ||
    fail "expected $file to contain the exact line: ${(qqq)expected}"
}

function count_exact_lines() {
  local file=$1
  local expected=$2
  local line
  local -i count=0

  if [[ -f $file ]]; then
    while IFS= read -r line; do
      [[ $line == "$expected" ]] && (( ++count ))
    done < "$file"
  fi
  REPLY=$count
}

function assert_exact_line_count() {
  local file=$1
  local expected=$2
  local wanted=$3
  count_exact_lines "$file" "$expected"
  [[ $REPLY == $wanted ]] ||
    fail "expected $file to contain ${(qqq)expected} $wanted times, found $REPLY"
}

function assert_text_line_count() {
  local file=$1
  local expected=$2
  local wanted=$3
  local line
  local -i count=0

  if [[ -f $file ]]; then
    while IFS= read -r line; do
      [[ $line == *${expected}* ]] && (( ++count ))
    done < "$file"
  fi
  [[ $count == $wanted ]] ||
    fail "expected $file to contain $expected on $wanted lines, found $count"
}

function assert_file_has_no_empty_lines() {
  local file=$1
  local line

  assert_file_exists "$file" || return 1
  while IFS= read -r line; do
    if [[ -z $line ]]; then
      fail "expected $file not to contain an empty line"
      return 1
    fi
  done < "$file"
}

function assert_file_line_count_at_most() {
  local file=$1
  local maximum=$2
  local line
  local -i count=0

  assert_file_exists "$file" || return 1
  while IFS= read -r line; do
    (( ++count ))
  done < "$file"
  (( count <= maximum )) ||
    fail "expected $file to contain at most $maximum lines, found $count"
}

# Start a real interactive zsh so zshaddhistory, precmd, and chpwd run in the
# same order they do for users. Each argument after the id is one input line.
function run_session() {
  local root=$1
  local working_directory=$2
  local id=$3
  shift 3

  local global_history=$root/global_history
  local history_base=$root/directory_history
  local home=$root/home
  local command

  mkdir -p -- "$working_directory" "$home"

  {
    print -r -- "PROMPT=''"
    print -r -- "PROMPT2=''"
    print -r -- "RPROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)history_base}"
    print -r -- 'HISTORY_START_WITH_GLOBAL=false'
    print -r -- "PER_DIRECTORY_HISTORY_TOGGLE='^G'"
    print -r -- 'setopt INC_APPEND_HISTORY'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
    for command in "$@"; do
      print -r -- "$command"
    done
    print -r -- 'exit'
  } | env TERM=dumb HOME="$home" zsh -dfi \
      > "$root/$id.stdout" 2> "$root/$id.stderr"
}

function legacy_history_file() {
  local root=$1
  local directory=$2
  REPLY="$root/directory_history${directory:A}/history"
}

function encoded_history_file() {
  local root=$1
  local directory=$2
  local encoded=${directory:A}
  encoded=${encoded//\%/%25}
  encoded=${encoded//\//%2F}
  REPLY="$root/directory_history/.history/$encoded"
}

function history_option_command() {
  local option=$1

  case $option in
    NONE)
      REPLY='unsetopt APPEND_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY'
      ;;
    APPEND_HISTORY|INC_APPEND_HISTORY|INC_APPEND_HISTORY_TIME|SHARE_HISTORY)
      REPLY="unsetopt APPEND_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY; setopt $option"
      ;;
    *)
      fail "unknown history option: $option"
      return 1
      ;;
  esac
}

function zpty_send_command() {
  local name=$1
  local prompt=$2
  local command=$3
  local output

  zpty -w "$name" "$command" || return 1
  zpty -r -m "$name" output "*${prompt}*"
}

function zpty_wait() {
  local name=$1
  local output

  while zpty -r "$name" output; do
    true
  done
  return 0
}

function test_plugin_entrypoint_loads() {
  local root=$TEST_ROOT/plugin-entrypoint
  local plugin_directory="$root/plugin install with spaces"
  local plugin_entrypoint=$plugin_directory/per-directory-history.plugin.zsh
  local working_directory=$root/work

  [[ -f $PLUGIN_ENTRYPOINT && ! -h $PLUGIN_ENTRYPOINT ]] ||
    { fail 'plugin entrypoint must be a regular file, not a symlink'; return 1 }
  [[ "$(<$PLUGIN_ENTRYPOINT)" != per-directory-history.zsh ]] ||
    { fail 'plugin entrypoint contains an unresolved symlink target'; return 1 }

  mkdir -p -- "$plugin_directory" "$working_directory"
  cp -- "$PLUGIN" "$plugin_directory/per-directory-history.zsh" || return 1
  cp -- "$PLUGIN_ENTRYPOINT" "$plugin_entrypoint" || return 1

  (
    emulate -L zsh
    setopt SH_WORD_SPLIT
    HISTFILE=$root/global_history
    HISTSIZE=50
    SAVEHIST=50
    HISTORY_BASE=$root/directory_history
    HOME=$root/home
    cd -- "$working_directory"
    source "$plugin_entrypoint"

    (( $+functions[_per-directory-history-addhistory] )) ||
      { fail 'plugin entrypoint did not define the history hook'; return 1 }
    [[ $_per_directory_history_directory == "$HISTORY_BASE${working_directory:A}/history" ]] ||
      fail 'plugin entrypoint initialized the wrong local history path'
  )
}

function test_global_and_directory_persistence() {
  local root=$TEST_ROOT/persistence
  local first=$root/work/first
  local second=$root/work/second
  mkdir -p -- "$first" "$second"
  print -r -- 'preexisting-global-marker' > "$root/global_history"

  run_session "$root" "$first" persistence \
    'print -r -- first-directory-marker' \
    "cd -- ${(q)second}" \
    'print -r -- second-directory-marker' || return 1

  local first_history
  local second_history
  legacy_history_file "$root" "$first"
  first_history=$REPLY
  legacy_history_file "$root" "$second"
  second_history=$REPLY

  assert_file_contains_text "$root/global_history" 'first-directory-marker' || return 1
  assert_file_contains_text "$root/global_history" 'second-directory-marker' || return 1
  assert_file_contains_text "$root/global_history" 'preexisting-global-marker' || return 1
  assert_file_contains_text "$first_history" 'first-directory-marker' || return 1
  assert_file_not_contains_text "$first_history" 'second-directory-marker' || return 1
  assert_file_contains_text "$second_history" 'second-directory-marker' || return 1
  assert_file_not_contains_text "$second_history" 'first-directory-marker'
}

function test_corrupt_history_does_not_block_commands() {
  local root=$TEST_ROOT/corrupt-history
  local working_directory=$root/work
  local directory_history
  mkdir -p -- "$working_directory"

  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY
  mkdir -p -- "${directory_history:h}"
  printf 'before\0after\n' > "$directory_history"

  run_session "$root" "$working_directory" corrupt \
    'print -r -- first-command-after-corruption' \
    'print -r -- second-command-after-corruption' || return 1

  assert_file_contains_text "$root/corrupt.stdout" 'first-command-after-corruption' || return 1
  assert_file_contains_text "$root/corrupt.stdout" 'second-command-after-corruption'
}

function test_concurrent_shells_persist_history() {
  local root=$TEST_ROOT/concurrent-shells
  local working_directory=$root/work
  local ready=$root/shell-a-ready
  local release=$root/release-shell-a
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" shell-a \
    'print -r -- shell-a-before-marker' \
    "touch ${(q)ready}" \
    "while [[ ! -e ${(q)release} ]]; do sleep 0.01; done" \
    'print -r -- shell-a-after-marker' &
  local shell_a_pid=$!

  local -i attempts=0
  while [[ ! -e $ready && $attempts -lt 500 ]]; do
    sleep 0.01
    (( ++attempts ))
  done
  if [[ ! -e $ready ]]; then
    touch "$release"
    wait "$shell_a_pid"
    fail 'first interactive shell did not reach its synchronization point'
    return 1
  fi

  run_session "$root" "$working_directory" shell-b \
    'print -r -- shell-b-marker' \
    "touch ${(q)release}" || return 1
  wait "$shell_a_pid" || return 1

  local directory_history
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY

  local file
  for file in "$root/global_history" "$directory_history"; do
    assert_file_contains_text "$file" 'shell-a-before-marker' || return 1
    assert_file_contains_text "$file" 'shell-b-marker' || return 1
    assert_file_contains_text "$file" 'shell-a-after-marker' || return 1
  done
}

function test_concurrent_shells_share_live_history() {
  local root=$TEST_ROOT/live-shared-history
  local working_directory=$root/work
  local shell_a_ready=$root/shell-a-ready
  local release_shell_a=$root/release-shell-a
  local snapshot_complete=$root/snapshot-complete
  local snapshot=$root/shell-a-active-history
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" live-shell-a \
    'unsetopt INC_APPEND_HISTORY; setopt SHARE_HISTORY' \
    'print -r -- live-shell-a-marker' \
    "touch ${(q)shell_a_ready}" \
    "while [[ ! -e ${(q)release_shell_a} ]]; do sleep 0.01; done" \
    "fc -l 1 > ${(q)snapshot}" \
    "touch ${(q)snapshot_complete}" &
  local shell_a_pid=$!

  local -i attempts=0
  while [[ ! -e $shell_a_ready && $attempts -lt 500 ]]; do
    sleep 0.01
    (( ++attempts ))
  done
  if [[ ! -e $shell_a_ready ]]; then
    touch "$release_shell_a"
    wait "$shell_a_pid"
    fail 'first shared-history shell did not reach its synchronization point'
    return 1
  fi

  run_session "$root" "$working_directory" live-shell-b \
    'unsetopt INC_APPEND_HISTORY; setopt SHARE_HISTORY' \
    'print -r -- live-shell-b-marker' \
    "touch ${(q)release_shell_a}" \
    "for attempt in {1..500}; do [[ -e ${(q)snapshot_complete} ]] && break; sleep 0.01; done" || return 1
  wait "$shell_a_pid" || return 1

  local directory_history
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY

  local file
  for file in "$root/global_history" "$directory_history"; do
    assert_text_line_count "$file" 'live-shell-a-marker' 1 || return 1
    assert_text_line_count "$file" 'live-shell-b-marker' 1 || return 1
  done
  assert_text_line_count "$snapshot" 'live-shell-b-marker' 1
}

function test_blank_history_entries_and_whitespace() {
  local root="$TEST_ROOT/options and whitespace"
  local working_directory="$root/work area"
  local preserved_command=' print -r -- whitespace-marker     '
  mkdir -p -- "$working_directory"

  # Reproduce a blank command passed directly to the history hook.
  run_session "$root" "$working_directory" whitespace \
    'setopt SH_WORD_SPLIT' \
    "$preserved_command" \
    'setopt HIST_IGNORE_SPACE' \
    "_per-directory-history-addhistory \$'\\n'" \
    ' print -r -- ignored-space-marker' || return 1

  local directory_history
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY

  local file
  for file in "$root/global_history" "$directory_history"; do
    assert_file_contains_exact_line "$file" "$preserved_command" || return 1
    assert_file_not_contains_text "$file" 'ignored-space-marker' || return 1
    assert_file_has_no_empty_lines "$file" || return 1
  done
}

function test_all_keymaps_are_bound() {
  local root=$TEST_ROOT/keymaps
  local working_directory=$root/work
  mkdir -p -- "$working_directory"

  (
    emulate -L zsh
    bindkey -e
    HISTFILE=$root/global_history
    HISTSIZE=50
    SAVEHIST=50
    HISTORY_BASE=$root/directory_history
    HOME=$root/home
    cd -- "$working_directory"
    source "$PLUGIN"
    bindkey -v

    local keymap
    local binding
    for keymap in viins vicmd; do
      binding=$(bindkey -M "$keymap" "$PER_DIRECTORY_HISTORY_TOGGLE")
      if [[ $binding != *'per-directory-history-toggle-history' ]]; then
        fail "toggle is not bound in the active $keymap keymap after switching to vi mode: $binding"
        return 1
      fi
    done

    binding=$(bindkey -M emacs "$PER_DIRECTORY_HISTORY_TOGGLE")
    if [[ $binding != *'per-directory-history-toggle-history' ]]; then
      fail "toggle is not bound in the emacs keymap: $binding"
      return 1
    fi
  )
}

function test_custom_main_keymap_receives_binding() {
  local root=$TEST_ROOT/custom-main-keymap
  local working_directory=$root/work
  mkdir -p -- "$working_directory"

  (
    emulate -L zsh
    bindkey -e
    bindkey -N custom-main emacs
    bindkey -A custom-main main
    PER_DIRECTORY_HISTORY_TOGGLE='^X'
    HISTFILE=$root/global_history
    HISTSIZE=50
    SAVEHIST=50
    HISTORY_BASE=$root/directory_history
    HOME=$root/home
    cd -- "$working_directory"
    source "$PLUGIN"

    local binding
    binding=$(bindkey -M custom-main "$PER_DIRECTORY_HISTORY_TOGGLE")
    if [[ $binding != *'per-directory-history-toggle-history' ]]; then
      fail "toggle is not bound in the custom keymap aliased to main: $binding"
      return 1
    fi
  )
}

function test_later_preexec_hook_receives_one_argument() {
  local root=$TEST_ROOT/later-preexec-hook
  local working_directory=$root/work
  local captured=$root/captured-hook-arguments
  local home=$root/home
  local prompt=PDH_HOOK_READY
  local pty_name=pdh-later-hook
  local pty_output
  mkdir -p -- "$working_directory" "$home"
  zmodload zsh/zpty || return 1

  {
    zpty "$pty_name" env TERM=dumb HOME=${(q)home} PS1=${(q)prompt} zsh -dfi || return 1
    zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1

    zpty_send_command "$pty_name" "$prompt" "HISTFILE=${(q)root}/global_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTSIZE=200' || return 1
    zpty_send_command "$pty_name" "$prompt" 'SAVEHIST=200' || return 1
    zpty_send_command "$pty_name" "$prompt" "HISTORY_BASE=${(q)root}/directory_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTORY_START_WITH_GLOBAL=false' || return 1
    zpty_send_command "$pty_name" "$prompt" 'setopt INC_APPEND_HISTORY' || return 1
    zpty_send_command "$pty_name" "$prompt" "cd -- ${(q)working_directory}" || return 1
    zpty_send_command "$pty_name" "$prompt" "source ${(q)PLUGIN}" || return 1
    zpty_send_command "$pty_name" "$prompt" \
      'function capture-preexec() { print -r -- "$1" >> '"${(q)captured}"'; }; add-zsh-hook preexec capture-preexec' || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- later-hook-marker' || return 1
    zpty -w "$pty_name" exit || return 1
    zpty_wait "$pty_name" || return 1
  } always {
    zpty -d "$pty_name" 2>/dev/null
  }

  assert_exact_line_count "$captured" 'print -r -- later-hook-marker' 1 || return 1
  assert_file_has_no_empty_lines "$captured"
}

function test_directory_named_history_has_its_own_history() {
  local root=$TEST_ROOT/history-directory-collision
  local parent=$root/work
  local child=$parent/history
  mkdir -p -- "$child"

  run_session "$root" "$parent" history-directory \
    'print -r -- parent-history-marker' \
    "cd -- ${(q)child}" \
    'print -r -- child-history-marker' || return 1

  local child_history
  local parent_history
  encoded_history_file "$root" "$child"
  child_history=$REPLY
  encoded_history_file "$root" "$parent"
  parent_history=$REPLY
  assert_file_contains_text "$parent_history" 'parent-history-marker' || return 1
  assert_file_not_contains_text "$parent_history" 'child-history-marker' || return 1
  assert_file_contains_text "$child_history" 'child-history-marker' || return 1
  assert_file_not_contains_text "$child_history" 'parent-history-marker'
}

function test_encoded_history_stays_selected_after_collision_changes() {
  local root=$TEST_ROOT/sticky-encoded-history
  local parent=$root/work
  local child=$parent/history
  local parent_history
  local legacy_parent_history
  mkdir -p -- "$child"

  run_session "$root" "$parent" sticky-before-removal \
    'print -r -- sticky-before-removal-marker' || return 1

  encoded_history_file "$root" "$parent"
  parent_history=$REPLY
  legacy_history_file "$root" "$parent"
  legacy_parent_history=$REPLY
  assert_file_contains_text "$parent_history" 'sticky-before-removal-marker' || return 1
  [[ ! -e $legacy_parent_history ]] ||
    fail "unexpected legacy history file: $legacy_parent_history" || return 1

  rmdir -- "$child" || return 1
  mkdir -p -- "${legacy_parent_history:h}"
  print -r -- 'legacy-after-removal-marker' > "$legacy_parent_history"
  run_session "$root" "$parent" sticky-after-removal \
    'print -r -- sticky-after-removal-marker' || return 1
  assert_file_contains_text "$legacy_parent_history" 'legacy-after-removal-marker' || return 1
  assert_file_not_contains_text "$legacy_parent_history" 'sticky-after-removal-marker' || return 1

  mkdir -p -- "$child"
  run_session "$root" "$parent" sticky-after-recreation \
    'print -r -- sticky-after-recreation-marker' || return 1

  for marker in sticky-before-removal-marker sticky-after-removal-marker \
      sticky-after-recreation-marker; do
    assert_file_contains_text "$parent_history" "$marker" || return 1
  done
  assert_file_not_contains_text "$legacy_parent_history" 'sticky-after-recreation-marker'
}

function test_preexisting_legacy_history_remains_usable() {
  local root=$TEST_ROOT/legacy-history-compatibility
  local working_directory=$root/work
  local legacy_history
  local encoded_history
  mkdir -p -- "$working_directory"

  legacy_history_file "$root" "$working_directory"
  legacy_history=$REPLY
  mkdir -p -- "${legacy_history:h}"
  print -r -- 'preexisting-legacy-marker' > "$legacy_history"

  run_session "$root" "$working_directory" legacy-compatibility \
    'print -r -- new-legacy-marker' || return 1

  assert_file_contains_text "$legacy_history" 'preexisting-legacy-marker' || return 1
  assert_file_contains_text "$legacy_history" 'new-legacy-marker' || return 1
  encoded_history_file "$root" "$working_directory"
  encoded_history=$REPLY
  [[ ! -e $encoded_history ]] ||
    fail "legacy history unexpectedly moved to: $encoded_history"
}

function test_nested_history_directories_use_distinct_files() {
  local root=$TEST_ROOT/nested-history-directories
  local parent=$root/work
  local child=$parent/history
  local nested=$child/history
  local parent_history
  local child_history
  local nested_history
  mkdir -p -- "$nested"

  run_session "$root" "$parent" nested-history \
    'print -r -- nested-parent-marker' \
    "cd -- ${(q)child}" \
    'print -r -- nested-child-marker' \
    "cd -- ${(q)nested}" \
    'print -r -- nested-grandchild-marker' || return 1

  encoded_history_file "$root" "$parent"
  parent_history=$REPLY
  encoded_history_file "$root" "$child"
  child_history=$REPLY
  encoded_history_file "$root" "$nested"
  nested_history=$REPLY

  assert_file_contains_text "$parent_history" 'nested-parent-marker' || return 1
  assert_file_not_contains_text "$parent_history" 'nested-child-marker' || return 1
  assert_file_not_contains_text "$parent_history" 'nested-grandchild-marker' || return 1
  assert_file_contains_text "$child_history" 'nested-child-marker' || return 1
  assert_file_not_contains_text "$child_history" 'nested-parent-marker' || return 1
  assert_file_not_contains_text "$child_history" 'nested-grandchild-marker' || return 1
  assert_file_contains_text "$nested_history" 'nested-grandchild-marker' || return 1
  assert_file_not_contains_text "$nested_history" 'nested-parent-marker' || return 1
  assert_file_not_contains_text "$nested_history" 'nested-child-marker'
}

function test_encoded_history_handles_spaces_and_percent() {
  local root=$TEST_ROOT/encoded-spaces-percent
  local parent="$root/work % area"
  local child="$parent/history"
  local parent_history
  local child_history
  mkdir -p -- "$child"

  run_session "$root" "$parent" spaces-percent \
    'print -r -- spaces-percent-parent-marker' \
    "cd -- ${(q)child}" \
    'print -r -- spaces-percent-child-marker' || return 1

  encoded_history_file "$root" "$parent"
  parent_history=$REPLY
  encoded_history_file "$root" "$child"
  child_history=$REPLY
  [[ $parent_history == *%25* && $child_history == *%25* ]] ||
    fail 'encoded history path did not escape percent signs' || return 1
  [[ $parent_history == *'work '* && $parent_history == *' area'* &&
     $child_history == *'work '* && $child_history == *' area'* ]] ||
    fail 'encoded history path did not preserve spaces safely' || return 1
  assert_file_contains_text "$parent_history" 'spaces-percent-parent-marker' || return 1
  assert_file_not_contains_text "$parent_history" 'spaces-percent-child-marker' || return 1
  assert_file_contains_text "$child_history" 'spaces-percent-child-marker' || return 1
  assert_file_not_contains_text "$child_history" 'spaces-percent-parent-marker'
}

function run_exit_history_safety_case() {
  local option=$1
  local start_global=$2
  local case_name=${option:l}-${start_global:l}
  local root=$TEST_ROOT/exit-history-safety/$case_name
  local working_directory=$root/work
  local home=$root/home
  local global_history=$root/global_history
  local directory_history
  local new_marker=issue35-new-${case_name//[^[:alnum:]]/-}
  local option_command
  local -i sentinel

  mkdir -p -- "$working_directory" "$home"
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY
  mkdir -p -- "${directory_history:h}"

  for sentinel in {1..12}; do
    print -r -- "issue35-global-sentinel-$sentinel-end"
  done > "$global_history"
  for sentinel in {1..4}; do
    print -r -- "issue35-local-sentinel-$sentinel-end"
  done > "$directory_history"

  history_option_command "$option" || return 1
  option_command=$REPLY
  {
    print -r -- "PROMPT=''"
    print -r -- "PROMPT2=''"
    print -r -- "RPROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- "HISTORY_START_WITH_GLOBAL=$start_global"
    print -r -- "PER_DIRECTORY_HISTORY_TOGGLE='^G'"
    print -r -- "$option_command"
    print -r -- 'setopt EXTENDED_HISTORY HIST_SAVE_BY_COPY'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  {
    print -r -- "print -r -- $new_marker"
    print -r -- 'exit'
  } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
      > "$root/session.stdout" 2> "$root/session.stderr" || return 1

  for sentinel in {1..12}; do
    assert_text_line_count \
      "$global_history" "issue35-global-sentinel-$sentinel-end" 1 || return 1
  done
  for sentinel in {1..4}; do
    assert_text_line_count \
      "$directory_history" "issue35-local-sentinel-$sentinel-end" 1 || return 1
  done
  assert_file_not_contains_text "$global_history" 'issue35-local-sentinel-' || return 1
  assert_file_not_contains_text "$directory_history" 'issue35-global-sentinel-' || return 1
  assert_text_line_count "$global_history" "$new_marker" 1 || return 1
  assert_text_line_count "$directory_history" "$new_marker" 1
}

function test_exit_preserves_and_mirrors_history_in_all_modes() {
  local option
  local start_global
  local -i failures=0

  for option in NONE APPEND_HISTORY INC_APPEND_HISTORY \
      INC_APPEND_HISTORY_TIME SHARE_HISTORY; do
    for start_global in false true; do
      run_exit_history_safety_case "$option" "$start_global" || (( ++failures ))
    done
  done
  (( failures == 0 ))
}

function run_runtime_limit_exit_case() {
  local exit_style=$1
  local root=$TEST_ROOT/runtime-history-limits/$exit_style
  local working_directory=$root/work
  local home=$root/home
  local global_history=$root/global_history
  local -i sentinel

  mkdir -p -- "$working_directory" "$home"
  for sentinel in {1..12}; do
    print -r -- "runtime-limit-global-sentinel-$sentinel-end"
  done > "$global_history"

  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- 'HISTORY_START_WITH_GLOBAL=false'
    print -r -- 'unsetopt INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY'
    print -r -- 'setopt APPEND_HISTORY EXTENDED_HISTORY HIST_SAVE_BY_COPY'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  if [[ $exit_style == same-line-exit ]]; then
    {
      print -r -- 'SAVEHIST=4'
      print -r -- 'SAVEHIST=200; exit'
    } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
        > "$root/session.stdout" 2> "$root/session.stderr" || return 1
  else
    {
      print -r -- 'SAVEHIST=4'
      print -r -- 'SAVEHIST=200'
    } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
        > "$root/session.stdout" 2> "$root/session.stderr" || return 1
  fi

  for sentinel in {1..12}; do
    assert_text_line_count \
      "$global_history" "runtime-limit-global-sentinel-$sentinel-end" 1 || return 1
  done
  assert_text_line_count "$global_history" 'SAVEHIST=200' 1
}

function test_runtime_history_limit_changes_preserve_inactive_history() {
  run_runtime_limit_exit_case prompt-then-eof || return 1
  run_runtime_limit_exit_case same-line-exit
}

function test_same_line_limit_reduction_bounds_inactive_history() {
  local root=$TEST_ROOT/runtime-history-limits/same-line-reduction
  local working_directory=$root/work
  local home=$root/home
  local global_history=$root/global_history
  local -i sentinel

  mkdir -p -- "$working_directory" "$home"
  for sentinel in {1..12}; do
    print -r -- "runtime-reduction-global-sentinel-$sentinel"
  done > "$global_history"

  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- 'HISTORY_START_WITH_GLOBAL=false'
    print -r -- 'unsetopt INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY'
    print -r -- 'setopt APPEND_HISTORY'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  print -r -- 'SAVEHIST=4; exit' |
    env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
      > "$root/session.stdout" 2> "$root/session.stderr" || return 1

  assert_file_line_count_at_most "$global_history" 4 || return 1
  assert_text_line_count "$global_history" 'SAVEHIST=4; exit' 1
}

function run_ksh_arrays_pending_case() {
  local option=$1
  local start_global=$2
  local case_name=${option:l}-${start_global:l}
  local root=$TEST_ROOT/ksh-arrays-pending/$case_name
  local working_directory=$root/work
  local home=$root/home
  local global_history=$root/global_history
  local directory_history
  local option_command
  local first_marker=ksh-arrays-first-$case_name
  local second_marker=ksh-arrays-second-$case_name

  mkdir -p -- "$working_directory" "$home"
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY
  mkdir -p -- "${directory_history:h}"
  print -r -- 'ksh-arrays-global-sentinel' > "$global_history"
  print -r -- 'ksh-arrays-local-sentinel' > "$directory_history"

  history_option_command "$option" || return 1
  option_command=$REPLY
  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=20'
    print -r -- 'SAVEHIST=20'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- "HISTORY_START_WITH_GLOBAL=$start_global"
    print -r -- "$option_command"
    print -r -- 'setopt KSH_ARRAYS'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  {
    print -r -- "print -r -- $first_marker"
    print -r -- "print -r -- $second_marker"
    print -r -- 'exit'
  } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
      > "$root/session.stdout" 2> "$root/session.stderr" || return 1

  local file
  for file in "$global_history" "$directory_history"; do
    assert_text_line_count "$file" "$first_marker" 1 || return 1
    assert_text_line_count "$file" "$second_marker" 1 || return 1
  done
}

function test_ksh_arrays_preserves_all_pending_history() {
  local option
  local start_global

  for option in NONE APPEND_HISTORY; do
    for start_global in false true; do
      run_ksh_arrays_pending_case "$option" "$start_global" || return 1
    done
  done
}

function run_bounded_final_mirror_case() {
  local start_global=$1
  local root=$TEST_ROOT/bounded-final-mirrors/$start_global
  local working_directory=$root/work
  local home=$root/home
  local global_history=$root/global_history
  local directory_history
  local inactive_history
  local marker
  local -i session

  mkdir -p -- "$working_directory" "$home"
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY
  mkdir -p -- "${directory_history:h}"
  for session in {1..5}; do
    print -r -- "bounded-local-sentinel-$session"
  done > "$directory_history"
  for session in {1..5}; do
    print -r -- "bounded-global-sentinel-$session"
  done > "$global_history"

  if [[ $start_global == true ]]; then
    inactive_history=$directory_history
  else
    inactive_history=$global_history
  fi

  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=5'
    print -r -- 'SAVEHIST=5'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- "HISTORY_START_WITH_GLOBAL=$start_global"
    print -r -- 'unsetopt INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY'
    print -r -- 'setopt APPEND_HISTORY'
    print -r -- "cd -- ${(q)working_directory}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  for session in {1..4}; do
    marker=bounded-final-marker-$session
    {
      print -r -- "print -r -- $marker"
      print -r -- 'exit'
    } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
        > "$root/session-$session.stdout" \
        2> "$root/session-$session.stderr" || return 1
  done

  assert_file_line_count_at_most "$inactive_history" 5 || return 1
  assert_text_line_count "$inactive_history" 'bounded-final-marker-4' 1
}

function test_final_inactive_mirrors_respect_savehist() {
  run_bounded_final_mirror_case false || return 1
  run_bounded_final_mirror_case true
}

function run_global_directory_routing_case() {
  local option=$1
  local root=$TEST_ROOT/global-directory-routing/${option:l}
  local first=$root/work/first
  local second=$root/work/second
  local home=$root/home
  local first_history
  local second_history
  local option_command

  mkdir -p -- "$first" "$second" "$home"
  legacy_history_file "$root" "$first"
  first_history=$REPLY
  legacy_history_file "$root" "$second"
  second_history=$REPLY
  mkdir -p -- "${first_history:h}" "${second_history:h}"
  print -r -- 'routing-first-sentinel' > "$first_history"
  print -r -- 'routing-second-sentinel' > "$second_history"

  history_option_command "$option" || return 1
  option_command=$REPLY
  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)root}/global_history"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- 'HISTORY_START_WITH_GLOBAL=true'
    print -r -- "$option_command"
    print -r -- "cd -- ${(q)first}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  {
    print -r -- 'print -r -- routing-first-marker'
    print -r -- "cd -- ${(q)second}"
    print -r -- 'print -r -- routing-second-marker'
    print -r -- 'exit'
  } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
      > "$root/session.stdout" 2> "$root/session.stderr" || return 1

  assert_text_line_count "$first_history" 'routing-first-sentinel' 1 || return 1
  assert_text_line_count "$second_history" 'routing-second-sentinel' 1 || return 1
  assert_text_line_count "$first_history" 'routing-first-marker' 1 || return 1
  assert_file_not_contains_text "$first_history" 'routing-second-marker' || return 1
  assert_text_line_count "$second_history" 'routing-second-marker' 1 || return 1
  assert_file_not_contains_text "$second_history" 'routing-first-marker' || return 1
  assert_text_line_count "$root/global_history" 'routing-first-marker' 1 || return 1
  assert_text_line_count "$root/global_history" 'routing-second-marker' 1
}

function test_global_mode_routes_pending_history_by_directory() {
  run_global_directory_routing_case NONE || return 1
  run_global_directory_routing_case APPEND_HISTORY
}

function test_failed_mirror_does_not_block_directory_switch() {
  local root=$TEST_ROOT/failed-mirror-directory-switch
  local first=$root/work/first
  local second=$root/work/second
  local home=$root/home
  local global_directory=$root/global-store
  local global_history=$global_directory/history
  local active_after_failure=$root/active-after-failure
  local global_before_retry=$root/global-before-retry
  local first_history
  local second_history

  mkdir -p -- "$first" "$second" "$home" "$global_directory"
  print -r -- 'failed-mirror-global-sentinel' > "$global_history"
  legacy_history_file "$root" "$first"
  first_history=$REPLY
  legacy_history_file "$root" "$second"
  second_history=$REPLY

  {
    print -r -- "PROMPT=''"
    print -r -- "HISTFILE=${(q)global_history}"
    print -r -- 'HISTSIZE=200'
    print -r -- 'SAVEHIST=200'
    print -r -- "HISTORY_BASE=${(q)root}/directory_history"
    print -r -- 'HISTORY_START_WITH_GLOBAL=false'
    print -r -- 'unsetopt INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME SHARE_HISTORY'
    print -r -- 'setopt APPEND_HISTORY'
    print -r -- "cd -- ${(q)first}"
    print -r -- "source ${(q)PLUGIN}"
  } > "$home/.zshrc"

  {
    print -r -- 'print -r -- failed-mirror-first-marker'
    print -r -- "chmod 400 ${(q)global_history}"
    print -r -- "chmod 500 ${(q)global_directory}"
    print -r -- "cd -- ${(q)second}"
    print -r -- "print -r -- \"\$HISTFILE\" > ${(q)active_after_failure}"
    print -r -- "cp ${(q)global_history} ${(q)global_before_retry}"
    print -r -- 'print -r -- failed-mirror-second-marker'
    print -r -- "chmod 700 ${(q)global_directory}"
    print -r -- "chmod 600 ${(q)global_history}"
    print -r -- 'exit'
  } | env TERM=dumb HOME="$home" ZDOTDIR="$home" zsh -di \
      > "$root/session.stdout" 2> "$root/session.stderr" || return 1

  local observed_active_history=$(<"$active_after_failure")
  [[ $observed_active_history == $second_history ]] ||
    fail "expected the second directory history after append failure, found: $observed_active_history" || return 1
  assert_file_not_contains_text "$global_before_retry" 'failed-mirror-first-marker' || return 1
  assert_text_line_count "$first_history" 'failed-mirror-first-marker' 1 || return 1
  assert_file_not_contains_text "$first_history" 'failed-mirror-second-marker' || return 1
  assert_text_line_count "$second_history" 'failed-mirror-second-marker' 1 || return 1
  assert_file_not_contains_text "$second_history" 'failed-mirror-first-marker' || return 1
  assert_text_line_count "$global_history" 'failed-mirror-first-marker' 1 || return 1
  assert_text_line_count "$global_history" 'failed-mirror-second-marker' 1
}

function run_repeated_toggle_case() {
  local option=$1
  local start_global=$2
  local case_name=${option:l}-${start_global:l}
  local root=$TEST_ROOT/repeated-toggles/$case_name
  local working_directory=$root/work
  local home=$root/home
  local prompt=PDH_TEST_READY
  local pty_name=pdh-toggle-${case_name//[^[:alnum:]]/-}
  local snapshot=$root/active-history
  local directory_history
  local pty_output
  local option_command

  history_option_command "$option" || return 1
  option_command=$REPLY

  mkdir -p -- "$working_directory" "$home"
  zmodload zsh/zpty || return 1

  {
    zpty "$pty_name" env TERM=dumb HOME=${(q)home} PS1=${(q)prompt} zsh -dfi || return 1
    zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1

    zpty_send_command "$pty_name" "$prompt" "HISTFILE=${(q)root}/global_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTSIZE=200' || return 1
    zpty_send_command "$pty_name" "$prompt" 'SAVEHIST=200' || return 1
    zpty_send_command "$pty_name" "$prompt" "HISTORY_BASE=${(q)root}/directory_history" || return 1
    zpty_send_command "$pty_name" "$prompt" "HISTORY_START_WITH_GLOBAL=$start_global" || return 1
    zpty_send_command "$pty_name" "$prompt" "PER_DIRECTORY_HISTORY_TOGGLE='^G'" || return 1
    zpty_send_command "$pty_name" "$prompt" "$option_command" || return 1
    zpty_send_command "$pty_name" "$prompt" 'bindkey -e' || return 1
    zpty_send_command "$pty_name" "$prompt" "cd -- ${(q)working_directory}" || return 1
    zpty_send_command "$pty_name" "$prompt" "source ${(q)PLUGIN}" || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- seeded-toggle-marker' || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- legitimate-duplicate-marker' || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- legitimate-duplicate-marker' || return 1
    if [[ $option == APPEND_HISTORY && $start_global == false ]]; then
      # Pending APPEND_HISTORY entries must still be mirrored if the user
      # changes history options before toggling.
      zpty_send_command "$pty_name" "$prompt" 'setopt INC_APPEND_HISTORY' || return 1
    fi

    repeat 4; do
      zpty -w -n "$pty_name" $'\C-G' || return 1
      zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1
    done

    zpty_send_command "$pty_name" "$prompt" 'print -r -- post-toggle-sync' || return 1
    zpty_send_command "$pty_name" "$prompt" "fc -l 1 > ${(q)snapshot}" || return 1
    zpty -w "$pty_name" exit || return 1
    zpty_wait "$pty_name" || return 1
  } always {
    zpty -d "$pty_name" 2>/dev/null
  }

  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY
  assert_text_line_count "$snapshot" 'seeded-toggle-marker' 1 || return 1
  assert_text_line_count "$root/global_history" 'seeded-toggle-marker' 1 || return 1
  assert_text_line_count "$directory_history" 'seeded-toggle-marker' 1 || return 1
  assert_text_line_count "$snapshot" 'legitimate-duplicate-marker' 2 || return 1
  assert_text_line_count "$root/global_history" 'legitimate-duplicate-marker' 2 || return 1
  assert_text_line_count "$directory_history" 'legitimate-duplicate-marker' 2
}

function test_repeated_toggles_do_not_duplicate_history() {
  local option
  local start_global

  for option in NONE APPEND_HISTORY INC_APPEND_HISTORY \
      INC_APPEND_HISTORY_TIME SHARE_HISTORY; do
    for start_global in false true; do
      run_repeated_toggle_case "$option" "$start_global" || return 1
    done
  done
}

function test_share_history_preserves_up_line_navigation() {
  local root=$TEST_ROOT/share-history-up-line
  local working_directory=$root/work
  local home=$root/home
  local prompt=PDH_UP_LINE_READY
  local pty_name=pdh-share-history-up-line
  local captured=$root/up-line-buffer
  local pty_output

  mkdir -p -- "$working_directory" "$home"
  zmodload zsh/zpty || return 1

  {
    zpty "$pty_name" env TERM=dumb HOME=${(q)home} PS1=${(q)prompt} zsh -dfi || return 1
    zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1

    zpty_send_command "$pty_name" "$prompt" "HISTFILE=${(q)root}/global_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTSIZE=200' || return 1
    zpty_send_command "$pty_name" "$prompt" 'SAVEHIST=200' || return 1
    zpty_send_command "$pty_name" "$prompt" "HISTORY_BASE=${(q)root}/directory_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTORY_START_WITH_GLOBAL=false' || return 1
    zpty_send_command "$pty_name" "$prompt" 'setopt INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_SPACE' || return 1
    zpty_send_command "$pty_name" "$prompt" 'bindkey -e' || return 1
    zpty_send_command "$pty_name" "$prompt" "cd -- ${(q)working_directory}" || return 1
    zpty_send_command "$pty_name" "$prompt" "source ${(q)PLUGIN}" || return 1
    zpty_send_command "$pty_name" "$prompt" \
      ' function capture-up-line() { zle up-line-or-history; print -r -- "$BUFFER" > '"${(q)captured}"'; zle send-break; }; zle -N capture-up-line; bindkey "^P" capture-up-line' || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- share-history-up-line-marker' || return 1

    zpty -w -n "$pty_name" $'\C-P' || return 1
    zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1
    zpty -w "$pty_name" exit || return 1
    zpty_wait "$pty_name" || return 1
  } always {
    zpty -d "$pty_name" 2>/dev/null
  }

  [[ -f $captured ]] ||
    { fail 'up-line-or-history widget did not capture a buffer'; return 1 }
  [[ "$(<$captured)" == 'print -r -- share-history-up-line-marker' ]] ||
    fail "expected up-line-or-history to recall the latest command, found: $(<$captured)"
}

function test_share_history_imports_before_next_command() {
  local root=$TEST_ROOT/share-history-before-next-command
  local working_directory=$root/work
  local home=$root/home
  local prompt=PDH_IMPORT_READY
  local pty_name=pdh-share-history-import
  local snapshot=$root/active-history
  local pty_output

  mkdir -p -- "$working_directory" "$home"
  zmodload zsh/zpty || return 1

  {
    zpty "$pty_name" env TERM=dumb HOME=${(q)home} PS1=${(q)prompt} zsh -dfi || return 1
    zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1

    zpty_send_command "$pty_name" "$prompt" "HISTFILE=${(q)root}/global_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTSIZE=200' || return 1
    zpty_send_command "$pty_name" "$prompt" 'SAVEHIST=200' || return 1
    zpty_send_command "$pty_name" "$prompt" "HISTORY_BASE=${(q)root}/directory_history" || return 1
    zpty_send_command "$pty_name" "$prompt" 'HISTORY_START_WITH_GLOBAL=false' || return 1
    zpty_send_command "$pty_name" "$prompt" 'setopt INC_APPEND_HISTORY SHARE_HISTORY' || return 1
    zpty_send_command "$pty_name" "$prompt" "cd -- ${(q)working_directory}" || return 1
    zpty_send_command "$pty_name" "$prompt" "source ${(q)PLUGIN}" || return 1

    run_session "$root" "$working_directory" external-writer \
      'setopt SHARE_HISTORY' \
      'print -r -- share-history-external-before-command' || return 1

    zpty_send_command "$pty_name" "$prompt" "fc -l 1 > ${(q)snapshot}" || return 1
    zpty -w "$pty_name" exit || return 1
    zpty_wait "$pty_name" || return 1
  } always {
    zpty -d "$pty_name" 2>/dev/null
  }

  assert_text_line_count "$snapshot" \
    'share-history-external-before-command' 1
}

function print_captured_output() {
  local output=$1
  [[ -n $output ]] || return 0
  print -r -- "$output" | sed 's/^/    /'
}

function run_test() {
  local description=$1
  local test_function=$2
  local output

  if output=$("$test_function" 2>&1); then
    print -r -- "PASS  $description"
    (( ++tests_passed ))
  else
    print -r -- "FAIL  $description"
    print_captured_output "$output"
    (( ++tests_failed ))
  fi
}

function run_expected_failure() {
  local description=$1
  local test_function=$2
  local reason=$3
  local output

  if output=$("$test_function" 2>&1); then
    print -r -- "XPASS $description"
    print -r -- "    was marked as a known bug: $reason"
    (( ++tests_xpassed ))
  else
    print -r -- "XFAIL $description"
    print -r -- "    known bug: $reason"
    print_captured_output "$output"
    (( ++tests_xfailed ))
  fi
}

run_test 'loads through the .plugin.zsh entrypoint' test_plugin_entrypoint_loads
run_test 'persists global and per-directory history' test_global_and_directory_persistence
run_test \
  'preserves and mirrors history on exit in every persistence mode' \
  test_exit_preserves_and_mirrors_history_in_all_modes
run_test \
  'uses runtime history-limit changes for the final inactive mirror' \
  test_runtime_history_limit_changes_preserve_inactive_history
run_test \
  'uses a same-line SAVEHIST reduction to bound the final mirror' \
  test_same_line_limit_reduction_bounds_inactive_history
run_test \
  'preserves delayed mirrors when KSH_ARRAYS is enabled' \
  test_ksh_arrays_preserves_all_pending_history
run_test \
  'bounds final inactive mirrors by SAVEHIST' \
  test_final_inactive_mirrors_respect_savehist
run_test \
  'routes global-mode pending history to its original directory' \
  test_global_mode_routes_pending_history_by_directory
run_test \
  'keeps directory history aligned after a mirror append failure' \
  test_failed_mirror_does_not_block_directory_switch
run_test 'persists history from concurrent shells' test_concurrent_shells_persist_history
run_test \
  'ignores blank history entries and preserves command whitespace' \
  test_blank_history_entries_and_whitespace
run_test 'keeps the shell usable with corrupt local history input' test_corrupt_history_does_not_block_commands

run_test \
  'binds the toggle after switching from emacs to vi mode' \
  test_all_keymaps_are_bound
run_test \
  'binds the toggle in a custom keymap aliased to main' \
  test_custom_main_keymap_receives_binding
run_test \
  'passes one intact argument to later preexec hooks' \
  test_later_preexec_hook_receives_one_argument
run_test \
  'stores history for a directory named history' \
  test_directory_named_history_has_its_own_history
run_test \
  'keeps encoded history selected when a collision disappears and returns' \
  test_encoded_history_stays_selected_after_collision_changes
run_test \
  'continues using pre-existing legacy history files' \
  test_preexisting_legacy_history_remains_usable
run_test \
  'keeps nested history directories in distinct files' \
  test_nested_history_directories_use_distinct_files
run_test \
  'encodes spaces and percent signs safely' \
  test_encoded_history_handles_spaces_and_percent
run_test \
  'makes new history immediately visible to concurrent shells' \
  test_concurrent_shells_share_live_history
run_test \
  'does not duplicate commands across repeated local/global toggles' \
  test_repeated_toggles_do_not_duplicate_history
run_test \
  'keeps up-line-or-history working with SHARE_HISTORY' \
  test_share_history_preserves_up_line_navigation
run_test \
  'imports SHARE_HISTORY writes before the next command' \
  test_share_history_imports_before_next_command

print
print -r -- "$tests_passed passed, $tests_xfailed known failures, $tests_failed failed, $tests_xpassed unexpected passes"

(( tests_failed == 0 && tests_xpassed == 0 ))
