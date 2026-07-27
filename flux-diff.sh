# Make a test to check if yq, git, flux, dirname, xargs are installed
#!/bin/bash

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
if [ -n "$PATH_FILTER" ]; then
  # Convert comma separated PATH_FILTER to space separated
  PATH_FILTER=$(echo "$PATH_FILTER" | tr ',' ' ')
  for path in $PATH_FILTER; do
    # Check if path filter is valid. If not, skip
    if ! git ls-files --error-unmatch "$path" > /dev/null 2>&1; then
      continue
    fi
    git diff origin/main --name-only "$path" >> tmp-changed-files.txt
  done
else
  git diff origin/main --name-only > tmp-changed-files.txt
fi

# Autodetect tenants to ignore by finding new sync.yaml files in tenant directory
if [ "$AUTODETECT_IGNORE_TENANTS" = "true" ]; then
  # Find all new sync.yaml files in tenant directories
  git diff origin/main --name-only "tenants/**/sync.yaml" > tmp-sync-files.txt

  # Extract tenant name from the tenant sync.yaml files
  while read file;
  do
    # Get tenant name from sync.yaml file
    TENANT=$(yq '.metadata.name' $file)
    if [ "$TENANT" != null ]; then
      # Append tenant name to IGNORE_TENANTS variable
      if [ -z "$IGNORE_TENANTS" ]; then
        IGNORE_TENANTS="$TENANT"
      else
        IGNORE_TENANTS="$IGNORE_TENANTS,$TENANT"
      fi
    fi
  done < tmp-sync-files.txt
  # Clean up
  rm -f tmp-sync-files.txt
  unset TENANT
fi

# Checks if the file 'tmp-changed-files.txt' exists and is not empty before processing.
# If it is not empty, extract the directory names of the changed files, sort them uniquely, and save to 'tmp-changed-dirs.txt'.
if [ -s tmp-changed-files.txt ]; then
  cat tmp-changed-files.txt | xargs dirname | sort -u > tmp-changed-dirs.txt
fi

touch tmp-changed-kustomization-dirs.txt
while read dir;
do
  # Check if kustomization.yaml exists in directory and if directory is not already in tmp-changed-kustomization-dirs.txt
  if [ -f "$dir/kustomization.yaml" ] && ! grep -Fxq "$dir" tmp-changed-kustomization-dirs.txt; then
    # Add directory to tmp-changed-kustomization-dirs.txt
    echo $dir >> tmp-changed-kustomization-dirs.txt
  fi
done < tmp-changed-dirs.txt


if [ -s tmp-changed-kustomization-dirs.txt ]; then
  # Print all changed kustomization directories
  printf "\n----------Folders to flux diff:----------\n"
  cat tmp-changed-kustomization-dirs.txt

  # Create output file.
  touch diff-output.txt
  # Loop over all lines in tmp-changed-kustomization-dirs and do diff against cluster
  while read dir;
  do
    # Get tenant name and namespace from header comment in kustomization.yaml on the form:
    # flux-tenant-name: <tenant-name>
    # flux-tenant-ns: <tenant-namespace>
    TENANT=$(yq '... | headComment | select(. != "")' "$dir/kustomization.yaml" | grep flux-tenant-name | yq '.flux-tenant-name')
    NAMESPACE=$(yq '... | headComment | select(. != "")' "$dir/kustomization.yaml" | grep flux-tenant-ns | yq '.flux-tenant-ns')


    if [ "$TENANT" == null ] || [ "$NAMESPACE" == null ]; then
      printf "\nNo 'flux-tenant-name' and/or 'flux-tenant-ns' comment found in $dir/kustomization.yaml. Skipping diff.\n" | tee -a diff-output.txt
      continue
    fi

    # Check if kustomization file has tenant header comment. If not, skip
    printf "\n---------- Flux diffing $dir----------\n"

    if ! [[ "$TENANT" == null ]] ; then
      # Check if the tenant should be ignored
      if [[ ",$IGNORE_TENANTS," == *",$TENANT,"* ]]; then
        printf -- '\n---\xE2\x9C\x93 Tenant %s ignored. Skipping diff for %s---\n' $TENANT $dir | tee -a diff-output.txt
        printf -- 'Tenant is new and is assumed to not exist in cluster, or it is explicitly ignored.\n' | tee -a diff-output.txt
        continue
      else
        # Perform flux diff.
        # Capture BOTH stdout and stderr: flux writes the diff to stdout, but
        # emits dry-run error blocks (✗ [ ... ]) to stderr. The RBAC-skip
        # classifier below reads this file, so it must contain the error block —
        # otherwise every failed dry-run looks like a generic error.
        flux diff kustomization $TENANT --path $dir --progress-bar=false -n $NAMESPACE > tmp-flux-diff.txt 2>&1
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
        awk '
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
        ' tmp-flux-diff.txt > tmp-flux-diff-redacted.txt && mv tmp-flux-diff-redacted.txt tmp-flux-diff.txt

        # Check if flux diff was successful
        case $FLUX_DIFF_RC in
          0)
            printf -- '\n---\xE2\x9C\x93 No changes in %s---\n' $dir
            ;;
          1)
            printf -- '\n---\xE2\x9C\x93 Changes detected in %s---\n' $dir | tee -a diff-output.txt
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
            case "$FLAT_DIFF" in
              *"✗ ["*)
                # Take everything after the first "✗ [", then drop a trailing "]".
                ERROR_BLOCK=${FLAT_DIFF#*✗ [}
                ERROR_BLOCK=${ERROR_BLOCK%]*}

                RBAC_KIND_RE='^(Role|RoleBinding|ClusterRole|ClusterRoleBinding)/'
                ERROR_ENTRIES=$(echo "$ERROR_BLOCK" | sed 's/, \([A-Z][A-Za-z]*\/\)/\n\1/g')
                while IFS= read -r entry; do
                  # Only entry-start lines begin with "<UpperKind>/"; skip detail lines.
                  echo "$entry" | grep -Eq '^[A-Z][A-Za-z]*/' || continue
                  if echo "$entry" | grep -Eq "$RBAC_KIND_RE"; then
                    HAS_RBAC_SKIP=1
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

            if [ "$NON_RBAC_ERRORS" -eq 0 ] && [ "$HAS_RBAC_SKIP" -eq 1 ]; then
              # All errors are RBAC-object errors: skip, don't fail.
              printf -- '\n---\xe2\x9a\xa0 RBAC objects skipped in %s---\n' "$dir" | tee -a diff-output.txt
              printf -- 'The flux-diff identity has no access to RBAC objects (Role/RoleBinding/ClusterRole/ClusterRoleBinding) by design. These are not diffed against the cluster; review their YAML in the PR directly.\n' | tee -a diff-output.txt
              continue
            fi

            printf -- '\n---\xe2\x9c\x97 An error occurred when diffing %s. Exit 1.---\n' $dir
            # Clean up and exit
            rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt tmp-flux-diff.txt diff-output.txt
            exit 1
            ;;
        esac
        continue
      fi
    fi
    # flux diff against cluster
  done < tmp-changed-kustomization-dirs.txt
fi

# Check if diff-output.txt is empty and add "No changes" if it is
if [ ! -s diff-output.txt ]; then
  echo "No changes" >> diff-output.txt
fi

# Clean up
rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt tmp-flux-diff.txt
exit 0
