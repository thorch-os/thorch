#!/usr/bin/env bash

package_version_preferred() {
  local candidate_version="$1"
  local current_version="$2"
  local expected_version="${3:-}"
  local comparison

  if [[ -n "${expected_version}" ]]; then
    if [[ "${candidate_version}" == "${expected_version}" &&
          "${current_version}" != "${expected_version}" ]]; then
      return 0
    fi
    if [[ "${current_version}" == "${expected_version}" &&
          "${candidate_version}" != "${expected_version}" ]]; then
      return 1
    fi
  fi

  comparison="$(vercmp "${candidate_version}" "${current_version}")"
  (( comparison > 0 ))
}
