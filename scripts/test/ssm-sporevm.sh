#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/.agents/ssm-sporevm"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/direct-bin"

cat >"$test_dir/bin/amp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'e30.eyJ0aHJlYWRfaWQiOiJ0aHJlYWQtMTIzIn0.sig'
EOF

cat >"$test_dir/bin/session-manager-plugin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$test_dir/aws-mock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_AWS_LOG"
case "$1 $2" in
  "ec2 describe-instances")
    printf '%s\n' "${MOCK_INSTANCE_IDS:-}"
    ;;
  "ssm start-session")
    [ "${4:-}" = "${MOCK_EXPECTED_INSTANCE_ID:-i-test}" ]
    ;;
esac
EOF

cat >"$test_dir/bin/mise" <<'EOF'
#!/usr/bin/env bash
shift 3
exec "$MOCK_AWS_BACKEND" "$@"
EOF

chmod +x \
  "$test_dir/bin/amp" \
  "$test_dir/bin/mise" \
  "$test_dir/bin/session-manager-plugin" \
  "$test_dir/aws-mock"
ln -s "$test_dir/aws-mock" "$test_dir/direct-bin/aws"

export MOCK_AWS_BACKEND="$test_dir/aws-mock"
export MOCK_AWS_LOG="$test_dir/aws.log"
export MOCK_EXPECTED_INSTANCE_ID="i-test"

PATH="$test_dir/direct-bin:$test_dir/bin:$PATH" \
  MOCK_INSTANCE_IDS="i-test" \
  "$helper" arm64
grep -q '^ssm start-session --target i-test$' "$MOCK_AWS_LOG"

: >"$MOCK_AWS_LOG"
PATH="$test_dir/bin:/usr/bin:/bin" \
  MOCK_INSTANCE_IDS="i-test" \
  "$helper" macos
grep -q '^ssm start-session --target i-test$' "$MOCK_AWS_LOG"

if PATH="$test_dir/direct-bin:$test_dir/bin:$PATH" \
  MOCK_INSTANCE_IDS="i-one i-two" \
  "$helper" x86_64 >/dev/null 2>&1; then
  echo "multiple matching instances must fail closed" >&2
  exit 1
fi

if PATH="$test_dir/direct-bin:$test_dir/bin:$PATH" \
  MOCK_INSTANCE_IDS="" \
  "$helper" arm64 >/dev/null 2>&1; then
  echo "no matching instances must fail closed" >&2
  exit 1
fi

if PATH="$test_dir/direct-bin:$test_dir/bin:$PATH" \
  "$helper" invalid >/dev/null 2>&1; then
  echo "invalid targets must fail" >&2
  exit 1
fi
