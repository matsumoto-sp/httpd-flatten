#!/usr/bin/env bash
# httpd-flatten - recursively expand Apache Include directives for auditing.
# Requires Bash >= 4.1 and standard GNU/Linux utilities.

VERSION=0.1.0
DEFAULT_FILE=/etc/httpd/conf/httpd.conf
SERVER_ROOT=/etc/httpd
ERRORS=0
MAX_DEPTH=64
declare -A DEFINES=()
declare -a INCLUDE_STACK=()

usage() {
    cat <<'HELP'
Usage: httpd-flatten [OPTIONS] [FILE]

Recursively expand Apache Include and IncludeOptional directives, printing
all source lines as: /absolute/path:line-number: original line
Includes are expanded immediately after their source directive.

Options:
  -h, --help       Show this help and exit
  -V, --version    Show the version and exit

FILE defaults to /etc/httpd/conf/httpd.conf.
This is a static audit tool, NOT Apache's effective configuration: conditions
are ignored; every Include is traversed regardless of IfModule/IfDefine/etc.
Errors and warnings go to stderr. Any incomplete expansion exits nonzero.
HELP
}

error() { printf 'httpd-flatten: ERROR: %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }
warn()  { printf 'httpd-flatten: WARNING: %s\n' "$*" >&2; }

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'httpd-flatten: Bash 4.1 or later is required\n' >&2
    exit 2
fi

file=$DEFAULT_FILE
seen_file=0
while (($#)); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -V|--version) printf 'httpd-flatten %s\n' "$VERSION"; exit 0 ;;
        --) shift; if (($# > 1)); then printf 'httpd-flatten: too many arguments\n' >&2; exit 2; fi
            if (($#)); then file=$1; fi; break ;;
        -*) printf 'httpd-flatten: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) if ((seen_file)); then printf 'httpd-flatten: too many arguments\n' >&2; exit 2; fi
           file=$1; seen_file=1 ;;
    esac
    shift
done

# GNU readlink is included with coreutils on CentOS 6 and later.
absolute_path() {
    readlink -f -- "$1"
}

# Trim whitespace, then decode a single quoted or double quoted argument.
# This is deliberately not a general-purpose Apache configuration parser.
parse_value() {
    local s=$1 q
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [[ -n $s ]] || return 1
    q=${s:0:1}
    if [[ $q == '"' || $q == "'" ]]; then
        [[ ${s: -1} == "$q" && ${#s} -ge 2 ]] || return 1
        s=${s:1:${#s}-2}
        # Apache accepts escaped quotes and backslashes inside quoted values.
        s=${s//\\$q/$q}
        s=${s//\\\\/\\}
    elif [[ $s == *[[:space:]]* ]]; then
        return 1
    fi
    PARSED=$s
}

# Expand Apache ${NAME} substitutions, with Define taking precedence over
# inherited environment variables. Never evaluate the value as shell code.
expand_vars() {
    local value=$1 where=$2 token key replacement n=0
    while [[ $value =~ (\$\{([a-zA-Z_][a-zA-Z_0-9]*)\}) ]]; do
        token=${BASH_REMATCH[1]}
        key=${BASH_REMATCH[2]}
        if [[ ${DEFINES[$key]+exists} ]]; then
            replacement=${DEFINES[$key]}
        elif replacement=$(printenv "$key"); then
            :
        else
            error "$where: undefined variable $key"
            return 1
        fi
        value=${value/"$token"/"$replacement"}
        n=$((n+1))
        if ((n > 100)); then error "$where: variable expansion too deep"; return 1; fi
    done
    EXPANDED=$value
}

# Resolve a name against ServerRoot, as Apache does (not the including file).
resolve_path() {
    local name=$1
    if [[ $name == /* ]]; then RESOLVED=$name
    else RESOLVED=${SERVER_ROOT%/}/$name
    fi
}

# A directory Include recursively includes its regular files. GNU find -L
# follows symlink targets; sort guarantees repeatable ordering.
expand_target() {
    local target=$1 depth=$2 where=$3 optional=$4 candidate
    local -a matches=()
    if [[ $target == *[\*\?\[]* ]]; then
        while IFS= read -r candidate; do
            [[ -n $candidate ]] && matches+=("$candidate")
        done < <(compgen -G "$target" | LC_ALL=C sort)
    elif [[ -e $target ]]; then
        matches+=("$target")
    fi
    if ((${#matches[@]} == 0)); then
        if [[ $optional != 1 ]]; then error "$where: Include target not found: $target"; fi
        return
    fi
    for candidate in "${matches[@]}"; do
        if [[ -d $candidate ]]; then
            local listing
            listing=$(mktemp) || { error "$where: cannot create temporary file"; continue; }
            if ! find -L "$candidate" -type f -print > "$listing"; then
                error "$where: could not fully enumerate directory: $candidate"
            fi
            while IFS= read -r targetfile; do
                [[ -n $targetfile ]] && process_file "$targetfile" "$depth"
            done < <(LC_ALL=C sort "$listing")
            rm -f -- "$listing"
        elif [[ -f $candidate ]]; then
            process_file "$candidate" "$depth"
        else
            error "$where: Include target is not a regular file: $candidate"
        fi
    done
}

process_directive() {
    local directive=$1 arg=$2 where=$3 depth=$4 name value
    case $directive in
        Include|IncludeOptional)
            if ! parse_value "$arg"; then error "$where: invalid $directive argument"; return; fi
            if ! expand_vars "$PARSED" "$where"; then return; fi
            resolve_path "$EXPANDED"
            local optional=0
            [[ $directive == IncludeOptional ]] && optional=1
            expand_target "$RESOLVED" "$((depth+1))" "$where" "$optional"
            ;;
        ServerRoot)
            if ! parse_value "$arg"; then error "$where: invalid ServerRoot argument"; return; fi
            if ! expand_vars "$PARSED" "$where"; then return; fi
            resolve_path "$EXPANDED"
            SERVER_ROOT=${RESOLVED%/}
            [[ -n $SERVER_ROOT ]] || SERVER_ROOT=/
            ;;
        Define)
            # NAME or NAME VALUE; Apache permits a valueless definition.
            name=${arg%%[[:space:]]*}
            if [[ ! $name =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; then
                error "$where: invalid Define name: $name"; return
            fi
            if [[ $arg == "$name" ]]; then value=''
            else
                value=${arg#"$name"}
                if ! parse_value "$value"; then error "$where: invalid Define value"; return; fi
                value=$PARSED
            fi
            if [[ ${DEFINES[$name]+exists} && ${DEFINES[$name]} != "$value" ]]; then
                warn "$where: Define $name redefined; conditional definitions may be ambiguous"
            fi
            DEFINES[$name]=$value
            ;;
        UnDefine)
            if ! parse_value "$arg" || [[ ! $PARSED =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; then
                error "$where: invalid UnDefine argument"; return
            fi
            unset 'DEFINES[$PARSED]'
            ;;
    esac
}

process_file() {
    local requested=$1 depth=$2 canonical line logical='' start_line=0 number=0
    local keyword arg i
    if ((depth > MAX_DEPTH)); then error "$requested: maximum Include depth ($MAX_DEPTH) exceeded"; return; fi
    canonical=$(absolute_path "$requested") || { error "cannot resolve path: $requested"; return; }
    if [[ ! -f $canonical || ! -r $canonical ]]; then error "cannot read file: $canonical"; return; fi
    for i in "${INCLUDE_STACK[@]}"; do
        if [[ $i == "$canonical" ]]; then error "recursive Include cycle at $canonical"; return; fi
    done
    INCLUDE_STACK+=("$canonical")
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number+1))
        printf '%s:%d: %s\n' "$canonical" "$number" "$line"
        if [[ -z $logical ]]; then start_line=$number; fi
        logical+=$line
        # An odd number of trailing backslashes means a continued line.
        local tail=$logical slash_count=0
        while [[ $tail == *\\ ]]; do tail=${tail%\\}; slash_count=$((slash_count+1)); done
        if ((slash_count % 2)); then
            logical=${logical%\\}
            continue
        fi
        if [[ $logical =~ ^[[:space:]]*(IncludeOptional|Include|ServerRoot|Define|UnDefine)[[:space:]]+(.+)$ ]]; then
            keyword=${BASH_REMATCH[1]}; arg=${BASH_REMATCH[2]}
            process_directive "$keyword" "$arg" "$canonical:$start_line" "$depth"
        elif [[ $logical =~ ^[[:space:]]*(IncludeOptional|Include)[[:space:]]*$ ]]; then
            error "$canonical:$start_line: missing Include path"
        fi
        logical=''
    done < "$canonical"
    if [[ -n $logical ]]; then error "$canonical:$start_line: unfinished line continuation"; fi
    unset 'INCLUDE_STACK[${#INCLUDE_STACK[@]}-1]'
}

process_file "$file" 0
((ERRORS == 0)) || exit 1
exit 0
