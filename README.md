# httpd-flatten

Read-only Apache configuration audit helper. Expands `Include` and `IncludeOptional` recursively, retaining the original file and line number for each physical line.

```text
/etc/httpd/conf/httpd.conf:125: IncludeOptional conf.d/*.conf
/etc/httpd/conf.d/ssl.conf:17: SSLProtocol all -SSLv3 -TLSv1
```

## Requirements

CentOS 6 or later, Bash 4.1+, GNU/Linux utilities (`readlink`, `find`, `sort`, `mktemp`, `printenv`, `rm`). No Perl, Python, or running Apache required.

## Usage

```bash
bash httpd-flatten.sh [FILE]
bash httpd-flatten.sh --help
bash httpd-flatten.sh --version

curl -fsSL https://raw.githubusercontent.com/matsumoto-sp/httpd-flatten/main/httpd-flatten.sh | bash -s -- /etc/httpd/conf/httpd.conf
```

Default FILE: `/etc/httpd/conf/httpd.conf`. Output is written to stdout, diagnostics to stderr. Exit codes: 0 success, 1 incomplete expansion, 2 argument error.

```bash
bash httpd-flatten.sh | grep -i SSLProtocol
bash httpd-flatten.sh | grep -i SSLProtocol > /tmp/httpd-matches.txt
vim -q /tmp/httpd-matches.txt
```

## Behavior

- Includes are expanded immediately after the original Include directive; duplicate includes remain duplicated.
- Nested includes, glob patterns, directory includes, relative paths resolved against `ServerRoot`, quoted paths, line continuation, `Define`, `UnDefine`, and basic variable references are supported.
- Every Include is expanded even inside `IfModule`, `IfDefine`, and other conditional blocks. The tool does **not** report Apache's effective runtime configuration.
- Missing required files, unreadable files, undefined variables, and Include cycles cause nonzero exit status; an unmatched `IncludeOptional` is allowed.
- Does **not** evaluate `.htaccess`, mod_macro, Apache command-line defines, runtime conditions, or complex Apache syntax. Conditional variable redefinitions can cause incomplete coverage. Source filenames containing newlines and unusual escaping or globs may not be supported.
- Input files are only read; Apache is not invoked or restarted.

For additional verification of which files Apache actually uses, consider `httpd -t -D DUMP_INCLUDES` on supported installations.

## Security

Review code before executing it as root. Piping from `curl` to Bash can execute partially downloaded content. Prefer downloading, verifying, then running for critical systems, and pin a commit SHA for reproducibility.

## Tests

```bash
bash tests/test.sh
```

Version: 0.1.0.
