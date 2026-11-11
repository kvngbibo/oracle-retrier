#!/usr/bin/env bash
# GitHub side of the Oracle "baton" retrier (Automate with Bibo).
# Public log prints result codes only - no IDs, keys, IPs or raw Oracle errors.
set -euo pipefail
umask 077
BUCKET=retrier-baton; OBJ=baton.json; NAME=n8n-server
HOLDER="gh-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
CS_STALE=900                     # Cloud Shell lease is stale after 15 min
WF=oracle-retrier.yml
say(){ echo "RESULT: $*"; }
classify(){ local f=$1
  if grep -qiE 'out of (host )?capacity' "$f"; then echo NO_CAPACITY
  elif grep -qE 'TooManyRequests|"status": 429' "$f"; then echo RATE_LIMITED
  elif grep -q 'NotAuthorizedOrNotFound' "$f"; then echo AUTH_ERROR
  else local c s; c=$(grep -o '"code": "[^"]*"' "$f" | head -1 | cut -d'"' -f4 || true)
       s=$(grep -o '"status": [0-9]*' "$f" | head -1 | awk '{print $2}' || true)
       echo "OTHER ${s:-?} ${c:-?}"; fi; }
disable_wf(){ gh workflow disable "$WF" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || say WARN_DISABLE_FAILED; }

# 1. Required secrets (names only are printed)
missing=""
for n in OCI_CONFIG OCI_PRIVATE_KEY OCI_SSH_PUBLIC_KEY; do [ -n "${!n:-}" ] || missing="$missing $n"; done
if [ "${MODE:-dry-run}" = launch ]; then for n in TG_BOT_TOKEN TG_CHAT_ID; do [ -n "${!n:-}" ] || missing="$missing $n"; done; fi
[ -z "$missing" ] || { say "MISSING_SECRETS$missing"; exit 1; }

# 2. OCI config from the console "Configuration file preview"
mkdir -p ~/.oci
printf '%s\n' "$OCI_PRIVATE_KEY" | tr -d '\r' > ~/.oci/key.pem
printf '%s\n' "$OCI_SSH_PUBLIC_KEY" | tr -d '\r' > ~/.oci/n8n.pub
printf '%s\n' "$OCI_CONFIG" | tr -d '\r' | grep -v '^key_file' > ~/.oci/config
echo "key_file=$HOME/.oci/key.pem" >> ~/.oci/config
T=$(sed -n 's/^tenancy=//p' ~/.oci/config | tr -d ' '); U=$(sed -n 's/^user=//p' ~/.oci/config | tr -d ' ')
[ -n "$T" ] && [ -n "$U" ] || { say BAD_OCI_CONFIG; exit 1; }
echo "::add-mask::$T"; echo "::add-mask::$U"
NS=$(oci os ns get --query data --raw-output 2>/tmp/e) || { say "NAMESPACE_ERROR $(classify /tmp/e)"; exit 1; }
echo "::add-mask::$NS"

# 3. Baton helpers (every write is conditional)
ETAG=""; SEQ=0
read_baton(){
  if oci os object head -ns "$NS" -bn "$BUCKET" --name "$OBJ" > /tmp/h.json 2>/tmp/e; then
    ETAG=$(jq -r '.etag // empty' /tmp/h.json); local lm; lm=$(jq -r '."last-modified" // empty' /tmp/h.json)
    [ -n "$ETAG" ] && [ -n "$lm" ] || { say BATON_READ_ERROR; exit 1; }
    oci os object get -ns "$NS" -bn "$BUCKET" --name "$OBJ" --file /tmp/b.json >/dev/null 2>/tmp/e || { say "BATON_READ_ERROR $(classify /tmp/e)"; exit 1; }
    jq -e '(.owner|type=="string") and (.status|type=="string") and (.seq|type=="number")' /tmp/b.json >/dev/null 2>&1 || { say BATON_MALFORMED; exit 1; }
    OWNER=$(jq -r .owner /tmp/b.json); STATUS=$(jq -r .status /tmp/b.json); SEQ=$(jq -r .seq /tmp/b.json)
    AGE=$(( $(date -u +%s) - $(date -u -d "$lm" +%s) )); B=ok
  elif grep -q '"status": 404' /tmp/e; then B=missing; ETAG=""; SEQ=0; OWNER=""; STATUS=""; AGE=0
  else say "BATON_READ_ERROR $(classify /tmp/e)"; exit 1; fi; }
write_baton(){ local st=$1 q=$((SEQ+1)) cond
  jq -n --arg h "$HOLDER" --arg s "$st" --arg t "$(date -u +%FT%TZ)" --argjson q "$q" \
     '{v:1,owner:"github",holder:$h,status:$s,updated_at:$t,seq:$q}' > /tmp/n.json
  if [ -z "$ETAG" ]; then cond=(--no-overwrite); else cond=(--if-match "$ETAG" --force); fi
  oci os object put -ns "$NS" -bn "$BUCKET" --name "$OBJ" --file /tmp/n.json --content-type application/json "${cond[@]}" > /tmp/p.json 2>/tmp/e || return 1
  local ne; ne=$(jq -r '.etag // empty' /tmp/p.json 2>/dev/null || true)
  [ -n "$ne" ] && [ "$ne" != null ] || return 1
  ETAG=$ne; SEQ=$q; }
