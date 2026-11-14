#!/usr/bin/env bash
set -eu
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/httpd-flatten.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d" "$TMP/deep" "$TMP/spaced dir"
cat > "$TMP/httpd.conf" <<EOT
ServerRoot "$TMP"
Define CONF conf.d
IncludeOptional missing/*.conf
Include ${CONF}/*.conf
<IfModule module_not_loaded>
Include deep/child.conf
</IfModule>
Include "spaced dir/space.conf"
EOT
printf 'SSLProtocol TLSv1.2\n' > "$TMP/conf.d/ssl.conf"
printf 'Include ../unexpected\n' > /dev/null
printf 'Listen 443\n' > "$TMP/deep/child.conf"
printf '# note\n' > "$TMP/spaced dir/space.conf"

bash "$SCRIPT" "$TMP/httpd.conf" > "$TMP/result"
grep -Fqx "$TMP/conf.d/ssl.conf:1: SSLProtocol TLSv1.2" "$TMP/result"
grep -Fqx "$TMP/deep/child.conf:1: Listen 443" "$TMP/result"
grep -Fqx "$TMP/spaced dir/space.conf:1: # note" "$TMP/result"
grep -Fqx "$TMP/httpd.conf:5: <IfModule module_not_loaded>" "$TMP/result"
[[ $(grep -c '^' "$TMP/result") == 11 ]]
[[ $(bash "$SCRIPT" --version) == 'httpd-flatten 0.1.0' ]]
bash "$SCRIPT" --help | grep -q 'Usage:'
if bash "$SCRIPT" --bad > /dev/null 2>&1; then exit 1; fi
if bash "$SCRIPT" "$TMP/httpd.conf" too-many > /dev/null 2>&1; then exit 1; fi

printf 'Include missing-required.conf\n' > "$TMP/deep/child.conf"
if bash "$SCRIPT" "$TMP/httpd.conf" > /dev/null 2> "$TMP/err"; then
    echo 'missing required Include must fail' >&2; exit 1
fi
grep -q 'Include target not found' "$TMP/err"
printf 'Include httpd.conf\n' > "$TMP/deep/child.conf"
if bash "$SCRIPT" "$TMP/httpd.conf" > /dev/null 2> "$TMP/err"; then
    echo 'cycle must fail' >&2; exit 1
fi
grep -q 'recursive Include cycle' "$TMP/err"
printf 'Include ${UNDEFINED_TEST_VAR_589}/*.conf\n' > "$TMP/deep/child.conf"
if bash "$SCRIPT" "$TMP/httpd.conf" > /dev/null 2> "$TMP/err"; then
    echo 'undefined variable must fail' >&2; exit 1
fi
grep -q 'undefined variable' "$TMP/err"
printf 'Include \\\n conf.d/*.conf\n' > "$TMP/deep/child.conf"
bash "$SCRIPT" "$TMP/httpd.conf" > "$TMP/result"
grep -Fqx "$TMP/deep/child.conf:2:  conf.d/*.conf" "$TMP/result"
echo 'All tests passed'
