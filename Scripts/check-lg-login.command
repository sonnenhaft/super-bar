#!/bin/bash
# Read-only LG mobile login check. Requires only macOS system tools; no compilation.
set +x
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="$ROOT/.build/dev-credentials/lg-login-input.json"
WORK=''
SAVE=''
cleanup() {
    [[ -z "$SAVE" ]] || /bin/rm -f -- "$SAVE"
    [[ -z "$WORK" ]] || /bin/rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'echo "FAIL: local processing failed (details withheld to protect credentials)." >&2' ERR
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash Scripts/check-lg-login.command [--input | private-credentials.json]'
    echo '--input saves email/password/country privately before any network request, even if login fails.'
    exit 0
fi
[[ $# -le 1 ]] || fail 'Expected at most one argument.'
if [[ $# == 1 && $1 != --input ]]; then
    [[ $1 != -* ]] || fail 'Unknown option; use --help.'
    INPUT="$1"
fi
for tool in /usr/bin/curl /usr/bin/jq /usr/bin/openssl; do
    [[ -x $tool ]] || fail 'Required macOS tool is unavailable.'
done
# Reject symlinks in the file AND its ancestors before reading or saving secrets.
no_links() {
    local path="$1"
    [[ $path == /* ]] || path="$PWD/$path"
    while [[ $path != / && -n $path ]]; do
        [[ ! -L $path ]] || fail 'Credential path must not contain symlinks.'
        path="${path%/*}"
    done
}
private_file() {
    no_links "$1"
    [[ -f $1 && -O $1 ]] || fail 'Credential file must be a regular file owned by you.'
    [[ $(/usr/bin/stat -f '%Lp' "$1") == 600 ]] || fail 'Credential file must have permissions 600.'
    [[ $(/usr/bin/stat -f '%l' "$1") == 1 ]] || fail 'Credential file must not have hard links.'
}
no_links "$INPUT"
if [[ ${1:-} == --input ]]; then
    if [[ -e $INPUT ]]; then private_file "$INPUT"; fi
    IFS= read -r -p 'LG email: ' lg_email
    IFS= read -r -s -p 'LG password: ' lg_password
    printf '\n'
    IFS= read -r -p 'Country [PH]: ' lg_country
    /bin/mkdir -p "$ROOT/.build/dev-credentials"
    /bin/chmod 700 "$ROOT/.build/dev-credentials"
    SAVE="$(/usr/bin/mktemp "$ROOT/.build/dev-credentials/.lg-input.XXXXXX")"
    # Shell built-in printf sends secrets over stdin, never process arguments.
    printf '%s\0' "$lg_email" "$lg_password" "${lg_country:-PH}" |
        /usr/bin/jq -Rs 'split("\u0000") | {email: .[0], password: .[1], country: .[2]}' > "$SAVE"
    /bin/chmod 600 "$SAVE"
    /bin/mv -f -- "$SAVE" "$INPUT"
    SAVE=''
    unset lg_email lg_password lg_country
    echo 'Input saved with permissions 600 before login; failed login will not erase it.'
fi
[[ -f $INPUT ]] || fail 'No saved input. Run bash Scripts/check-lg-login.command --input.'
private_file "$INPUT"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lg-login.XXXXXX")"
/bin/cp "$INPUT" "$WORK/input.json"
/usr/bin/jq -e 'type == "object" and
    (.email | type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not)) and
    (.password | type == "string" and length > 0 and (contains("\u0000") | not)) and
    (.country | type == "string" and test("^[A-Za-z]{2}$"))' "$WORK/input.json" >/dev/null 2>&1 ||
    fail 'Input must contain email, password and a two-letter country.'
email="$(/usr/bin/jq -r '.email | gsub("^\\s+|\\s+$"; "")' "$WORK/input.json")"
[[ -n $email ]] || fail 'Email is empty.'
country="$(/usr/bin/jq -r '.country | ascii_upcase' "$WORK/input.json")"
client="$(/usr/bin/uuidgen)"
APP_KEY='6V1V8H2BN5P9ZQGOI5DAQ92YZBDO3EK9'
CLIENT_ID='LGAO221A02'
OAUTH_KEY='c053c2a6ddeb7ad97cb0eed0dcb31cf8' # Public protocol constant.

# Strict HTTPS LG allowlist; redirects are never followed.
valid_url() {
    local url="$1" host
    [[ $url != *[$'\r\n\t '\\]* && $url != *'#'* ]] || return 1
    [[ $url =~ ^https://([A-Za-z0-9.-]+)(:(443|46030))?(/[^[:space:]]*)?$ ]] || return 1
    host="$(printf '%s' "${BASH_REMATCH[1]}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "$host" in
        lgthinq.com|*.lgthinq.com|lgaccount.com|*.lgaccount.com|lgsmartplatform.com|*.lgsmartplatform.com|lgecloud.com|*.lgecloud.com|lgeapi.com|*.lgeapi.com) return 0;;
        *) return 1;;
    esac
}
endpoint() {
    valid_url "$1" && [[ $1 != *'?'* ]] || fail 'Unsupported LG server address.'
    printf '%s/%s' "${1%/}" "$2"
}
# NUL-delimited pairs are form-encoded using jq; all values arrive on stdin.
form() {
    /usr/bin/jq -jRs 'split("\u0000") | if .[-1] == "" then .[:-1] else . end |
        . as $v | [range(0; length; 2) | ($v[.] | @uri) + "=" + ($v[.+1] | @uri)] | join("&")'
}
required() {
    /usr/bin/jq -er "$2 | if (type == \"string\" and length > 0) or type == \"number\" then tostring else error(\"missing\") end" "$1" 2>/dev/null ||
        fail 'LG response is missing a required field.'
}
header() {
    [[ $2 != *[$'\r\n']* ]] || fail 'Invalid LG response header value.'
    printf '%s: %s\n' "$1" "$2" >> "$WORK/headers"
}
common_headers() {
    : > "$WORK/headers"
    header x-api-key 'VGhpblEyLjAgU0VSVklDRQ=='
    header x-client-id "$client"
    header x-country-code "$country"
    header x-language-code "en-$country"
    header x-message-id "$(/usr/bin/uuidgen)"
    header x-service-code SVC202
    header x-service-phase OP
    header x-thinq-app-level PRD
    header x-thinq-app-os ANDROID
    header x-thinq-app-type NUTS
    header x-thinq-app-ver 5.0.1200
}
request() {
    local stage="$1" url="$2" method="${3:-GET}" kind="${4:-json}" escaped status rc
    valid_url "$url" || fail "$stage: unsupported LG server."
    escaped="${url//\\/\\\\}"; escaped="${escaped//\"/\\\"}"
    printf 'url = "%s"\n' "$escaped" > "$WORK/curl.conf"
    # -q prevents ~/.curlrc from enabling verbose output, redirects or other options.
    # Config/header/body files keep even URLs containing email or codes out of argv.
    local args=(-q --silent --show-error --proto '=https' --connect-timeout 15 --max-time 35
        --max-redirs 0 --globoff --config "$WORK/curl.conf" --header "@$WORK/headers"
        --header 'Accept: application/json' --user-agent 'Mozilla/5.0'
        --output "$WORK/response" --write-out '%{http_code}')
    if [[ $method == POST ]]; then
        args+=(--header 'Content-Type: application/x-www-form-urlencoded;charset=UTF-8' --data-binary "@$WORK/body")
    fi
    if status="$(/usr/bin/curl "${args[@]}" 2> "$WORK/curl-error")"; then :; else
        rc=$?
        if [[ $rc == 6 ]]; then fail "$stage: DNS error (curl 6); login was not verified."; fi
        fail "$stage: curl error $rc; login was not verified."
    fi
    printf '  %s: HTTP %s\n' "$stage" "$status"
    if [[ $status != 2[0-9][0-9] ]]; then
        report_error_code
        fail "$stage: HTTP $status."
    fi
    if [[ $kind == json ]]; then
        /usr/bin/jq -e 'type == "object"' "$WORK/response" >/dev/null 2>&1 || fail "$stage: invalid JSON response."
        /usr/bin/jq -e '(has("error") or has("lgoauth_error_code") or
            ((.status | type) == "number" and .status != 1) or
            ((.resultCode | type) == "string" and .resultCode != "0000")) | not' "$WORK/response" >/dev/null ||
            { report_error_code; fail "$stage: LG rejected the request."; }
    fi
}
report_error_code() {
    # Remove known credentials before showing the provider's diagnostic message.
    local code
    code="$(/usr/bin/jq -r '[.error.code?, .error_code?, .errorCode?, .lgoauth_error_code?, .resultCode?, .code?] |
        map(select(type == "string" or type == "number") | tostring |
            select(test("^[A-Z0-9_.-]{1,64}$"))) | unique | join(", ")' "$WORK/response" 2>/dev/null)" || code=''
    [[ -z $code ]] || printf '  LG error code: %s\n' "$code"
    /usr/bin/jq -r --slurpfile input "$WORK/input.json" '
        (.error.message? // .error.description? // .message? // empty) |
        select(type == "string") |
        reduce ($input[0] | [.email, .password] | .[] | select(type == "string" and length > 0)) as $secret
            (.; split($secret) | join("[redacted]") | split($secret | @uri) | join("[redacted]")) |
        gsub("[A-Za-z0-9.!#$%&\u0027*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+"; "[email]") |
        gsub("[A-Za-z0-9_+/=-]{32,}"; "[redacted]") |
        gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | .[0:300] |
        "  LG message: " + .
    ' "$WORK/response" 2>/dev/null || true
    return 0
}
oauth_date() { LC_ALL=C /bin/date -u '+%a, %d %b %Y %H:%M:%S +0000'; }
sign() { /usr/bin/openssl dgst -sha1 -hmac "$OAUTH_KEY" -binary | /usr/bin/openssl base64 -A; }
# Percent decoding is performed by shell built-ins, keeping authorization codes off argv.
decode() {
    local rest="$1" out='' char hex
    while [[ -n $rest ]]; do
        char="${rest:0:1}"; rest="${rest:1}"
        if [[ $char == '%' ]]; then
            hex="${rest:0:2}"
            [[ $hex =~ ^[0-9A-Fa-f]{2}$ && $hex != 00 ]] || fail 'Invalid authorization escape.'
            printf -v char '%b' "\\x$hex"; rest="${rest:2}"
        fi
        out+="$char"
    done
    printf '%s' "$out"
}

echo 'Checking LG login, token exchange, profile and device dashboard…'
common_headers
request gateway 'https://route.lgthinq.com:46030/v1/service/application/gateway-uri'
/bin/cp "$WORK/response" "$WORK/gateway"
login_base="$(required "$WORK/gateway" '.result.empSpxUri')"
emp_base="$(required "$WORK/gateway" '.result.empTermsUri')"
api_base="$(required "$WORK/gateway" '.result.thinq2Uri')"
for base in "$login_base" "$emp_base" "$api_base"; do valid_url "$base" || fail 'Gateway returned an unsupported LG server.'; done
: > "$WORK/headers"
header X-Application-Key "$APP_KEY"
header X-Client-App-Key "$CLIENT_ID"
header X-Lge-Svccode SVC709
header X-Device-Type M01
header X-Device-Platform ADR
header X-Device-Language-Type IETF
header X-Device-Publish-Flag Y
header X-Device-Country "$country"
header X-Device-Language "en-$country"
hash="$(/usr/bin/jq -j '.password' "$WORK/input.json" | /usr/bin/openssl dgst -sha512 -binary | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')"
printf '%s\0' user_auth2 "$hash" log_param "login request / user_id : $email / third_party : null / svc_list : SVC202,SVC710 / 3rd_service : " | form > "$WORK/body"
unset hash
request pre-login "$(endpoint "$login_base" preLogin)" POST
header X-Signature "$(required "$WORK/response" '.signature')"
header X-Timestamp "$(required "$WORK/response" '.tStamp')"
printf '%s\0' user_auth2 "$(required "$WORK/response" '.encrypted_pw')" password_hash_prameter_flag Y svc_list 'SVC202,SVC710' | form > "$WORK/body"
encoded_email="$(printf '%s' "$email" | /usr/bin/jq -jRs '@uri')"
request 'account login' "$(endpoint "$emp_base" "emp/v2.0/account/session/$encoded_email")" POST
/bin/cp "$WORK/response" "$WORK/account"
state="$(/usr/bin/uuidgen)"
redirect='lgaccount.lgsmartthinq:/'
query="$(printf '%s\0' account_type "$(required "$WORK/account" '.account.userIDType')" client_id "$CLIENT_ID" country_code "$(required "$WORK/account" '.account.country')" redirect_uri "$redirect" response_type code state "$state" username "$(required "$WORK/account" '.account.userID')" | form)"
date="$(oauth_date)"
path="/emp/oauth2/authorize/empsession?$query"
signature_query="$(printf '%s\0' kind oauth2 timestamp "$path"$'\n'"$date" key_name OAUTH_SECRETKEY sever_type OP | form)"
: > "$WORK/headers"
request signature "$(endpoint "$login_base" "signature?$signature_query")" GET text
signature="$(/usr/bin/tr -d '\r\n' < "$WORK/response")"
[[ $signature =~ ^[A-Za-z0-9+/]{27}=$ ]] || fail 'LG signature: invalid response.'
header lgemp-x-app-key LGAO722A02
header lgemp-x-date "$date"
header lgemp-x-signature "$signature"
header lgemp-x-session-key "$(required "$WORK/account" '.account.loginSessionID')"
header X-Device-Type M01
header X-Device-Platform ADR
request authorization "https://emp-oauth.lgecloud.com$path"
raw="$(required "$WORK/response" '.redirect_uri')"
code=''; returned_state=''; has_state=0; oauth_base=''
for attempt in 1 2; do
    if [[ $raw == *'?'* ]]; then
        query="${raw#*\?}"; query="${query%%#*}"
        while [[ -n $query ]]; do
            pair="${query%%&*}"
            if [[ $query == *'&'* ]]; then query="${query#*&}"; else query=''; fi
            key="$(decode "${pair%%=*}")"; value="$(decode "${pair#*=}")"
            case "$key" in
                code) code="$value";;
                state) returned_state="$value"; has_state=1;;
                oauth2_backend_url) oauth_base="$value";;
            esac
        done
    fi
    [[ -z $code ]] || break
    raw="$(decode "$raw")"
done
[[ -n $code ]] || fail 'Authorization returned no code.'
[[ $has_state == 0 || $returned_state == "$state" ]] || fail 'Authorization state mismatch.'
if [[ -z $oauth_base ]]; then
    oauth_base="$(/usr/bin/jq -r '.result.uris.empOauthBaseUri // empty' "$WORK/gateway")"
    if [[ -z $oauth_base ]]; then oauth_base="https://$(printf '%s' "$country" | /usr/bin/tr '[:upper:]' '[:lower:]').lgeapi.com/"; fi
fi
valid_url "$oauth_base" || fail 'Authorization returned an unsupported token server.'
printf '%s\0' code "$code" grant_type authorization_code redirect_uri "$redirect" | form > "$WORK/body"
date="$(oauth_date)"
signature="$( { printf '/oauth/1.0/oauth2/token?'; /bin/cat "$WORK/body"; printf '\n%s' "$date"; } | sign)"
: > "$WORK/headers"
header x-lge-appkey "$CLIENT_ID"
header x-lge-app-os ADR
header x-lge-oauth-date "$date"
header x-lge-oauth-signature "$signature"
request 'token exchange' "$(endpoint "$oauth_base" oauth/1.0/oauth2/token)" POST
access="$(required "$WORK/response" '.access_token')"
refresh="$(required "$WORK/response" '.refresh_token')"
unset refresh
hint="$(/usr/bin/jq -r '.oauth2_backend_url | if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end' "$WORK/response")"
# Optional malformed backend hints must not break a successful token exchange.
if valid_url "$hint" && [[ $hint != *'?'* ]]; then oauth_base="$hint"; fi
date="$(oauth_date)"
: > "$WORK/headers"
header Authorization "Bearer $access"
header X-Lge-Svccode SVC202
header X-Application-Key "$APP_KEY"
header lgemp-x-app-key "$CLIENT_ID"
header X-Device-Type M01
header X-Device-Platform ADR
header x-lge-oauth-date "$date"
header x-lge-oauth-signature "$(printf '/users/profile\n%s' "$date" | sign)"
request profile "$(endpoint "$oauth_base" users/profile)"
user_number="$(required "$WORK/response" '.account.userNo')"
common_headers
header x-emp-token "$access"
header x-user-no "$user_number"
request 'device dashboard' "$(endpoint "$api_base" service/application/dashboard)"
/usr/bin/jq -e '.result.item | type == "array" and all(.[]; type == "object")' "$WORK/response" >/dev/null || fail 'LG device list is missing.'
/usr/bin/jq -r '"Devices found: \(.result.item | length)", "Air conditioners found: \([.result.item[] | select((.deviceType | tostring) == "401")] | length)"' "$WORK/response"
echo 'PASS: login, tokens, profile and device dashboard. No device settings or app sessions changed.'
