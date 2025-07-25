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
        printf -- 'Tenant does not already exist in the cluster, or it is explicitly ignored.\n' | tee -a diff-output.txt
        continue
      else
        # Perform flux diff
        flux diff kustomization $TENANT --path $dir --progress-bar=false -n $NAMESPACE > tmp-flux-diff.txt

        # Check if flux diff was successful
        case $? in
          0)
            printf -- '\n---\xE2\x9C\x93 No changes in %s---\n' $dir
            ;;
          1)
            printf -- '\n---\xE2\x9C\x93 Changes detected in %s---\n' $dir | tee -a diff-output.txt
            cat tmp-flux-diff.txt | tee -a diff-output.txt
            ;;
          *)
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
