#!/bin/bash

# Make a test to check if yq, git, flux, dirname, xargs are installed

trap 'rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt tmp-flux-diff.txt tmp-flux-diff-redacted.txt tmp-flux-diff-scrubbed.txt tmp-sync-files.txt' EXIT

# Check if yq is installed
if ! command -v yq &> /dev/null; then
  echo "yq could not be found. Please install yq to run this script."
  exit 1
fi
# Check if git is installed
if ! command -v git &> /dev/null; then
  echo "git could not be found. Please install git to run this script."
  exit 1
fi
# Check if flux is installed
if ! command -v flux &> /dev/null; then
  echo "flux could not be found. Please install flux to run this script."
  exit 1
fi
# Check if dirname is installed
if ! command -v dirname &> /dev/null; then
  echo "dirname could not be found. Please install dirname to run this script."
  exit 1
fi
# Check if xargs is installed
if ! command -v xargs &> /dev/null; then
  echo "xargs could not be found. Please install xargs to run this script."
  exit 1
fi


# Find all changed files compared to main branch
: > tmp-changed-files.txt
: > tmp-changed-dirs.txt
if [ -n "$PATH_FILTER" ]; then
  # Split only on commas so paths containing spaces remain a single pathspec.
  IFS=',' read -r -a path_filters <<< "$PATH_FILTER"
  for path in "${path_filters[@]}"; do
    git diff origin/main --name-only -z -- "$path" >> tmp-changed-files.txt
  done
else
  git diff origin/main --name-only -z >> tmp-changed-files.txt
fi

# Autodetect tenants to ignore by finding new sync.yaml files in tenant directory
if [ "$AUTODETECT_IGNORE_TENANTS" = "true" ]; then
  # Find all new sync.yaml files in tenant directories
  git diff origin/main --diff-filter=A --name-only -z -- "tenants/**/sync.yaml" > tmp-sync-files.txt

  # Extract tenant name from the tenant sync.yaml files
  while IFS= read -r -d '' file;
  do
    # Get tenant name from sync.yaml file
    TENANT=$(yq '.metadata.name' "$file")
    if [ "$TENANT" != null ]; then
      # Append tenant name to IGNORE_TENANTS variable
      if [ -z "$IGNORE_TENANTS" ]; then
        IGNORE_TENANTS="$TENANT"
      else
        IGNORE_TENANTS="$IGNORE_TENANTS,$TENANT"
      fi
    fi
  done < tmp-sync-files.txt
  unset TENANT
fi

# Checks if the file 'tmp-changed-files.txt' exists and is not empty before processing.
# Git permits whitespace in filenames, so preserve NUL delimiters while extracting
# and deduplicating the directories.
if [ -s tmp-changed-files.txt ]; then
  xargs -r -0 -n1 dirname -z -- < tmp-changed-files.txt | sort -zu > tmp-changed-dirs.txt
fi

: > tmp-changed-kustomization-dirs.txt
while IFS= read -r -d '' dir;
do
  # Check if kustomization.yaml exists in directory and if directory is not already in tmp-changed-kustomization-dirs.txt
  if [ -f "$dir/kustomization.yaml" ] && ! grep -Fzxq -- "$dir" tmp-changed-kustomization-dirs.txt; then
    # Add directory to tmp-changed-kustomization-dirs.txt
    printf '%s\0' "$dir" >> tmp-changed-kustomization-dirs.txt
  fi
done < tmp-changed-dirs.txt


