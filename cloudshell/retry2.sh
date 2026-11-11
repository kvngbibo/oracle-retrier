#!/usr/bin/env bash
# Cloud Shell side of the Oracle "baton" retrier (Automate with Bibo).
# Takes turns with the GitHub Actions retrier through retrier-baton/baton.json.
# Contains no secrets. Start:  nohup bash ~/retry2.sh >> ~/retry2.log 2>&1 &
set -uo pipefail
BUCKET=retrier-baton; OBJ=baton.json; NAME=n8n-server
GH_STALE=2700      # GitHub lease is stale after 45 min
CS_STALE=900       # another Cloud Shell lease is stale after 15 min
GAP_MAX=600        # if this script was frozen > 10 min, log it (baton is re-checked every loop anyway)
HOLDER="cs-$$-$RANDOM"
T="${OCI_TENANCY:-}"; PUB=~/n8n-key.pub
LOG(){ echo "$(date -u +%F' '%T) $*"; }
classify(){ local f=$1
  if grep -qiE 'out of (host )?capacity' "$f"; then echo NO_CAPACITY
  elif grep -qE 'TooManyRequests|"status": 429' "$f"; then echo RATE_LIMITED
  elif grep -q 'NotAuthorizedOrNotFound' "$f"; then echo AUTH_ERROR
  else echo "OTHER $(grep -o '"status": [0-9]*' "$f" | head -1) $(grep -o '"code": "[^"]*"' "$f" | head -1)"; fi; }
[ -n "$T" ] || { LOG "OCI_TENANCY not set - stop"; exit 1; }
[ -s "$PUB" ] || { LOG "missing $PUB - stop"; exit 1; }
NS=$(oci os ns get --query data --raw-output 2>/tmp/cs_e) || { LOG "NAMESPACE_ERROR $(classify /tmp/cs_e)"; exit 1; }

ETAG=""; SEQ=0; OWNER=""; STATUS=""; HOLD_IN=""; AGE=0; B=""
read_baton(){
  if oci os object head -ns "$NS" -bn "$BUCKET" --name "$OBJ" > /tmp/cs_h.json 2>/tmp/cs_e; then
    ETAG=$(jq -r '.etag // empty' /tmp/cs_h.json); local lm; lm=$(jq -r '."last-modified" // empty' /tmp/cs_h.json)
    [ -n "$ETAG" ] && [ -n "$lm" ] || return 2
    oci os object get -ns "$NS" -bn "$BUCKET" --name "$OBJ" --file /tmp/cs_b.json >/dev/null 2>/tmp/cs_e || return 2
    jq -e '(.owner|type=="string") and (.status|type=="string") and (.seq|type=="number")' /tmp/cs_b.json >/dev/null 2>&1 || return 3
    OWNER=$(jq -r .owner /tmp/cs_b.json); STATUS=$(jq -r .status /tmp/cs_b.json)
    HOLD_IN=$(jq -r '.holder // ""' /tmp/cs_b.json); SEQ=$(jq -r .seq /tmp/cs_b.json)
    AGE=$(( $(date -u +%s) - $(date -u -d "$lm" +%s) )); B=ok; return 0
  elif grep -q '"status": 404' /tmp/cs_e; then B=missing; ETAG=""; SEQ=0; OWNER=""; STATUS=""; HOLD_IN=""; AGE=0; return 0
  else return 2; fi; }
write_baton(){ local st=$1 q=$((SEQ+1)) cond
  jq -n --arg h "$HOLDER" --arg s "$st" --arg t "$(date -u +%FT%TZ)" --argjson q "$q" \
     '{v:1,owner:"cloudshell",holder:$h,status:$s,updated_at:$t,seq:$q}' > /tmp/cs_n.json
  if [ -z "$ETAG" ]; then cond=(--no-overwrite); else cond=(--if-match "$ETAG" --force); fi
  oci os object put -ns "$NS" -bn "$BUCKET" --name "$OBJ" --file /tmp/cs_n.json --content-type application/json "${cond[@]}" > /tmp/cs_p.json 2>/tmp/cs_e || return 1
  local ne; ne=$(jq -r '.etag // empty' /tmp/cs_p.json 2>/dev/null || true)
  [ -n "$ne" ] && [ "$ne" != null ] || return 1
  ETAG=$ne; SEQ=$q; return 0; }
mark_launched(){ local i; for i in 1 2 3; do
    write_baton launched && return 0
    read_baton >/dev/null 2>&1 || true; sleep 2; done; LOG "WARN could not write launched"; return 1; }
count_servers(){
  oci compute instance list -c "$T" --display-name "$NAME" --all > /tmp/cs_l.json 2>/tmp/cs_e || return 1
  [ -s /tmp/cs_l.json ] || echo '{"data":[]}' > /tmp/cs_l.json
  jq '[.data[] | select(."lifecycle-state" != "TERMINATED")] | length' /tmp/cs_l.json; }
on_exit(){ if read_baton && [ "$B" = ok ] && [ "$OWNER" = cloudshell ] && [ "$HOLD_IN" = "$HOLDER" ] && [ "$STATUS" != launched ]; then
    write_baton stopped && LOG "stopped - baton released"; fi; exit 0; }
trap on_exit INT TERM

# Resources (exact, fail closed)
ADS=$(oci iam availability-domain list -c "$T" 2>/tmp/cs_e) || { LOG "AD_ERROR $(classify /tmp/cs_e)"; exit 1; }
[ "$(jq '.data|length' <<<"$ADS")" = 1 ] || { LOG AD_UNEXPECTED; exit 1; }
AD=$(jq -r '.data[0].name' <<<"$ADS"); case "$AD" in *AF-JOHANNESBURG-1-AD-1) ;; *) LOG AD_UNEXPECTED; exit 1;; esac
VCN=$(oci network vcn list -c "$T" --display-name n8n-network --all 2>/dev/null | jq -r 'if (.data|length)==1 then .data[0].id else empty end')
[ -n "$VCN" ] || { LOG VCN_NOT_FOUND_ONCE; exit 1; }
SUBNET=$(oci network subnet list -c "$T" --vcn-id "$VCN" --display-name "public subnet-n8n-network" --all 2>/dev/null \
  | jq -r 'if (.data|length)==1 and (.data[0]."prohibit-public-ip-on-vnic"==false) then .data[0].id else empty end')
