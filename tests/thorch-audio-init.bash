#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audio_init="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-audio-init"
unit="${root}/packages/thorch-kde-defaults/payload/usr/lib/systemd/user/thorch-audio-init.service"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

sh -n "${audio_init}" || fail "thorch-audio-init has invalid shell syntax"
if grep -Eq '^[[:space:]]*(alsaucm|amixer)([[:space:]]|$)' "${audio_init}"; then
  fail "audio init still races WirePlumber through raw ALSA controls"
fi
grep -Fq 'Wants=pipewire.service wireplumber.service pipewire-pulse.service' "${unit}" ||
  fail "audio init does not pull in the services it controls"
grep -Fxq 'Type=exec' "${unit}" ||
  fail "audio init blocks the user session while waiting for PipeWire objects"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
install -d "${tmp}/bin" "${tmp}/runtime" "${tmp}/cases"

cat >"${tmp}/bin/pactl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${THORCH_AUDIO_TEST_LOG}"

bump() {
  local counter="${THORCH_AUDIO_TEST_STATE}/$1"
  local value=0
  if [[ -f "${counter}" ]]; then
    read -r value <"${counter}"
  fi
  value=$((value + 1))
  printf '%s\n' "${value}" >"${counter}"
  printf '%s\n' "${value}"
}

case "$*" in
  'list short cards')
    attempt="$(bump cards)"
    if (( attempt < THORCH_AUDIO_TEST_CARD_AFTER )); then
      exit 1
    fi
    printf '59\talsa_card.platform-sound\talsa\n'
    ;;
  'list cards')
    attempt="$(bump profile)"
    if (( attempt < THORCH_AUDIO_TEST_PROFILE_AFTER )); then
      exit 1
    fi
    printf 'Card #59\n\tName: alsa_card.platform-sound\n\tActive Profile: %s\n' \
      "${THORCH_AUDIO_TEST_PROFILE}"
    ;;
  'list short sinks')
    printf '65\talsa_output.platform-sound.HiFi__Speaker__sink\tPipeWire\n'
    ;;
  'list short sources')
    attempt="$(bump sources)"
    if (( attempt < THORCH_AUDIO_TEST_SOURCE_AFTER )); then
      exit 0
    fi
    printf '66\talsa_input.platform-sound.HiFi__Mic__source\tPipeWire\n'
    ;;
  set-card-profile*|set-default-sink*|set-default-source*|set-sink-mute*|set-sink-volume*|set-source-volume*)
    ;;
  *)
    printf 'unexpected pactl invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "${tmp}/bin/pactl"

cat >"${tmp}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"${THORCH_AUDIO_TEST_LOG}"
EOF
chmod 755 "${tmp}/bin/sleep"

run_case() {
  local name="$1"
  local profile="$2"
  local card_after="${3:-1}"
  local profile_after="${4:-1}"
  local source_after="${5:-1}"
  local case_dir="${tmp}/cases/${name}"

  install -d "${case_dir}/state"
  : >"${case_dir}/pactl.log"
  PATH="${tmp}/bin:${PATH}" \
    XDG_RUNTIME_DIR="${tmp}/runtime" \
    THORCH_AUDIO_TEST_LOG="${case_dir}/pactl.log" \
    THORCH_AUDIO_TEST_STATE="${case_dir}/state" \
    THORCH_AUDIO_TEST_PROFILE="${profile}" \
    THORCH_AUDIO_TEST_CARD_AFTER="${card_after}" \
    THORCH_AUDIO_TEST_PROFILE_AFTER="${profile_after}" \
    THORCH_AUDIO_TEST_SOURCE_AFTER="${source_after}" \
    "${audio_init}"
}

preferred_profile='HiFi (Headphones, Mic, Speaker)'

run_case fast "${preferred_profile}"
fast_log="${tmp}/cases/fast/pactl.log"
if grep -q '^set-card-profile ' "${fast_log}"; then
  fail "audio init reapplies an already-active UCM profile"
fi
if grep -q '^sleep ' "${fast_log}"; then
  fail "audio init sleeps when all PipeWire objects are already available"
fi
grep -Fq 'set-default-sink alsa_output.platform-sound.HiFi__Speaker__sink' "${fast_log}" ||
  fail "audio init did not select the speaker sink"
grep -Fq 'set-default-source alsa_input.platform-sound.HiFi__Mic__source' "${fast_log}" ||
  fail "audio init did not select an immediately available microphone source"

run_case inactive off
inactive_log="${tmp}/cases/inactive/pactl.log"
[[ "$(grep -c '^set-card-profile ' "${inactive_log}")" -eq 1 ]] ||
  fail "audio init must select a missing profile exactly once"
grep -Fq 'set-card-profile alsa_card.platform-sound HiFi (Headphones, Mic, Speaker)' "${inactive_log}" ||
  fail "audio init did not select the preferred HiFi profile"

run_case transient "${preferred_profile}" 2 3
transient_log="${tmp}/cases/transient/pactl.log"
[[ "$(grep -c '^list short cards$' "${transient_log}")" -eq 2 ]] ||
  fail "audio init did not retry transient card discovery"
[[ "$(grep -c '^list cards$' "${transient_log}")" -eq 3 ]] ||
  fail "audio init did not retry transient profile discovery"
if grep -q '^set-card-profile ' "${transient_log}"; then
  fail "audio init changed the profile after transient discovery recovered"
fi

run_case late-source "${preferred_profile}" 1 1 3
late_source_log="${tmp}/cases/late-source/pactl.log"
[[ "$(grep -c '^list short sources$' "${late_source_log}")" -eq 3 ]] ||
  fail "audio init did not retry microphone source discovery"
grep -Fq 'set-default-source alsa_input.platform-sound.HiFi__Mic__source' "${late_source_log}" ||
  fail "audio init did not select a microphone source that appeared later"

run_case missing-source "${preferred_profile}" 1 1 99
missing_source_log="${tmp}/cases/missing-source/pactl.log"
[[ "$(grep -c '^list short sources$' "${missing_source_log}")" -eq 5 ]] ||
  fail "audio init did not bound microphone source discovery retries"
if grep -q '^set-default-source ' "${missing_source_log}"; then
  fail "audio init selected a microphone source that never appeared"
fi

printf 'thorch audio init checks passed\n'