if [ -s tmp-changed-kustomization-dirs.txt ]; then
  # Print all changed kustomization directories
  printf "\n----------Folders to flux diff:----------\n"
  tr '\0' '\n' < tmp-changed-kustomization-dirs.txt

  # Create output file.
  touch diff-output.txt
  # Loop over all lines in tmp-changed-kustomization-dirs and do diff against cluster
  while IFS= read -r -d '' dir <&3;
  do
    # Get tenant name and namespace from header comment in kustomization.yaml on the form:
    # flux-tenant-name: <tenant-name>
    # flux-tenant-ns: <tenant-namespace>
    TENANT=$(yq '... | headComment | select(. != "")' "$dir/kustomization.yaml" | grep flux-tenant-name | yq '.flux-tenant-name')
    NAMESPACE=$(yq '... | headComment | select(. != "")' "$dir/kustomization.yaml" | grep flux-tenant-ns | yq '.flux-tenant-ns')


    if [ "$TENANT" == null ] || [ "$NAMESPACE" == null ]; then
      printf "\nNo 'flux-tenant-name' and/or 'flux-tenant-ns' comment found in %s/kustomization.yaml. Skipping diff.\n" "$dir" | tee -a diff-output.txt
      continue
    fi

    # Check if kustomization file has tenant header comment. If not, skip
    printf '\n---------- Flux diffing %s----------\n' "$dir"

    if ! [[ "$TENANT" == null ]] ; then
      # Check if the tenant should be ignored
      if [[ ",$IGNORE_TENANTS," == *",$TENANT,"* ]]; then
        printf -- '\n---\xE2\x9C\x93 Tenant %s ignored. Skipping diff for %s---\n' "$TENANT" "$dir" | tee -a diff-output.txt
        printf -- 'Tenant is new and is assumed to not exist in cluster, or it is explicitly ignored.\n' | tee -a diff-output.txt
        continue
      else
        # Perform flux diff.
        # Capture BOTH stdout and stderr: flux writes the diff to stdout, but
        # emits dry-run error blocks (✗ [ ... ]) to stderr. The RBAC-skip
        # classifier below reads this file, so it must contain the error block —
        # otherwise every failed dry-run looks like a generic error.
        flux diff kustomization "$TENANT" --path "$dir" --progress-bar=false -n "$NAMESPACE" > tmp-flux-diff.txt 2>&1
        # Capture flux's exit code immediately; the redaction pipeline below would
        # otherwise overwrite $? before the `case` statement inspects it.
        FLUX_DIFF_RC=$?

        # Redact Secret values from the diff output.
        # `flux diff` reads live Secrets from the cluster to compute the diff and
        # can emit their `data`/`stringData` contents into the output, which then
        # ends up in workflow logs and PR comments. We keep the fact that a Secret
        # changed (keys, add/remove) visible, but replace every value under a
        # `data:` or `stringData:` block with a fixed placeholder so no secret
        # material leaks. Diff line prefixes (space, +, -) are preserved.
        #
        # Behaviour: once inside a `data:`/`stringData:` block, every more-indented
        # `key: value` line has its value replaced with `<redacted>`. The block
        # ends when a line returns to the indentation of the `data:` key or less.
        #
        # Fail-closed: if this redaction pass itself errors out for any reason,
        # `&&` below would otherwise short-circuit and let the ORIGINAL,
        # unredacted content silently fall through to a public PR comment. We
        # explicitly check the exit status and replace the content with a safe
        # placeholder on failure instead of ever printing unscrubbed output.
        if awk '
          {
            line = $0
            # Strip a leading diff marker (space/+/-) for indentation analysis.
            marker = ""
            body = line
            if (line ~ /^[ +-]/) { marker = substr(line, 1, 1); body = substr(line, 2) }

            # Current indentation (leading spaces of the body).
            match(body, /^ */); indent = RLENGTH

            # Detect entering a data/stringData block.
            if (body ~ /^ *(data|stringData): *$/) {
              in_secret = 1
              secret_indent = indent
              print line
              next
            }

            if (in_secret) {
              # Leaving the block when indentation is back at/above the key level
              # on a non-blank line.
              if (body !~ /^ *$/ && indent <= secret_indent) {
                in_secret = 0
              } else if (body ~ /^ *[^ :][^:]*: */) {
                # A "key: value" entry inside the block: redact the value.
                sub(/: *.*$/, ": <redacted>", body)
                print marker body
                next
              }
            }
            print line
          }
        ' tmp-flux-diff.txt > tmp-flux-diff-redacted.txt; then
          mv tmp-flux-diff-redacted.txt tmp-flux-diff.txt
        else
          echo "::warning::Secret redaction pass failed, suppressing raw output for safety" >&2
          echo "[Output suppressed: redaction step failed]" > tmp-flux-diff.txt
        fi

        # Scrub JWT-shaped bearer tokens and RFC1918 private/internal IP
        # addresses that may appear inline anywhere in the output (e.g. API
        # server URLs, "dial tcp" connection errors). This runs universally
        # over the whole file — not just inside data:/stringData: blocks —
        # because this content is genuine, unstructured error prose (TLS/
        # connection errors, admission-webhook bodies, etc.) that does not
        # match the YAML-shaped Secret redaction above, and it flows into a
        # PUBLIC PR comment on the genuine-failure branch below. This is a
        # best-effort pattern scrub, not a full parser — it does not attempt
        # to catch every possible secret shape or internal hostname.
        #
        # Implementation note: an earlier version of this scrub used sed with
        # a hand-rolled boundary emulation
        # (`([^0-9.]|^)PATTERN([^0-9.]|$)`). Because sed's global /g
        # substitution scans non-overlapping matches, the trailing boundary
        # character of one match was CONSUMED as part of the substitution, so
        # a second IP separated from the first by only a single delimiter
        # character (e.g. "tried 10.0.1.5:443, then 10.0.1.6:443") had no
        # leading boundary character left to anchor on and silently bypassed
        # redaction. awk's match()/substr() give us real non-consuming
        # boundary checks: we scan for each pattern, and only when found we
        # inspect (without consuming) the single character immediately before
        # and after the match to confirm it isn't itself part of a longer
        # digit/dot run, then advance past the match. If the boundary check
        # fails, we advance by one character (not by the match length) so
        # overlapping candidate positions are still considered.
        #
        # Fail-closed: same rationale as the Secret redaction above — check
        # the exit status explicitly and never let unscrubbed content fall
        # through to a public PR comment.
        if awk '
          # IP boundary: a digit immediately adjacent is always ambiguous
          # (part of a longer number). A literal "." immediately adjacent is
          # ONLY ambiguous if the character one further past it is also a
          # digit (genuine octet-continuation ambiguity, e.g. distinguishing
          # "10.0.0.5" in "10.0.0.5.6" from ordinary sentence-ending
          # punctuation in "10.0.0.5."). c2 is the character one position
          # further away from the match than c; it is only consulted when
          # c is ".".
          function is_ip_boundary(c, c2) {
            if (c == "") return 1
            if (c ~ /[0-9]/) return 0
            if (c == ".") return (c2 !~ /[0-9]/)
            return 1
          }
          # JWT boundary: anything that is not part of the base64url-ish
          # token alphabet counts as a valid boundary. Unlike IPs, JWTs have
          # no legitimate reason to be followed/preceded by a "." outside
          # the token itself (the pattern already matches the dot-separated
          # segments), so a bare not-alnum/underscore/hyphen check is
          # correct here and does not need the IP-specific lookahead.
          function is_jwt_boundary(c, c2) {
            if (c == "") return 1
            return (c !~ /[A-Za-z0-9_-]/)
          }
          function redact(line, pattern, placeholder, mode,    out, remaining, mstart, mlen, before, before2, after, after2, ok_before, ok_after) {
            out = ""
            remaining = line
            while (match(remaining, pattern)) {
              mstart = RSTART
              mlen = RLENGTH
              before = (mstart > 1) ? substr(remaining, mstart - 1, 1) : ""
              before2 = (mstart > 2) ? substr(remaining, mstart - 2, 1) : ""
              after = substr(remaining, mstart + mlen, 1)
              after2 = substr(remaining, mstart + mlen + 1, 1)
              if (mode == "jwt") {
                ok_before = is_jwt_boundary(before, before2)
                ok_after = is_jwt_boundary(after, after2)
              } else {
                ok_before = is_ip_boundary(before, before2)
                ok_after = is_ip_boundary(after, after2)
              }
              if (ok_before && ok_after) {
                out = out substr(remaining, 1, mstart - 1) placeholder
                remaining = substr(remaining, mstart + mlen)
              } else {
                # Not a real boundary-delimited match (e.g. part of a longer
                # number). Keep the first character literally and resume
                # scanning from the next position, WITHOUT consuming any
                # delimiter character a real match might need.
                out = out substr(remaining, 1, mstart)
                remaining = substr(remaining, mstart + 1)
              }
            }
            return out remaining
          }
          {
            line = $0
            line = redact(line, "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "<redacted-jwt>", "jwt")
            line = redact(line, "10(\\.[0-9]{1,3}){3}", "<redacted-ip>", "ip")
            line = redact(line, "172\\.(1[6-9]|2[0-9]|3[01])(\\.[0-9]{1,3}){2}", "<redacted-ip>", "ip")
            line = redact(line, "192\\.168(\\.[0-9]{1,3}){2}", "<redacted-ip>", "ip")
            print line
          }
        ' tmp-flux-diff.txt > tmp-flux-diff-scrubbed.txt; then
          mv tmp-flux-diff-scrubbed.txt tmp-flux-diff.txt
        else
          echo "::warning::JWT/IP scrub pass failed, suppressing raw output for safety" >&2
          echo "[Output suppressed: redaction step failed]" > tmp-flux-diff.txt
        fi

        # Check if flux diff was successful
        case $FLUX_DIFF_RC in
          0)
            printf -- '\n---\xE2\x9C\x93 No changes in %s---\n' "$dir"
            ;;
          1)
            printf -- '\n---\xE2\x9C\x93 Changes detected in %s---\n' "$dir" | tee -a diff-output.txt
            cat tmp-flux-diff.txt | tee -a diff-output.txt
            ;;
          *)
            # flux exited with an error (>1). Some of these are benign: a
            # least-privilege diff identity (see the svai-flux-diff ClusterRole)
            # deliberately has NO access to RBAC objects (Role/RoleBinding/
            # ClusterRole/ClusterRoleBinding), because diffing them would require
            # the escalation/bind verbs and turn the identity into a privilege-
            # escalation surface. flux reports those objects as dry-run
            # "Forbidden" or "not found" errors.
            #
            # We skip the diff for a kustomization ONLY when every error entry in
            # the flux output refers to an RBAC object. If ANY non-RBAC error is
            # present we fail as before, so genuine problems are never masked.
            #
            # flux packs errors into a bracketed, comma-separated block that may
            # span multiple lines and be very long, e.g.:
            #   ✗ [Role/ns/name dry-run failed (Forbidden): ... not currently held:
            #      {APIGroups:["apps"], Resources:["deployments/scale"], ...},
            #      RoleBinding/ns/name not found: ...]
            # We extract the content AFTER the opening "✗ [" WITHOUT requiring a
            # closing "]" (the block can be huge; we must not depend on matching
            # the bracket), then split into entries on ", <Kind>/" where <Kind>
            # starts uppercase (so lowercase tokens like "deployments/scale"
            # inside detail braces are not treated as entries).
            FLAT_DIFF=$(tr '\n' ' ' < tmp-flux-diff.txt)

            NON_RBAC_ERRORS=0
            HAS_RBAC_SKIP=0
            HAS_ASO_SKIP=0
            case "$FLAT_DIFF" in
              *"✗ ["*)
                # Take everything after the first "✗ [", then drop a trailing "]".
                ERROR_BLOCK=${FLAT_DIFF#*✗ [}
                ERROR_BLOCK=${ERROR_BLOCK%]*}

                RBAC_KIND_RE='^(Role|RoleBinding|ClusterRole|ClusterRoleBinding)/'
                # Azure Service Operator (ASO) resource kinds deliberately narrowed to
                # read-only by PLT-4806 in the svai-flux-diff ClusterRole — write access
                # to any of these is a confirmed Azure privilege-escalation path (ASO's
                # own controller holds subscription-Owner in every tenant this org
                # operates in), so a Forbidden error on these specific kinds is expected
                # and by design, exactly like the RBAC-object case above. See PLT-4907.
                ASO_KIND_RE='^(ResourceGroup|RoleAssignment|UserAssignedIdentity|FederatedIdentityCredential|SqlRoleAssignment|RedisAccessPolicyAssignment|RedisEnterpriseDatabaseAccessPolicyAssignment)/'
                ERROR_ENTRIES=$(echo "$ERROR_BLOCK" | sed 's/, \([A-Z][A-Za-z]*\/\)/\n\1/g')
                while IFS= read -r entry; do
                  # Only entry-start lines begin with "<UpperKind>/"; skip detail lines.
                  echo "$entry" | grep -Eq '^[A-Z][A-Za-z]*/' || continue
                  if echo "$entry" | grep -Eq "$RBAC_KIND_RE"; then
                    HAS_RBAC_SKIP=1
                  elif echo "$entry" | grep -Eq "$ASO_KIND_RE"; then
                    HAS_ASO_SKIP=1
                  else
                    NON_RBAC_ERRORS=1
                  fi
                done <<< "$ERROR_ENTRIES"

                # Fail-safe: if the flux output has an opening "✗ [" but NO closing
                # "]" anywhere, it was truncated and an unseen non-RBAC error could
                # be hiding in the tail. Do not skip on truncated output.
                case "$FLAT_DIFF" in
                  *"]"*) : ;;
                  *) NON_RBAC_ERRORS=1 ;;
                esac
                ;;
              *)
                # No flux error block at all (e.g. a build failure) — genuine error.
                NON_RBAC_ERRORS=1
                ;;
            esac

            if [ "$NON_RBAC_ERRORS" -eq 0 ] && { [ "$HAS_RBAC_SKIP" -eq 1 ] || [ "$HAS_ASO_SKIP" -eq 1 ]; }; then
              # All ERRORS are known-by-design-skippable (RBAC objects and/or the 7
              # ASO kinds narrowed by PLT-4806), so we do not fail. But the same
              # kustomization may ALSO contain real drift that flux computed and
              # printed (e.g. a HelmRelease or CronJob change) — flux still exits
              # non-zero because of the forbidden objects, which is why we land
              # here. We must therefore still surface that real drift, and only
              # replace the error block with the "skipped" notice(s) below.
              #
              # flux prints the drift first and the "✗ [ ... ]" error summary last.
              # Print everything up to the "✗ [" line, then the skip notice(s).
              PRE_ERROR=$(sed '/✗ \[/,$d' tmp-flux-diff.txt)
              if [ -n "$(echo "$PRE_ERROR" | tr -d '[:space:]')" ]; then
                # There is real drift to show.
                printf -- '\n---\xE2\x9C\x93 Changes detected in %s---\n' "$dir" | tee -a diff-output.txt
                echo "$PRE_ERROR" | tee -a diff-output.txt
              fi
              if [ "$HAS_RBAC_SKIP" -eq 1 ]; then
                printf -- '\n---\xe2\x9a\xa0 RBAC objects skipped in %s---\n' "$dir" | tee -a diff-output.txt
                printf -- 'The flux-diff identity has no access to RBAC objects (Role/RoleBinding/ClusterRole/ClusterRoleBinding) by design. These are not diffed against the cluster; review their YAML in the PR directly.\n' | tee -a diff-output.txt
              fi
              if [ "$HAS_ASO_SKIP" -eq 1 ]; then
                printf -- '\n---\xe2\x9a\xa0 Azure Service Operator identity/permission objects skipped in %s---\n' "$dir" | tee -a diff-output.txt
                printf -- 'The flux-diff identity has read-only access to these Azure Service Operator (ASO) resource types (ResourceGroup, RoleAssignment, UserAssignedIdentity, FederatedIdentityCredential, SqlRoleAssignment, RedisAccessPolicyAssignment, RedisEnterpriseDatabaseAccessPolicyAssignment) by design (PLT-4806) — write access to any of them is a confirmed Azure privilege-escalation path. These are not diffed against the cluster; review their YAML in the PR directly.\n' | tee -a diff-output.txt
              fi
              continue
            fi

            # Surface the genuine failure. tmp-flux-diff.txt already went through
            # both the Secret-redaction pipeline AND the JWT/IP scrub pass
            # above (applied universally to the whole file, since this is
            # genuine, unpredictable error prose — connection/TLS errors,
            # non-RBAC Forbidden/admission-webhook bodies, etc. — that is not
            # shaped like a Kubernetes manifest and would not otherwise be
            # caught by the data:/stringData: block redaction). It is
            # therefore safe to print in full and to append to
            # diff-output.txt: the latter is what the "Set diff output" step
            # in action.yaml exposes as the `diff-output` action output,
            # which downstream workflows use to build the PR comment body.
            # Without this, only the generic banner below was ever visible,
            # making every genuine failure undiagnosable from CI logs or PR
            # comments.
            printf -- '\n---\xe2\x9c\x97 An error occurred when diffing %s. Exit 1.---\n' "$dir" | tee -a diff-output.txt
            printf -- '\n----------flux diff output (%s)----------\n' "$dir" | tee -a diff-output.txt
            cat tmp-flux-diff.txt | tee -a diff-output.txt
            exit 1
            ;;
        esac
        continue
      fi
    fi
    # flux diff against cluster
  done 3< tmp-changed-kustomization-dirs.txt
fi

# Check if diff-output.txt is empty and add "No changes" if it is
if [ ! -s diff-output.txt ]; then
  echo "No changes" >> diff-output.txt
fi

exit 0