[ -n "$SUBNET" ] || { LOG SUBNET_NOT_FOUND_ONCE; exit 1; }
PICK=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all 2>/dev/null \
  | jq -c '[.data[] | select(."display-name"|test("aarch64")) | select(."display-name"|test("Minimal")|not)][0] // empty')
[ -n "$PICK" ] || { LOG IMAGE_NOT_FOUND; exit 1; }
IMAGE=$(jq -r .id <<<"$PICK"); LOG "start $HOLDER | image $(jq -r '."display-name"' <<<"$PICK") | A1 1 OCPU / 6 GB"

LAST_OK=0
while true; do
  now=$(date -u +%s)
  [ "$LAST_OK" -gt 0 ] && [ $((now-LAST_OK)) -gt "$GAP_MAX" ] && LOG "was paused $((now-LAST_OK))s - re-checking baton"
  read_baton; rc=$?
  if [ $rc -eq 3 ]; then LOG "BATON_MALFORMED - stop (fix baton.json by hand)"; exit 1; fi
  if [ $rc -ne 0 ]; then LOG "baton read error - no try"; sleep 60; continue; fi
  if [ "$B" = ok ] && [ "$STATUS" = launched ]; then LOG "baton says LAUNCHED - stop"; exit 0; fi
  take=no
  if [ "$B" = missing ]; then take=yes
  elif [ "$OWNER" = cloudshell ] && [ "$HOLD_IN" = "$HOLDER" ]; then take=yes
  elif [ "$OWNER" = cloudshell ]; then { [ "$STATUS" = stopped ] || [ "$AGE" -gt "$CS_STALE" ]; } && take=yes
  elif [ "$OWNER" = github ]; then { [ "$STATUS" = idle ] || [ "$STATUS" = stopped ] || [ "$AGE" -gt "$GH_STALE" ]; } && take=yes
  fi
  if [ "$take" != yes ]; then LOG "waiting - baton held by $OWNER ($STATUS, ${AGE}s)"; sleep 60; continue; fi
  write_baton trying || { LOG "baton taken by other side"; sleep 60; continue; }
  LAST_OK=$(date -u +%s)
  C=$(count_servers) || { LOG "LIST_ERROR - no try"; sleep 60; continue; }
  if [ "$C" != 0 ]; then mark_launched; LOG "n8n-server already exists - stop"; exit 0; fi
  write_baton launching || { LOG "baton taken by other side"; sleep 60; continue; }
  oci compute instance launch --no-retry --availability-domain "$AD" -c "$T" \
    --shape VM.Standard.A1.Flex --shape-config '{"ocpus":1,"memoryInGBs":6}' \
    --display-name "$NAME" --image-id "$IMAGE" --subnet-id "$SUBNET" \
    --assign-public-ip true --ssh-authorized-keys-file "$PUB" > /tmp/cs_o.json 2>/tmp/cs_e
  lrc=$?
  ID=$(jq -r '.data.id // empty' /tmp/cs_o.json 2>/dev/null)
  if [ $lrc -eq 0 ] && [[ "$ID" == ocid1.instance.* ]]; then
    mark_launched; LOG "SUCCESS - n8n-server is being created"; sleep 90
    VN=$(oci compute instance list-vnics --instance-id "$ID" 2>/dev/null | jq -r '.data[0]."public-ip" // "not ready yet"')
    LOG "PUBLIC IP: $VN"; exit 0
  fi
  R=$(classify /tmp/cs_e)
  write_baton trying >/dev/null 2>&1 || true
  case "$R" in
    NO_CAPACITY) LOG "not yet (no capacity)"; sleep 60;;
    RATE_LIMITED) LOG "not yet (rate limited) - wait 180s"; sleep 180;;
    *) LOG "UNEXPECTED: $R - stop"; on_exit;;
  esac
done
