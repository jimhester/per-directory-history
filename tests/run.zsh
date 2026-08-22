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

function local_history_file() {
  local root=$1
  local directory=$2
  REPLY="$root/directory_history${directory:A}/history"
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
  local_history_file "$root" "$first"
  first_history=$REPLY
  local_history_file "$root" "$second"
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

  local_history_file "$root" "$working_directory"
  directory_history=$REPLY
  mkdir -p -- "${directory_history:h}"
  printf 'before\0after\n' > "$directory_history"

  run_session "$root" "$working_directory" corrupt \
    'print -r -- first-command-after-corruption' \
    'print -r -- second-command-after-corruption' || return 1

  assert_file_contains_text "$root/corrupt.stdout" 'first-command-after-corruption' || return 1
  assert_file_contains_text "$root/corrupt.stdout" 'second-command-after-corruption'
}

function test_concurrent_shells_share_history() {
  local root=$TEST_ROOT/concurrent-shells
  local working_directory=$root/work
  local ready=$root/shell-a-ready
  local release=$root/release-shell-a
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" shell-a \
    'setopt SHARE_HISTORY' \
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
    'setopt SHARE_HISTORY' \
    'print -r -- shell-b-marker' \
    "touch ${(q)release}" || return 1
  wait "$shell_a_pid" || return 1

  local directory_history
  local_history_file "$root" "$working_directory"
  directory_history=$REPLY

  local file
  for file in "$root/global_history" "$directory_history"; do
    assert_file_contains_text "$file" 'shell-a-before-marker' || return 1
    assert_file_contains_text "$file" 'shell-b-marker' || return 1
    assert_file_contains_text "$file" 'shell-a-after-marker' || return 1
  done
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
  local_history_file "$root" "$working_directory"
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
  local_history_file "$root" "$child"
  child_history=$REPLY
  assert_file_contains_text "$child_history" 'child-history-marker'
}

function test_repeated_toggles_do_not_duplicate_history() {
  local root=$TEST_ROOT/repeated-toggles
  local working_directory=$root/work
  local toggle_command='per-directory-history-toggle-history >/dev/null 2>&1'
  local snapshot=$root/active-history
  mkdir -p -- "$working_directory"

  run_session "$root" "$working_directory" toggles \
    'print -r -- unique-toggle-marker' \
    "$toggle_command" \
    "$toggle_command" \
    "$toggle_command" \
    "$toggle_command" \
    "fc -l 1 > ${(q)snapshot}" || return 1

  assert_text_line_count "$snapshot" "$toggle_command" 4
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
run_test 'shares global and local history between concurrent shells' test_concurrent_shells_share_history
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
run_expected_failure \
  'stores history for a directory named history' \
  test_directory_named_history_has_its_own_history \
  'the parent history file occupies the path needed for the child history directory'
run_expected_failure \
  'does not duplicate commands across repeated local/global toggles' \
  test_repeated_toggles_do_not_duplicate_history \
  'executed toggles are duplicated in the active history buffer'

print
print -r -- "$tests_passed passed, $tests_xfailed known failures, $tests_failed failed, $tests_xpassed unexpected passes"

(( tests_failed == 0 && tests_xpassed == 0 ))
