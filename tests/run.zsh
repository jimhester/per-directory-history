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
      fail "expected $file not to contain an empty hook argument"
      return 1
    fi
  done < "$file"
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

function zpty_send_command() {
  local name=$1
  local prompt=$2
  local command=$3
  local output

  zpty -w "$name" "$command" || return 1
  zpty -r -m "$name" output "*${prompt}*"
}

function test_plugin_entrypoint_loads() {
  local root=$TEST_ROOT/plugin-entrypoint
  local working_directory=$root/work
  mkdir -p -- "$working_directory"

  (
    emulate -L zsh
    HISTFILE=$root/global_history
    HISTSIZE=50
    SAVEHIST=50
    HISTORY_BASE=$root/directory_history
    HOME=$root/home
    cd -- "$working_directory"
    source "$PLUGIN_ENTRYPOINT"

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

  assert_file_contains_text "$root/global_history" 'live-shell-b-marker' || return 1
  assert_file_contains_text "$directory_history" 'live-shell-b-marker' || return 1
  assert_file_contains_text "$snapshot" 'live-shell-b-marker'
}

function test_history_options_and_whitespace() {
  local root="$TEST_ROOT/options and whitespace"
  local working_directory="$root/work area"
  local preserved_command='print -r -- whitespace-marker     '
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" whitespace \
    'setopt SH_WORD_SPLIT' \
    'setopt HIST_IGNORE_SPACE' \
    "$preserved_command" \
    ' print -r -- ignored-space-marker' || return 1

  local directory_history
  legacy_history_file "$root" "$working_directory"
  directory_history=$REPLY

  local file
  for file in "$root/global_history" "$directory_history"; do
    assert_file_contains_exact_line "$file" "$preserved_command" || return 1
    assert_file_not_contains_text "$file" 'ignored-space-marker' || return 1
  done
}

function test_all_keymaps_are_bound() {
  local root=$TEST_ROOT/keymaps
  local working_directory=$root/work
  mkdir -p -- "$working_directory"

  (
    emulate -L zsh
    bindkey -v
    HISTFILE=$root/global_history
    HISTSIZE=50
    SAVEHIST=50
    HISTORY_BASE=$root/directory_history
    HOME=$root/home
    cd -- "$working_directory"
    source "$PLUGIN"

    local keymap
    local binding
    for keymap in emacs viins vicmd; do
      binding=$(bindkey -M "$keymap" "$PER_DIRECTORY_HISTORY_TOGGLE")
      if [[ $binding != *'per-directory-history-toggle-history' ]]; then
        fail "toggle is not bound in the $keymap keymap: $binding"
        return 1
      fi
    done
  )
}

function test_later_zshaddhistory_hook_receives_one_argument() {
  local root=$TEST_ROOT/later-hook
  local working_directory=$root/work
  local captured=$root/captured-hook-arguments
  local capture_function='function capture-hook() { print -r -- "$1" >> '"${(q)captured}"'; }'
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" later-hook \
    "$capture_function" \
    'add-zsh-hook zshaddhistory capture-hook' \
    'print -r -- later-hook-marker' || return 1

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

function test_repeated_toggles_do_not_duplicate_history() {
  local root=$TEST_ROOT/repeated-toggles
  local working_directory=$root/work
  local home=$root/home
  local prompt=PDH_TEST_READY
  local pty_name=pdh-toggle-shell
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
    zpty_send_command "$pty_name" "$prompt" "PER_DIRECTORY_HISTORY_TOGGLE='^G'" || return 1
    zpty_send_command "$pty_name" "$prompt" 'setopt INC_APPEND_HISTORY' || return 1
    zpty_send_command "$pty_name" "$prompt" 'bindkey -e' || return 1
    zpty_send_command "$pty_name" "$prompt" "cd -- ${(q)working_directory}" || return 1
    zpty_send_command "$pty_name" "$prompt" "source ${(q)PLUGIN}" || return 1
    zpty_send_command "$pty_name" "$prompt" 'print -r -- seeded-toggle-marker' || return 1

    repeat 4; do
      zpty -w -n "$pty_name" $'\C-G' || return 1
      zpty -r -m "$pty_name" pty_output "*${prompt}*" || return 1
    done

    zpty_send_command "$pty_name" "$prompt" "fc -l 1 > ${(q)snapshot}" || return 1
    zpty -w "$pty_name" exit
  } always {
    zpty -d "$pty_name" 2>/dev/null
  }

  assert_text_line_count "$snapshot" 'seeded-toggle-marker' 1
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
run_test 'persists history from concurrent shells' test_concurrent_shells_persist_history
run_test 'honors history options and preserves whitespace' test_history_options_and_whitespace
run_test 'keeps the shell usable with corrupt local history input' test_corrupt_history_does_not_block_commands

run_expected_failure \
  'binds the toggle in emacs, viins, and vicmd keymaps' \
  test_all_keymaps_are_bound \
  'the plugin binds only the active main keymap and vicmd'
run_expected_failure \
  'passes one intact argument to later zshaddhistory hooks' \
  test_later_zshaddhistory_hook_receives_one_argument \
  'fc -p triggers later hooks twice, with an empty argument on the second call'
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
run_expected_failure \
  'makes new history immediately visible to concurrent shells' \
  test_concurrent_shells_share_live_history \
  'SHARE_HISTORY does not import another live shell history until reload or toggle'
run_expected_failure \
  'does not duplicate commands across repeated local/global toggles' \
  test_repeated_toggles_do_not_duplicate_history \
  'ZLE toggle invocations duplicate existing entries in the active history buffer'

print
print -r -- "$tests_passed passed, $tests_xfailed known failures, $tests_failed failed, $tests_xpassed unexpected passes"

(( tests_failed == 0 && tests_xpassed == 0 ))
