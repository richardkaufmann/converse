# Shared by build.sh and release.sh (zsh).
# Explicit selection wins. Otherwise use the sole valid Developer ID identity;
# machines without one can still build a local, ad-hoc-signed app.
converse_signing_identity() {
  if [[ -n "${CONVERSE_SIGN_IDENTITY:-}" ]]; then
    print -r -- "$CONVERSE_SIGN_IDENTITY"
    return
  fi
  local found
  found=$(security find-identity -v -p codesigning | sed -nE '/"Developer ID Application:/{s/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) .*/\1/p;}')
  if [[ -z "$found" ]]; then
    print -r -- '-'
    return
  fi
  local -a identities
  identities=("${(@f)found}")
  if (( ${#identities} != 1 )); then
    print -u2 'Multiple valid Developer ID identities found. Set CONVERSE_SIGN_IDENTITY to the desired certificate SHA-1 or full name.'
    return 1
  fi
  print -r -- "$identities[1]"
}

# Resolve aliases such as /var -> /private/var before comparing process paths.
converse_require_stopped_app() {
  local executable="${1:A}/Contents/MacOS/Converse"
  local commands process_command
  commands=$(ps -axo comm=) || {
    print -u2 'Could not check running apps; no bundle will be modified.'
    return 1
  }
  for process_command in "${(@f)commands}"; do
    if [[ "$process_command" == */Contents/MacOS/Converse && "${process_command:A}" == "$executable" ]]; then
      print -u2 "Refusing to modify a running app: ${1:A}"
      print -u2 'Quit that app first, or choose a different CONVERSE_APP_OUTPUT.'
      return 1
    fi
  done
  return 0
}
