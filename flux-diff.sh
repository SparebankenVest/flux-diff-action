# Find all changed files compared to main branch
if [ -n "$PATH_FILTER" ]; then
  for path in $PATH_FILTER; do
    git diff origin/main --name-only "$path" >> tmp-changed-files.txt
  done
else
  git diff origin/main --name-only > tmp-changed-files.txt
fi

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
    TENANT=$(yq 'head_comment' "$dir/kustomization.yaml" | grep flux-tenant-name | yq '.flux-tenant-name')
    NAMESPACE=$(yq 'head_comment' "$dir/kustomization.yaml" | grep flux-tenant-ns | yq '.flux-tenant-ns')

    if [ "$TENANT" == null ] || [ "$NAMESPACE" == null ]; then
      printf "\nNo 'flux-tenant-name' and/or 'flux-tenant-ns' comment found in $dir/kustomization.yaml. Skipping diff.\n" | tee -a diff-output.txt
      continue
    fi

    # Check if kustomization file has tenant header comment. If not, skip
    printf "\n---------- Flux diffing $dir----------\n"

    if ! [[ "$TENANT" == null ]] ; then
      flux diff kustomization $TENANT --path $dir --progress-bar=false -n $NAMESPACE > tmp-flux-diff.txt
      if [ $? -eq 0 ]; then
        printf -- '\n---\xE2\x9C\x93 No changes in %s---\n' $dir
      elif [ $? -eq 1 ]; then
        printf -- '\n---\xE2\x9C\x93 Changes detected in %s---\n' $dir | tee -a diff-output.txt
        cat tmp-flux-diff.txt | tee -a diff-output.txt
      elif [ $? -gt 1 ]; then
        printf -- '\n---\xe2\x9c\x97 An error occurred in %s---\n' $dir | tee -a diff-output.txt
        # Clean up and exit
        rm -f tmp-changed-files.txt tmp-changed-dirs.txt tmp-changed-kustomization-dirs.txt tmp-flux-diff.txt
        exit 1
      fi
      continue
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