release(){ write_baton idle >/dev/null 2>&1 || true; }
mark_launched(){ local i; for i in 1 2 3; do
    write_baton launched && return 0
    oci os object head -ns "$NS" -bn "$BUCKET" --name "$OBJ" > /tmp/h.json 2>/dev/null && ETAG=$(jq -r '.etag // empty' /tmp/h.json) || true
    sleep 2; done; say WARN_LAUNCHED_WRITE_FAILED; return 1; }
count_servers(){
  oci compute instance list -c "$T" --display-name "$NAME" --all > /tmp/l.json 2>/tmp/e || { say "LIST_ERROR $(classify /tmp/e)"; release; exit 1; }
  [ -s /tmp/l.json ] || echo '{"data":[]}' > /tmp/l.json
  jq '[.data[] | select(."lifecycle-state" != "TERMINATED")] | length' /tmp/l.json; }

# 4. Take the baton or yield
read_baton
if [ "$B" = ok ] && [ "$STATUS" = launched ]; then say LAUNCHED_ALREADY; disable_wf; exit 0; fi
if [ "$B" = ok ] && [ "$OWNER" = cloudshell ] && [ "$STATUS" != stopped ] && [ "$AGE" -lt "$CS_STALE" ]; then
  say "LEASE_HELD_BY_CLOUDSHELL (${AGE}s old)"; exit 0; fi
write_baton trying || { say LEASE_LOST; exit 0; }

# 5. Stop for good if any non-TERMINATED n8n-server exists
C=$(count_servers); if [ "$C" != 0 ]; then mark_launched || true; disable_wf; say SERVER_EXISTS; exit 0; fi

# 6. Exact resources (fail closed)
ADS=$(oci iam availability-domain list -c "$T" 2>/tmp/e) || { say "AD_ERROR $(classify /tmp/e)"; release; exit 1; }
[ "$(jq '.data|length' <<<"$ADS")" = 1 ] || { say AD_UNEXPECTED; release; exit 1; }
AD=$(jq -r '.data[0].name' <<<"$ADS"); case "$AD" in *AF-JOHANNESBURG-1-AD-1) ;; *) say AD_UNEXPECTED; release; exit 1;; esac
VCN=$(oci network vcn list -c "$T" --display-name n8n-network --all 2>/tmp/e | jq -r 'if (.data|length)==1 then .data[0].id else empty end') || true
[ -n "$VCN" ] || { say VCN_NOT_FOUND_ONCE; release; exit 1; }
SUBNET=$(oci network subnet list -c "$T" --vcn-id "$VCN" --display-name "public subnet-n8n-network" --all 2>/tmp/e \
  | jq -r 'if (.data|length)==1 and (.data[0]."prohibit-public-ip-on-vnic"==false) then .data[0].id else empty end') || true
[ -n "$SUBNET" ] || { say SUBNET_NOT_FOUND_ONCE; release; exit 1; }
PICK=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all 2>/tmp/e \
  | jq -c '[.data[] | select(."display-name"|test("aarch64")) | select(."display-name"|test("Minimal")|not)][0] // empty') || true
[ -n "$PICK" ] || { say IMAGE_NOT_FOUND; release; exit 1; }
IMAGE=$(jq -r .id <<<"$PICK"); IMG_NAME=$(jq -r '."display-name"' <<<"$PICK")
for v in "$AD" "$VCN" "$SUBNET" "$IMAGE"; do echo "::add-mask::$v"; done
echo "Checks: AD-1 ok | subnet: public subnet-n8n-network | image: $IMG_NAME | shape: A1.Flex 1 OCPU / 6 GB"

# 7. Launch gate: only MODE=launch AND ENABLE_LAUNCH exactly "yes"
if [ "${MODE:-}" != launch ] || [ "${ENABLE_LAUNCH:-}" != yes ]; then release; say DRY_RUN_OK; exit 0; fi

# 8. One launch attempt
write_baton launching || { say LEASE_LOST; exit 0; }
C=$(count_servers); if [ "$C" != 0 ]; then mark_launched || true; disable_wf; say SERVER_EXISTS; exit 0; fi
set +e
oci compute instance launch --no-retry --availability-domain "$AD" -c "$T" \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":1,"memoryInGBs":6}' \
  --display-name "$NAME" --image-id "$IMAGE" --subnet-id "$SUBNET" \
  --assign-public-ip true --ssh-authorized-keys-file ~/.oci/n8n.pub > /tmp/o.json 2>/tmp/e
RC=$?
set -e
ID=$(jq -r '.data.id // empty' /tmp/o.json 2>/dev/null || true)
if [ "$RC" -eq 0 ] && [[ "$ID" == ocid1.instance.* ]]; then
  mark_launched || true
  disable_wf
  curl -sS -m 20 --fail -o /dev/null "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=Your Oracle n8n-server was created (GitHub retrier). Open Oracle Console > Compute > Instances." \
    || say WARN_TELEGRAM_FAILED
  say SUCCESS; exit 0
fi
R=$(classify /tmp/e); release
case "$R" in NO_CAPACITY|RATE_LIMITED) say "$R"; exit 0;; *) say "LAUNCH_FAILED $R"; exit 1;; esac
