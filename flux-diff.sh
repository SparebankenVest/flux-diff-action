## Pre-requisite:
# - yq
# - flux

#
# Find all changed files compared to main branch

git diff origin/main --name-only > tmp-changed-files.txt

# Find all parent directories of changed files containing kustomization.yaml
cat tmp-changed-files.txt | xargs -n 1 dirname | sort -u > tmp-changed-dirs.txt

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
  echo "\n----------Folders to flux diff:----------\n"
  cat tmp-changed-kustomization-dirs.txt

  # Loop over all lines in tmp-changed-kustomization-dirs and do diff against cluster
  while read dir;
  do
    # Get tenant name and namespace from header comment in kustomization.yaml on the form:
    # flux-tenant-name: <tenant-name>
    # flux-tenant-ns: <tenant-namespace>
    TENANT=$(yq 'head_comment' "$dir/kustomization.yaml" | grep flux-tenant-name | yq '.flux-tenant-name')
    NAMESPACE=$(yq 'head_comment' "$dir/kustomization.yaml" | grep flux-tenant-ns | yq '.flux-tenant-ns')

    # Check if kustomization file has tenant header comment. If not, skip
    echo "\n---------- Flux diffing $dir----------\n"

    if ! [[ "$TENANT" == null ]] ; then
      flux diff kustomization $TENANT --path $dir -n $NAMESPACE
      if [ $? -eq 0 ]; then
        printf '\xE2\x9C\x93' # Checkmark
        printf ' No changes'
      elif [ $? -gt 1 ]; then
        printf '\xe2\x9c\x97' # Cross
        printf ' An error occurred'
        # Clean up and exit
        rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt
        exit 1
      fi
      continue
    fi
    # flux diff against cluster
  done < tmp-changed-kustomization-dirs.txt
fi

# Clean up
rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt